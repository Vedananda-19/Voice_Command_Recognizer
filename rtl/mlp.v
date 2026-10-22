// Source: 05 The Brain - Tiny Neural Network in Hardware.md
// 992 → 32 (ReLU, int8) → 4 (int32 scores). One MAC, 3-stage pipeline.
module mlp #(
    parameter SHIFT1 = 8                       // requant shift from the training script
)(
    input  wire               clk,
    input  wire               rst,
    input  wire               start,           // row_done && window_full
    input  wire        [5:0]  oldest,          // slot of the oldest feature row
    output wire        [9:0]  feat_raddr,      // to feature RAM (1-clock read)
    input  wire signed [7:0]  feat_rdata,
    output reg                done,            // 1-clock pulse
    output reg  signed [31:0] score0, score1, score2, score3
);
    localparam NIN1 = 992, NH = 32, NOUT = 4;

    // ---------- parameters from Python ----------
    reg signed [7:0]  w1 [0:NIN1*NH-1];
    reg signed [31:0] b1 [0:NH-1];
    reg signed [7:0]  w2 [0:NH*NOUT-1];
    reg signed [31:0] b2 [0:NOUT-1];
    initial begin
        $readmemh("w1.mem", w1);  $readmemh("b1.mem", b1);
        $readmemh("w2.mem", w2);  $readmemh("b2.mem", b2);
    end
    reg signed [7:0] h [0:NH-1];               // hidden activations

    // ---------- controller ----------
    localparam S_IDLE = 3'd0, S_LOAD = 3'd1, S_RUN = 3'd2, S_WAIT = 3'd3, S_STORE = 3'd4;
    reg  [2:0]  state;
    reg         layer;                          // 0 = hidden, 1 = output
    reg  [5:0]  neuron;
    reg  [9:0]  j;                              // input index
    reg  [14:0] waddr;                          // running weight address
    reg         wait_cnt;
    reg  signed [31:0] acc;

    wire [9:0] n_in      = layer ? NH   : NIN1;
    wire [5:0] n_neurons = layer ? NOUT : NH;

    // feature address: row = oldest + j/16 (mod 62), band = j % 16
    wire [6:0] row_sum = oldest + j[9:4];
    wire [5:0] slot    = (row_sum >= 7'd62) ? row_sum - 7'd62 : row_sum[5:0];
    assign feat_raddr  = {slot, j[3:0]};

    // requantise + ReLU
    function signed [7:0] requant(input signed [31:0] a);
        reg signed [31:0] r;
        begin
            r = (a + (32'sd1 <<< (SHIFT1-1))) >>> SHIFT1;
            if (a <= 0)       requant = 8'sd0;      // ReLU
            else if (r > 127) requant = 8'sd127;    // saturate
            else              requant = r[7:0];
        end
    endfunction

    // ---------- stage 1: memory reads (1-clock latency) ----------
    reg signed [7:0] w1q, w2q, hq;
    reg              v1;
    always @(posedge clk) begin
        w1q <= w1[waddr];
        w2q <= w2[waddr[6:0]];
        hq  <= h[j[4:0]];
        v1  <= (state == S_RUN);
    end
    wire signed [7:0] wq = layer ? w2q : w1q;
    wire signed [7:0] xq = layer ? hq  : feat_rdata;

    // ---------- stage 2: multiply ----------
    reg signed [15:0] prod;
    reg               v2;
    always @(posedge clk) begin
        prod <= xq * wq;
        v2   <= v1;
    end

    // ---------- stage 3 + FSM: accumulate, sequence ----------
    always @(posedge clk) begin
        done <= 1'b0;
        if (rst) begin
            state <= S_IDLE;
        end else begin
            if (v2) acc <= acc + prod;               // accumulate (overridden in LOAD)
            case (state)
                S_IDLE: if (start) begin
                    layer <= 0; neuron <= 0; waddr <= 0; state <= S_LOAD;
                end
                S_LOAD: begin
                    acc   <= layer ? b2[neuron[1:0]] : b1[neuron[4:0]];
                    j     <= 0;
                    state <= S_RUN;
                end
                S_RUN: begin
                    j     <= j + 1'b1;
                    waddr <= waddr + 1'b1;
                    if (j == n_in - 1'b1) begin state <= S_WAIT; wait_cnt <= 0; end
                end
                S_WAIT: begin
                    if (wait_cnt) state <= S_STORE;
                    wait_cnt <= 1'b1;
                end
                S_STORE: begin
                    if (!layer) h[neuron[4:0]] <= requant(acc);
                    else case (neuron[1:0])
                        2'd0: score0 <= acc;  2'd1: score1 <= acc;
                        2'd2: score2 <= acc;  2'd3: score3 <= acc;
                    endcase
                    if (neuron == n_neurons - 1'b1) begin
                        if (!layer) begin
                            layer <= 1; neuron <= 0; waddr <= 0; state <= S_LOAD;
                        end else begin
                            done <= 1'b1; state <= S_IDLE;
                        end
                    end else begin
                        neuron <= neuron + 1'b1; state <= S_LOAD;
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
