`timescale 1ns/10ps
//============================================================================
// Testbench for BSW (banded Smith-Waterman, affine gap, traceback)
//
//   +define+RTL            : simulate ../verilog/BSW.v
//   +define+SDF            : simulate gate-level netlist ../verilog/BSW_syn.v
//   +define+FSDB           : dump waveform (Verdi)
//   +define+BAND=<B>       : number of PEs / band parameter (default 4)
//   +define+SEQ_L=<n> +define+PAT_DIR=\"dir/\" +define+NCASE=<n>
//                          : other configurations (see gen_pattern.py --band --length)
//
// Runs NCASE patterns back-to-back (without reset in between) and checks
// score, alignment end/start, alignment length and every traceback op
// against the golden model (BSW.py / gen_pattern.py --band B).
//============================================================================
`define clk_period 12
`define END_CYCLE  200000
`ifndef NCASE
    `define NCASE 10
`endif
`ifndef SEQ_L
    `define SEQ_L 256
`endif
`ifndef PAT_DIR
    `define PAT_DIR "pattern/"
`endif
`ifndef BAND
    `define BAND 4
`endif
`define SDFFILE "../verilog/BSW_syn.sdf"

`ifdef SDF
    `include "../verilog/tsmc13.v"
    `include "../verilog/BSW_syn.v"
`else
    `include "../verilog/BSW.v"
`endif

module tb_BSW;
    localparam L  = `SEQ_L;
    localparam IW = (L > 1) ? $clog2(L) : 1;
    localparam DW = $clog2(8 * L + 1) + 1;

    reg           clk, reset, valid;
    reg  [1:0]    data_s, data_t;
    wire          finish, aln_valid;
    wire [1:0]    aln_op;
    wire [DW-1:0] max;
    wire [IW-1:0] end_i, end_j, start_i, start_j;
    wire [IW+1:0] aln_len;

    reg  [1:0]    seq_s [0:L-1];
    reg  [1:0]    seq_t [0:L-1];
    reg  [15:0]   gold  [0:2*L+8];
    reg  [1:0]    ops   [0:2*L+8];
    integer       n_ops, ncase, i, err, case_err, total_err;
    reg  [8*64-1:0] fname;

`ifdef SDF
    BSW BSW0 (
`else
    BSW #(.L(L), .B(`BAND)) BSW0 (
`endif
        .clk(clk), .reset(reset), .valid(valid), .data_s(data_s), .data_t(data_t),
        .finish(finish), .max(max), .end_i(end_i), .end_j(end_j),
        .start_i(start_i), .start_j(start_j), .aln_len(aln_len),
        .aln_valid(aln_valid), .aln_op(aln_op));

    initial begin
`ifdef SDF
        $sdf_annotate(`SDFFILE, BSW0);
`endif
`ifdef FSDB
        $fsdbDumpfile("BSW.fsdb");
        $fsdbDumpvars(0, tb_BSW, "+mda");
`endif
    end

    always #(`clk_period/2) clk = ~clk;

    // collect traceback ops
    always @(negedge clk) begin
        if (aln_valid) begin
            ops[n_ops] = aln_op;
            n_ops = n_ops + 1;
        end
    end

    task run_case(input integer c);
        integer cycles;
        begin
            $sformat(fname, "%scase%02d_s.dat", `PAT_DIR, c);      $readmemh(fname, seq_s);
            $sformat(fname, "%scase%02d_t.dat", `PAT_DIR, c);      $readmemh(fname, seq_t);
            for (i = 0; i < 2*L+9; i = i + 1) gold[i] = 16'hxxxx;
            $sformat(fname, "%scase%02d_golden.dat", `PAT_DIR, c); $readmemh(fname, gold);
            n_ops = 0;

            // stream S and T
            for (i = 0; i < L; i = i + 1) begin
                @(negedge clk);
                valid  = 1'b1;
                data_s = seq_s[i];
                data_t = seq_t[i];
            end
            @(negedge clk);
            valid  = 1'b0;
            data_s = 2'd0;
            data_t = 2'd0;

            // wait for finish
            cycles = 0;
            while (finish !== 1'b1) begin
                @(negedge clk);
                cycles = cycles + 1;
            end

            case_err = 0;
            if (max     !== gold[0][DW-1:0]) case_err = case_err + 1;
            if (end_i   !== gold[1][IW-1:0]) case_err = case_err + 1;
            if (end_j   !== gold[2][IW-1:0]) case_err = case_err + 1;
            if (start_i !== gold[3][IW-1:0]) case_err = case_err + 1;
            if (start_j !== gold[4][IW-1:0]) case_err = case_err + 1;
            if (aln_len !== gold[5][IW+1:0] || n_ops != gold[5]) case_err = case_err + 1;
            err = 0;
            for (i = 0; i < gold[5] && i < n_ops; i = i + 1)
                if (ops[i] !== gold[6+i][1:0]) err = err + 1;
            case_err  = case_err + err;
            total_err = total_err + case_err;

            $display("case%02d %s  score %4d/%4d  end (%3d,%3d)/(%3d,%3d)  start (%3d,%3d)/(%3d,%3d)  ops %3d/%3d (%0d op errors)  latency %0d cycles",
                     c, (case_err == 0) ? "PASS" : "FAIL",
                     max, gold[0], end_i, end_j, gold[1], gold[2],
                     start_i, start_j, gold[3], gold[4], n_ops, gold[5], err, cycles);
            repeat (3) @(negedge clk);
        end
    endtask

    initial begin
        clk = 1'b0; reset = 1'b0; valid = 1'b0; data_s = 2'd0; data_t = 2'd0;
        total_err = 0;
        #(`clk_period)   reset = 1'b1;
        #(`clk_period*2) reset = 1'b0;
        #(`clk_period*2);

        $display("------------------------------------------------------------");
        $display(" BSW  L = %0d  B (PEs) = %0d  band: -B <= j-i <= B-1", L, `BAND);
        $display("            yours/golden");
        $display("------------------------------------------------------------");
        for (ncase = 0; ncase < `NCASE; ncase = ncase + 1)
            run_case(ncase);
        $display("------------------------------------------------------------");
        if (total_err == 0)
            $display(" ALL %0d CASES PASS", `NCASE);
        else
            $display(" FAIL : %0d mismatches", total_err);
        $display("------------------------------------------------------------");
        $finish;
    end

    initial begin
        #(`clk_period*`END_CYCLE);
        $display("Time out!!");
        $finish;
    end
endmodule
