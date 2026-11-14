//============================================================================
// Banded Smith-Waterman accelerator (affine gap) with traceback
//
// Architecture follows Liao et al., "Adaptively Banded Smith-Waterman Algorithm
// for Long Reads and Its Hardware Accelerator" (ASAP 2018), fixed-band mode:
//
//   * B PEs sit on an anti-diagonal of the DP matrix. In step t the front is
//     at (r, c) and PE k computes cell (i, j) = (r + k, c - k), i + j = t.
//   * The front moves one cell per step:
//         (B-1) right shifts   -> top corner, PEs become active one by one
//         2(L-B) alternating down / right shifts (down first)
//         (B-1) right shifts   -> bottom corner, ends at cell (L-1, L-1)
//     i.e. r(t) = 0                                   for t <= B-1
//               = min(ceil((t-B+1)/2), L-B)           otherwise,   c(t) = t - r(t)
//     2L-1 steps in total; every cell with  -B <= j - i <= B-1  is computed
//     exactly once, all other cells are treated as H = 0, E = F = -inf.
//   * A right shift moves only the T shift register, a down shift only the
//     S shift register (as in the paper).
//   * Dependencies of PE k (from the previous one / two steps):
//         up   (i-1, j)  : right -> PE k-1 @t-1      down -> PE k   @t-1
//         left (i, j-1)  : right -> PE k   @t-1      down -> PE k+1 @t-1
//         diag (i-1,j-1) : right,right -> PE k-1 @t-2,  otherwise PE k @t-2
//   * Each step stores B 4-bit pointers {hsrc, e_ext, f_ext} at address t of
//     the traceback memory; cell (i,j) is found at t = i+j, k = i - r(t).
//
// Scoring : match +8, mismatch -5, gap open -7, gap extend -3 (same as SW repo)
//
// Interface
//   valid/data_s/data_t : S[k], T[k] for k = 0..L-1 on L consecutive cycles
//   aln_valid/aln_op    : ops from alignment END back to START
//                         0 = MATCH, 1 = MISMATCH, 2 = INS (gap in S), 3 = DEL (gap in T)
//   finish (1 cycle)    : max, (end_i,end_j), (start_i,start_j), aln_len
//   Tie-break: best = highest score, then smallest i, then smallest j;
//              DIAG > UP(F) > LEFT(E); extend gap only if strictly better.
//============================================================================
module BSW #(
    parameter L  = 256,            // sequence length (both sequences)
    parameter B  = 4,              // number of PEs = band parameter, 1 <= B <= L
    // derived widths -- do not override
    parameter IW = (L > 1) ? $clog2(L) : 1,
    parameter DW = $clog2(8 * L + 1) + 1
)(
    input                    clk,
    input                    reset,
    input                    valid,
    input      [1:0]         data_s,
    input      [1:0]         data_t,
    output reg               finish,
    output reg [DW-1:0]      max,
    output reg [IW-1:0]      end_i,
    output reg [IW-1:0]      end_j,
    output reg [IW-1:0]      start_i,
    output reg [IW-1:0]      start_j,
    output reg [IW+1:0]      aln_len,
    output                   aln_valid,
    output     [1:0]         aln_op
);
    localparam NSTEP = 2 * L - 1;
    localparam SW_   = $clog2(2 * L);           // step counter width (t <= 2L-2)
    localparam KW    = (B > 1) ? $clog2(B) : 1;
    localparam BW    = DW + 2 * IW;
    localparam signed [DW-1:0] NEG = -16;

    localparam S_LOAD = 3'd0, S_INIT = 3'd1, S_RUN = 3'd2, S_TB = 3'd3, S_DONE = 3'd4;

    // r(t): row of PE0 in step t
    function [IW-1:0] r_of;
        input [SW_-1:0] t;
        integer m, r;
        begin
            if (t <= B - 1) r = 0;
            else begin
                m = t - (B - 1);
                r = (m + 1) / 2;
                if (r > L - B) r = L - B;
            end
            r_of = r[IW-1:0];
        end
    endfunction

    reg  [2:0]     state_r;
    reg  [IW:0]    in_cnt_r;
    reg  [SW_-1:0] t_r;
    reg  [1:0]     seq_s [0:L-1];
    reg  [1:0]     seq_t [0:L-1];

    // ------------------------------------------------------------------
    // input capture
    // ------------------------------------------------------------------
    wire accept = valid && (state_r == S_LOAD) && (in_cnt_r < L);
    always @(posedge clk or posedge reset) begin
        if (reset)
            in_cnt_r <= 0;
        else if (state_r == S_DONE)
            in_cnt_r <= 0;
        else if (accept)
            in_cnt_r <= in_cnt_r + 1'b1;
    end

    // sequence storage (plain memory, no reset needed)
    always @(posedge clk) begin
        if (accept) begin
            seq_s[in_cnt_r[IW-1:0]] <= data_s;
            seq_t[in_cnt_r[IW-1:0]] <= data_t;
        end
    end

    // ------------------------------------------------------------------
    // front position and moves
    // ------------------------------------------------------------------
    wire [IW-1:0] r_cur   = r_of(t_r);
    wire [IW-1:0] r_prev  = (t_r >= 1) ? r_of(t_r - 1'b1) : {IW{1'b0}};
    wire [IW-1:0] r_prev2 = (t_r >= 2) ? r_of(t_r - 2'd2) : {IW{1'b0}};
    wire [IW-1:0] r_next  = r_of(t_r + 1'b1);
    wire          mv_down    = (t_r >= 1) && (r_cur  != r_prev);   // move into step t
    wire          mv_down_p  = (t_r >= 2) && (r_prev != r_prev2);  // move into step t-1
    wire          nxt_down   = (r_next != r_cur);                  // move into step t+1
    wire [SW_:0]  c_cur      = {1'b0, t_r} - r_cur;                // column of PE0
    wire          running    = (state_r == S_RUN);

    // S / T shift registers (sw[k] = S[r+k], tw[k] = T[c-k])
    reg  [1:0] sw [0:B-1];
    reg  [1:0] tw [0:B-1];
    integer k;
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            for (k = 0; k < B; k = k + 1) begin
                sw[k] <= 2'd0;
                tw[k] <= 2'd0;
            end
        end else if (state_r == S_INIT) begin
            for (k = 0; k < B; k = k + 1) begin
                sw[k] <= seq_s[k];
                tw[k] <= (k == 0) ? seq_t[0] : 2'd0;
            end
        end else if (running && t_r != NSTEP - 1) begin
            if (nxt_down) begin
                for (k = 0; k < B - 1; k = k + 1) sw[k] <= sw[k+1];
                sw[B-1] <= seq_s[r_cur + B];
            end else begin
                for (k = B - 1; k > 0; k = k - 1) tw[k] <= tw[k-1];
                tw[0] <= (c_cur + 1 < L) ? seq_t[c_cur[IW-1:0] + 1'b1] : 2'd0;
            end
        end
    end

    // ------------------------------------------------------------------
    // PE array
    // ------------------------------------------------------------------
    reg  signed [DW-1:0] h1 [0:B-1];   // results of step t-1
    reg  signed [DW-1:0] e1 [0:B-1];
    reg  signed [DW-1:0] f1 [0:B-1];
    reg                  v1 [0:B-1];
    reg  signed [DW-1:0] h2 [0:B-1];   // H of step t-2
    reg                  v2 [0:B-1];

    wire signed [DW-1:0] h_new [0:B-1];
    wire signed [DW-1:0] e_new [0:B-1];
    wire signed [DW-1:0] f_new [0:B-1];
    wire        [3:0]    ptr   [0:B-1];
    wire                 v_new [0:B-1];
    wire        [BW-1:0] cand  [0:B-1];
    wire        [4*B-1:0] ptr_word;

    genvar p;
    generate
        for (p = 0; p < B; p = p + 1) begin : PEs
            // cell of this PE
            wire [SW_:0] jj = c_cur - p;                          // may be negative
            wire         vv = running && !jj[SW_] && (jj < L);
            wire [IW-1:0] ii = r_cur + p;

            // neighbour selection
            wire                 up_v,   lf_v,   dg_v;
            wire signed [DW-1:0] up_h, up_f, lf_h, lf_e, dg_h;
            if (p == 0) begin : g_first
                assign up_v = mv_down ? v1[p] : 1'b0;
                assign up_h = h1[p];
                assign up_f = f1[p];
                assign dg_v = (!mv_down && !mv_down_p) ? 1'b0 : v2[p];
                assign dg_h = h2[p];
            end else begin : g_mid
                assign up_v = mv_down ? v1[p] : v1[p-1];
                assign up_h = mv_down ? h1[p] : h1[p-1];
                assign up_f = mv_down ? f1[p] : f1[p-1];
                assign dg_v = (!mv_down && !mv_down_p) ? v2[p-1] : v2[p];
                assign dg_h = (!mv_down && !mv_down_p) ? h2[p-1] : h2[p];
            end
            if (p == B - 1) begin : g_last
                assign lf_v = mv_down ? 1'b0 : v1[p];
                assign lf_h = h1[p];
                assign lf_e = e1[p];
            end else begin : g_lmid
                assign lf_v = mv_down ? v1[p+1] : v1[p];
                assign lf_h = mv_down ? h1[p+1] : h1[p];
                assign lf_e = mv_down ? e1[p+1] : e1[p];
            end

            BSW_PE #(.DW(DW)) u_pe (
                .s(sw[p]), .t(tw[p]),
                .h_up  (up_v ? up_h : {DW{1'b0}}), .f_up  (up_v ? up_f : NEG),
                .h_left(lf_v ? lf_h : {DW{1'b0}}), .e_left(lf_v ? lf_e : NEG),
                .h_diag(dg_v ? dg_h : {DW{1'b0}}),
                .h(h_new[p]), .e(e_new[p]), .f(f_new[p]), .ptr(ptr[p])
            );

            assign v_new[p] = vv;
            assign cand[p]  = vv ? {h_new[p], ii, jj[IW-1:0]} : {BW{1'b0}};
            assign ptr_word[4*p +: 4] = ptr[p];

            always @(posedge clk or posedge reset) begin
                if (reset) begin
                    h1[p] <= 0; e1[p] <= 0; f1[p] <= 0; v1[p] <= 1'b0;
                    h2[p] <= 0; v2[p] <= 1'b0;
                end else if (state_r == S_INIT) begin
                    v1[p] <= 1'b0;
                    v2[p] <= 1'b0;
                end else if (running) begin
                    h1[p] <= h_new[p]; e1[p] <= e_new[p]; f1[p] <= f_new[p]; v1[p] <= vv;
                    h2[p] <= h1[p];    v2[p] <= v1[p];
                end
            end
        end
    endgenerate

    // ------------------------------------------------------------------
    // best cell (score, then smallest i, then smallest j)
    // ------------------------------------------------------------------
    function better;
        input [BW-1:0] a, b;
        begin
            if (a[BW-1 -: DW] != b[BW-1 -: DW])
                better = $signed(a[BW-1 -: DW]) > $signed(b[BW-1 -: DW]);
            else
                better = (a[2*IW-1:0] < b[2*IW-1:0]);
        end
    endfunction

    reg  [BW-1:0] best_r;
    reg  [BW-1:0] best_w;
    integer kb;
    always @(*) begin
        best_w = best_r;
        for (kb = 0; kb < B; kb = kb + 1)
            if (v_new[kb] && better(cand[kb], best_w)) best_w = cand[kb];
    end

    // ------------------------------------------------------------------
    // traceback memory: one word of B pointers per step
    // ------------------------------------------------------------------
    reg [4*B-1:0] tbm [0:NSTEP-1];
    always @(posedge clk) begin
        if (running) tbm[t_r] <= ptr_word;
    end

    wire signed [IW:0] tb_i, tb_j;
    wire [SW_-1:0]     tb_t   = tb_i[IW-1:0] + tb_j[IW-1:0];
    wire [IW-1:0]      tb_r   = r_of(tb_t);
    wire [IW:0]        tb_k   = {1'b0, tb_i[IW-1:0]} - tb_r;     // PE index of cell
    wire               tb_inb = (tb_i[IW-1:0] >= tb_r) && (tb_k < B);
    wire [4*B-1:0]     tb_wd  = tbm[tb_t];
    wire [3:0]         tb_ptr = tb_wd[4*tb_k[KW-1:0] +: 4];

    reg  [IW-1:0] bi_r, bj_r;
    reg           tb_start;
    wire          tb_done;
    wire [IW:0]   tb_si, tb_sj;
    wire [IW+1:0] tb_len;

    BSW_traceback #(.IW(IW)) u_tb (
        .clk(clk), .reset(reset),
        .start(tb_start), .best_i(bi_r), .best_j(bj_r),
        .cur_i(tb_i), .cur_j(tb_j),
        .ptr(tb_ptr), .inband(tb_inb),
        .s_base(seq_s[tb_i[IW-1:0]]), .t_base(seq_t[tb_j[IW-1:0]]),
        .op_valid(aln_valid), .op(aln_op),
        .done(tb_done), .start_i(tb_si), .start_j(tb_sj), .len(tb_len)
    );

    // ------------------------------------------------------------------
    // control
    // ------------------------------------------------------------------
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            state_r  <= S_LOAD;
            t_r      <= 0;
            best_r   <= {BW{1'b0}};
            finish   <= 1'b0;
            max      <= 0;
            end_i    <= 0;
            end_j    <= 0;
            start_i  <= 0;
            start_j  <= 0;
            aln_len  <= 0;
            bi_r     <= 0;
            bj_r     <= 0;
            tb_start <= 1'b0;
        end else begin
            finish   <= 1'b0;
            tb_start <= 1'b0;
            case (state_r)
                S_LOAD: if (accept && in_cnt_r == L - 1) state_r <= S_INIT;
                S_INIT: begin
                    t_r     <= 0;
                    best_r  <= {BW{1'b0}};
                    state_r <= S_RUN;
                end
                S_RUN: begin
                    best_r <= best_w;
                    if (t_r == NSTEP - 1) begin
                        max      <= best_w[BW-1 -: DW];
                        bi_r     <= best_w[2*IW-1 -: IW];
                        bj_r     <= best_w[IW-1:0];
                        tb_start <= 1'b1;
                        state_r  <= S_TB;
                    end else
                        t_r <= t_r + 1'b1;
                end
                S_TB: if (tb_done) begin
                    end_i   <= bi_r;
                    end_j   <= bj_r;
                    start_i <= tb_si[IW-1:0];
                    start_j <= tb_sj[IW-1:0];
                    aln_len <= tb_len;
                    finish  <= 1'b1;
                    state_r <= S_DONE;
                end
                default: state_r <= S_LOAD;     // S_DONE
            endcase
        end
    end

endmodule

//============================================================================
// PE: one DP cell (combinational)
//============================================================================
module BSW_PE #(
    parameter DW = 13
)(
    input         [1:0]    s,
    input         [1:0]    t,
    input  signed [DW-1:0] h_up,
    input  signed [DW-1:0] f_up,
    input  signed [DW-1:0] h_left,
    input  signed [DW-1:0] e_left,
    input  signed [DW-1:0] h_diag,
    output reg signed [DW-1:0] h,
    output signed [DW-1:0] e,
    output signed [DW-1:0] f,
    output        [3:0]    ptr
);
    localparam signed [DW-1:0] MATCH = 8, MISMATCH = -5, GAP_OPEN = -7, GAP_EXT = -3;
    localparam [1:0] STOP = 2'd0, DIAG = 2'd1, UP = 2'd2, LEFT = 2'd3;

    wire signed [DW-1:0] e_open = h_left + GAP_OPEN;
    wire signed [DW-1:0] e_extv = e_left + GAP_EXT;
    wire                 e_ext  = (e_extv > e_open);
    assign e = e_ext ? e_extv : e_open;

    wire signed [DW-1:0] f_open = h_up + GAP_OPEN;
    wire signed [DW-1:0] f_extv = f_up + GAP_EXT;
    wire                 f_ext  = (f_extv > f_open);
    assign f = f_ext ? f_extv : f_open;

    wire signed [DW-1:0] d = h_diag + ((s == t) ? MATCH : MISMATCH);

    reg [1:0] hsrc;
    always @(*) begin
        h    = 0;
        hsrc = STOP;
        if (d > h) begin h = d; hsrc = DIAG; end
        if (f > h) begin h = f; hsrc = UP;   end
        if (e > h) begin h = e; hsrc = LEFT; end
    end

    assign ptr = {hsrc, e_ext, f_ext};
endmodule

//============================================================================
// Traceback FSM (one op per cycle), ptr/inband read combinationally for (cur_i, cur_j)
//============================================================================
module BSW_traceback #(
    parameter IW = 8
)(
    input                    clk,
    input                    reset,
    input                    start,
    input      [IW-1:0]      best_i,
    input      [IW-1:0]      best_j,
    output reg signed [IW:0] cur_i,
    output reg signed [IW:0] cur_j,
    input      [3:0]         ptr,
    input                    inband,
    input      [1:0]         s_base,
    input      [1:0]         t_base,
    output reg               op_valid,
    output reg [1:0]         op,
    output reg               done,
    output     [IW:0]        start_i,
    output     [IW:0]        start_j,
    output reg [IW+1:0]      len
);
    localparam [1:0] ST_H = 2'd0, ST_E = 2'd1, ST_F = 2'd2;
    localparam [1:0] STOP = 2'd0, DIAG = 2'd1, UP = 2'd2;
    localparam [1:0] OP_M = 2'd0, OP_X = 2'd1, OP_I = 2'd2, OP_D = 2'd3;

    reg       busy;
    reg [1:0] st;

    wire [1:0] hsrc  = ptr[3:2];
    wire       e_ext = ptr[1];
    wire       f_ext = ptr[0];
    wire       oob   = cur_i[IW] || cur_j[IW];

    reg [1:0] act;
    reg       stop;
    always @(*) begin
        stop = 1'b0;
        act  = ST_H;
        case (st)
            ST_E: act = ST_E;
            ST_F: act = ST_F;
            default: begin
                if (oob || !inband || hsrc == STOP) stop = 1'b1;
                else if (hsrc == DIAG)              act  = ST_H;
                else if (hsrc == UP)                act  = ST_F;
                else                                act  = ST_E;
            end
        endcase
    end

    assign start_i = cur_i + 1'b1;
    assign start_j = cur_j + 1'b1;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            busy <= 1'b0; st <= ST_H; cur_i <= 0; cur_j <= 0;
            op_valid <= 1'b0; op <= 2'd0; done <= 1'b0; len <= 0;
        end else begin
            op_valid <= 1'b0;
            done     <= 1'b0;
            if (start) begin
                busy  <= 1'b1;
                st    <= ST_H;
                cur_i <= {1'b0, best_i};
                cur_j <= {1'b0, best_j};
                len   <= 0;
            end else if (busy) begin
                if (stop) begin
                    busy <= 1'b0;
                    done <= 1'b1;
                end else begin
                    op_valid <= 1'b1;
                    len      <= len + 1'b1;
                    case (act)
                        ST_H: begin
                            op    <= (s_base == t_base) ? OP_M : OP_X;
                            cur_i <= cur_i - 1'b1;
                            cur_j <= cur_j - 1'b1;
                            st    <= ST_H;
                        end
                        ST_F: begin
                            op    <= OP_D;
                            cur_i <= cur_i - 1'b1;
                            st    <= f_ext ? ST_F : ST_H;
                        end
                        default: begin
                            op    <= OP_I;
                            cur_j <= cur_j - 1'b1;
                            st    <= e_ext ? ST_E : ST_H;
                        end
                    endcase
                end
            end
        end
    end
endmodule
