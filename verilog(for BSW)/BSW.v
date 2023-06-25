module BSW(
    input clk,
    input reset,
    input [1:0] data_s,
    input [1:0] data_t,
    input i_valid,
    output reg finish,
    output reg [11:0] max
);
    parameter BAND_WIDTH = 4;

    parameter GET_DATA = 0;
    parameter PREPARE = 1;
    parameter MOVING = 2;
    parameter ENDING = 3;
    parameter OUT = 4;
    
    integer i;
    reg [2:0]  state_r, state_w;
    reg [1:0]  seq_s     [0:255];
    reg [1:0]  seq_s_nxt [0:255];
    reg [1:0]  seq_t     [0:255];
    reg [1:0]  seq_t_nxt [0:255];
    reg [7:0]  counter_r, counter_w;

    
    reg [3:0]   valid;
    reg [1:0]   edge_count_r, edge_count_w;
    reg         even_odd_r, even_odd_w;
    reg [9:0]   moving_down_r, moving_down_w;
    reg [9:0]   moving_right_r, moving_right_w;
    wire[9:0]   moving_count;
    reg [1:0]   seq_s_data     [0:3];
    reg [1:0]   seq_t_data     [0:3];


    wire [11:0] Max_in_data[0:3];
    wire [11:0] F_in_data  [0:3];
    wire [11:0] V_in_data  [0:3];
    wire [11:0] E_in_data  [0:3];
    reg  [11:0] Max_in;
    reg  [11:0] Max_in2;
    reg  [11:0] Max_in3;
    reg  [11:0] Max_in4;
    reg  [11:0] V_in;
    reg  [11:0] V_in2;
    reg  [11:0] V_in3;
    reg  [11:0] V_in4;
    reg  [11:0] F_in;
    reg  [11:0] F_in2;
    reg  [11:0] F_in3;
    reg  [11:0] F_in4;
    reg  [11:0] E_in;
    reg  [11:0] E_in2;
    reg  [11:0] E_in3;
    reg  [11:0] E_in4;


    wire [11:0] Max_out[0:3];
    wire [11:0] V_out  [0:3];
    wire [11:0] F_out  [0:3];
    wire [11:0] E_out  [0:3];

    /******************PEs********************/
    genvar j;
    generate   
        for(j=0;j<BAND_WIDTH;j=j+1) begin: PEs
            PE PE1(.clk(clk),.reset(reset),.valid(valid[j]),.S_in(seq_s_data[j]),.T_in(seq_t_data[j])
                    ,.Max_in(Max_in_data[j]),.V_in(V_in_data[j]),.F_in(F_in_data[j]),.E_in(E_in_data[j])
                    ,.Max_out(Max_out[j]),.V_out(V_out[j]),.F_out(F_out[j]),.E_out(E_out[j]));
        end
    endgenerate
    /*****************************************/
    assign moving_count   = moving_down_r + moving_right_r;
    assign Max_in_data[0] = Max_in;
    assign Max_in_data[1] = Max_in2;
    assign Max_in_data[2] = Max_in3;
    assign Max_in_data[3] = Max_in4;
    assign V_in_data[0]   = V_in;
    assign V_in_data[1]   = V_in2;
    assign V_in_data[2]   = V_in3;
    assign V_in_data[3]   = V_in4;
    assign F_in_data[0]   = F_in;
    assign F_in_data[1]   = F_in2;
    assign F_in_data[2]   = F_in3;
    assign F_in_data[3]   = F_in4;
    assign E_in_data[0]   = E_in;
    assign E_in_data[1]   = E_in2;
    assign E_in_data[2]   = E_in3;
    assign E_in_data[3]   = E_in4;

    always@ (*) begin
        case(state_r) 
            GET_DATA: state_w = (&counter_r) ? PREPARE : GET_DATA;
            PREPARE:  state_w = (&edge_count_r) ? MOVING : PREPARE;
            MOVING:   state_w = (moving_count==10'd508) ? ENDING : MOVING;  // shifting takes 2*length - bandwidth times
            ENDING:   state_w = (&edge_count_r) ? OUT : ENDING;
            OUT:      state_w = OUT;
            default:  state_w = state_r;
        endcase
    end

    always@ (posedge clk or posedge reset) begin
        if(reset)  
            state_r <= GET_DATA;
        else
            state_r <= state_w;
    end

    /*****************
        GET DATA
    ******************/
    always@ (*) begin
        if(state_r == GET_DATA && i_valid)
            counter_w = counter_r + 1'b1;
        else
            counter_w = counter_r;
    end

    always@ (*) begin
        for(i=0;i<256;i=i+1) begin
            seq_s_nxt[i] = seq_s[i];
            seq_t_nxt[i] = seq_t[i];
        end

        if(state_r == GET_DATA && i_valid) begin
            seq_s_nxt[counter_r] = data_s;
            seq_t_nxt[counter_r] = data_t;
        end 
    end

    always@ (posedge clk or posedge reset) begin
        if(reset) begin
            counter_r <= 0;
            for(i=0;i<256;i=i+1) begin
                seq_s[i] <= 0;
                seq_t[i] <= 0;
            end
        end
        else begin
            counter_r <= counter_w;
            for(i=0;i<256;i=i+1) begin
                seq_s[i] <= seq_s_nxt[i];
                seq_t[i] <= seq_t_nxt[i];
            end
        end
    end

    /******************* 
    PREPARE for SHIFTING
            and
    AFTER SHIFTING
    *******************/
    always@ (*) begin
        if(state_r == PREPARE || state_r == ENDING) 
            edge_count_w = edge_count_r + 1'b1;
        else
            edge_count_w = edge_count_r;
    end

    always@ (*) begin
        if(state_r == GET_DATA) begin
            valid = 4'b0000;
        end
        else if(state_r == PREPARE) begin
            case(edge_count_r) 
                2'b00:   valid = 4'b0001;
                2'b01:   valid = 4'b0011;
                2'b10:   valid = 4'b0111;
                2'b11:   valid = 4'b1111;
                default: valid = 4'b0000;
            endcase
        end
        else begin
            valid = 4'b1111;
        end
    end

    always@ (posedge clk or posedge reset)begin
        if(reset)
            edge_count_r <= 0;
        else
            edge_count_r <= edge_count_w;
    end

    /*****************
    RIGHT OR DOWN SHIFTING
    ******************/
    always@ (*) begin
        if(state_r == PREPARE) begin
            case(edge_count_r)
                2'b00: begin
                    seq_s_data[0] = seq_s[0];
                    seq_s_data[1] = 0;
                    seq_s_data[2] = 0;
                    seq_s_data[3] = 0;
                    seq_t_data[0] = seq_t[0];
                    seq_t_data[1] = seq_t[1];
                    seq_t_data[2] = seq_t[2];
                    seq_t_data[3] = seq_t[3];
                end
                2'b01: begin
                    seq_s_data[0] = seq_s[1];
                    seq_s_data[1] = seq_s[0];
                    seq_s_data[2] = 0;
                    seq_s_data[3] = 0;
                    seq_t_data[0] = seq_t[0];
                    seq_t_data[1] = seq_t[1];
                    seq_t_data[2] = seq_t[2];
                    seq_t_data[3] = seq_t[3];
                end
                2'b10: begin
                    seq_s_data[0] = seq_s[2];
                    seq_s_data[1] = seq_s[1];
                    seq_s_data[2] = seq_s[0];
                    seq_s_data[3] = 0;
                    seq_t_data[0] = seq_t[0];
                    seq_t_data[1] = seq_t[1];
                    seq_t_data[2] = seq_t[2];
                    seq_t_data[3] = seq_t[3];
                end
                2'b11: begin
                    seq_s_data[0] = seq_s[3];
                    seq_s_data[1] = seq_s[2];
                    seq_s_data[2] = seq_s[1];
                    seq_s_data[3] = seq_s[0];
                    seq_t_data[0] = seq_t[0];
                    seq_t_data[1] = seq_t[1];
                    seq_t_data[2] = seq_t[2];
                    seq_t_data[3] = seq_t[3];
                end
                default: begin
                    seq_s_data[0] = 0;
                    seq_s_data[1] = 0;
                    seq_s_data[2] = 0;
                    seq_s_data[3] = 0;
                    seq_t_data[0] = 0;
                    seq_t_data[1] = 0;
                    seq_t_data[2] = 0;
                    seq_t_data[3] = 0;
                end
            endcase
        end
        else if(state_r == MOVING) begin
            if(!even_odd_r) begin
                //moving downward
                seq_s_data[3] = seq_s[moving_down_r];
                seq_s_data[2] = seq_s[moving_down_r+1];
                seq_s_data[1] = seq_s[moving_down_r+2];
                seq_s_data[0] = seq_s[moving_down_r+3];
                seq_t_data[0] = seq_t[moving_right_r];
                seq_t_data[1] = seq_t[moving_right_r+1];
                seq_t_data[2] = seq_t[moving_right_r+2];
                seq_t_data[3] = seq_t[moving_right_r+3];
            end
            else begin
                //moving rightward
                seq_s_data[3] = seq_s[moving_down_r];
                seq_s_data[2] = seq_s[moving_down_r+1];
                seq_s_data[1] = seq_s[moving_down_r+2];
                seq_s_data[0] = seq_s[moving_down_r+3];
                seq_t_data[0] = seq_t[moving_right_r];
                seq_t_data[1] = seq_t[moving_right_r+1];
                seq_t_data[2] = seq_t[moving_right_r+2];
                seq_t_data[3] = seq_t[moving_right_r+3];
            end
        end
        else if(state_r == ENDING) begin
            case(edge_count_r)
                2'b00: begin
                    seq_s_data[0] = seq_s[255];
                    seq_s_data[1] = seq_s[254];
                    seq_s_data[2] = seq_s[253];
                    seq_s_data[3] = seq_s[252];
                    seq_t_data[0] = seq_t[252];
                    seq_t_data[1] = seq_t[253];
                    seq_t_data[2] = seq_t[254];
                    seq_t_data[3] = seq_t[255];
                end
                2'b01: begin
                    seq_s_data[0] = 0;
                    seq_s_data[1] = seq_s[255];
                    seq_s_data[2] = seq_s[254];
                    seq_s_data[3] = seq_s[253];
                    seq_t_data[0] = seq_t[252];
                    seq_t_data[1] = seq_t[253];
                    seq_t_data[2] = seq_t[254];
                    seq_t_data[3] = seq_t[255];
                end
                2'b10: begin
                    seq_s_data[0] = 0;
                    seq_s_data[1] = 0;
                    seq_s_data[2] = seq_s[255];
                    seq_s_data[3] = seq_s[254];
                    seq_t_data[0] = seq_t[252];
                    seq_t_data[1] = seq_t[253];
                    seq_t_data[2] = seq_t[254];
                    seq_t_data[3] = seq_t[255];
                end
                2'b11: begin
                    seq_s_data[0] = 0;
                    seq_s_data[1] = 0;
                    seq_s_data[2] = 0;
                    seq_s_data[3] = seq_s[255];
                    seq_t_data[0] = seq_t[252];
                    seq_t_data[1] = seq_t[253];
                    seq_t_data[2] = seq_t[254];
                    seq_t_data[3] = seq_t[255];
                end
                default: begin
                    seq_s_data[0] = 0;
                    seq_s_data[1] = 0;
                    seq_s_data[2] = 0;
                    seq_s_data[3] = 0;
                    seq_t_data[0] = 0;
                    seq_t_data[1] = 0;
                    seq_t_data[2] = 0;
                    seq_t_data[3] = 0;
                end
            endcase
        end
        else begin
            seq_s_data[0] = 0;
            seq_s_data[1] = 0;
            seq_s_data[2] = 0;
            seq_s_data[3] = 0;
            seq_t_data[0] = 0;
            seq_t_data[1] = 0;
            seq_t_data[2] = 0;
            seq_t_data[3] = 0;
        end
    end

    always@ (*) begin
        if(state_r == MOVING)
            even_odd_w = !even_odd_r;
        else
            even_odd_w = even_odd_r;
    end

    always@ (*) begin
        moving_down_w = moving_down_r;
        moving_right_w = moving_right_r;

        if(state_r == MOVING) begin
            if(!even_odd_r)
                moving_down_w = moving_down_r + 1;
            else
                moving_right_w = moving_right_r + 1;
        end
    end

    always@ (posedge clk or posedge reset) begin
        if(reset) begin
            even_odd_r <= 0;
            moving_down_r <= 0;
            moving_right_r <= 0;
        end
        else begin
            even_odd_r <= even_odd_w;
            moving_down_r <= moving_down_w;
            moving_right_r <= moving_right_w;
        end
    end

    /*******************
    Select data for PEs
    *******************/
    always@ (*) begin
        if(state_r == PREPARE) begin
            Max_in = 0;
            V_in   = 0;
            F_in   = 0;
            E_in   = E_out[0];

            Max_in2 = Max_out[0];
            V_in2   = V_out[0];
            F_in2   = F_out[0];
            E_in2   = E_out[1];

            Max_in3 = Max_out[1];
            V_in3   = V_out[1];
            F_in3   = F_out[1];
            E_in3   = E_out[2];

            Max_in4 = Max_out[2];
            V_in4   = V_out[2];
            F_in4   = F_out[2];
            E_in4   = E_out[3];
        end
        else if(state_r == MOVING) begin
            if(!even_odd_r) begin
                Max_in = Max_out[0];
                V_in   = V_out[0];
                F_in   = F_out[0];
                E_in   = 0;

                Max_in2 = Max_out[0];
                V_in2   = V_out[0];
                F_in2   = F_out[0];
                E_in2   = E_out[1];

                Max_in3 = Max_out[1];
                V_in3   = V_out[1];
                F_in3   = F_out[1];
                E_in3   = E_out[2];

                Max_in4 = Max_out[2];
                V_in4   = V_out[2];
                F_in4   = F_out[2];
                E_in4   = E_out[3];
            end
            else begin
                Max_in   = Max_out[1];
                V_in     = V_out[1];
                F_in     = F_out[0];
                E_in     = E_out[1];

                Max_in2  = Max_out[2];
                V_in2    = V_out[2];
                F_in2    = F_out[1];
                E_in2    = E_out[2];

                Max_in3  = Max_out[3];
                V_in3    = V_out[3];
                F_in3    = F_out[2];
                E_in3    = E_out[3];

                Max_in4  = Max_out[3];
                V_in4    = V_out[3];
                F_in4    = F_out[3];
                E_in4    = 0;
            end
        end
        else if(state_r == ENDING) begin
            Max_in = Max_out[0];
            V_in   = V_out[0];
            F_in   = F_out[0];
            E_in   = E_out[0];

            Max_in2 = Max_out[0];
            V_in2   = V_out[0];
            F_in2   = F_out[0];
            E_in2   = E_out[1];

            Max_in3 = Max_out[1];
            V_in3   = V_out[1];
            F_in3   = F_out[1];
            E_in3   = E_out[2];

            Max_in4 = Max_out[2];
            V_in4   = V_out[2];
            F_in4   = F_out[2];
            E_in4   = E_out[3];
        end
        else begin
            Max_in = 0;
            V_in = 0;
            F_in = 0;
            E_in = 0;

            Max_in2 = 0;
            V_in2 = 0;
            F_in2 = 0;
            E_in2 = 0;

            Max_in3 = 0;
            V_in3 = 0;
            F_in3 = 0;
            E_in3 = 0;

            Max_in4 = 0;
            V_in4 = 0;
            F_in4 = 0;
            E_in4 = 0;
        end
    end
    
    /*******************
        OUTPUT
    *******************/
    always@ (posedge clk or posedge reset) begin
        if(reset) begin
            finish <= 0;
            max    <= 0;
        end
        else begin
            if(state_r==OUT) begin
                finish <= 1;
                max    <= Max_out[3];
            end
            else begin
                finish <= 0;
                max    <= 0;
            end
        end
    end

endmodule

module PE(
    input clk,
    input reset,
    input valid,
    input [1:0]   S_in,
    input [1:0]   T_in,
    input [11:0]  Max_in,
    input [11:0]  V_in,
    input [11:0]  F_in,
    input [11:0]  E_in,
    output [11:0] Max_out,
    output [11:0] V_out,
    output [11:0] F_out,
    output [11:0] E_out
);
    localparam GAP_OPEN = -12'd7; 
    localparam GAP_EXTEND =  -12'd3; 
    localparam MATCH = 12'd8;
    localparam MISMATCH = -12'd5;

    parameter IDLE = 0;
    parameter RUN = 1;

    // For DFF parameters
    reg state_r ,state_w;
    reg [11:0] V_diag_r;
    reg [11:0] E_out_r,E_out_w;
    reg [11:0] Max_out_r,Max_out_w;
    reg [11:0] V_out_r,V_out_w;
    reg [11:0] F_out_r,F_out_w;

    assign Max_out = Max_out_r;
    assign F_out = F_out_r;
    assign V_out = V_out_r;
    assign E_out = E_out_r;

    // wire and regs
    reg [11:0] score;
    reg [11:0] max_out_temp;
    reg [11:0] max_E_1,max_E_2;
    reg [11:0] max_F_1,max_F_2;
    reg [11:0] max_V_1,max_V_2;

    always@ (*) begin
        if(state_r==IDLE)
            state_w = (valid) ? RUN : IDLE;
        else 
            state_w = state_r;
    end

    always@ (*) begin
        score   = (S_in==T_in) ? MATCH : MISMATCH;
        max_V_1 = $signed(V_diag_r) + $signed(score);
        max_F_1 = $signed(V_in) + $signed(GAP_OPEN);
        max_F_2 = $signed(F_in) + $signed(GAP_EXTEND);
        max_E_1 = $signed(E_in) + $signed(GAP_EXTEND);
        max_E_2 = $signed(V_out_r) + $signed(GAP_OPEN);

        if($signed(F_out_w) >= $signed(E_out_w))
            max_V_2 = F_out_w;
        else 
            max_V_2 = E_out_w;

        if($signed(V_out_w) >= $signed(Max_in))
            max_out_temp = V_out_w;
        else 
            max_out_temp = Max_in;
    end

    always@ (*) begin
        if(state_r==IDLE && (!valid)) begin
            Max_out_w = 0;
            V_out_w = 0;
            E_out_w = 0;
            F_out_w = 0;
        end
        else begin
            if($signed(max_out_temp) >= $signed(Max_out_r))
                Max_out_w = max_out_temp;
            else 
                Max_out_w = Max_out_r;

            if($signed(max_V_1) >= $signed(max_V_2))
                V_out_w = max_V_1;
            else 
                V_out_w = max_V_2;

            if($signed(max_E_1) >= $signed(max_E_2))
                E_out_w = max_E_1;
            else 
                E_out_w = max_E_2;
            
            if($signed(max_F_1) >= $signed(max_F_2))
                F_out_w = max_F_1;
            else 
                F_out_w = max_F_2;
        end
    end

    always@ (posedge clk or posedge reset) begin
        if(reset) begin
            state_r   <= 0;
            V_diag_r  <= 0;
            E_out_r   <= 0;
            Max_out_r <= 0;
            V_out_r   <= 0;
            F_out_r   <= 0;
        end
        else begin
            state_r   <= state_w;
            V_diag_r  <= V_in;
            E_out_r   <= E_out_w;
            Max_out_r <= Max_out_w;
            V_out_r   <= V_out_w;
            F_out_r   <= F_out_w;
        end
    end

endmodule
