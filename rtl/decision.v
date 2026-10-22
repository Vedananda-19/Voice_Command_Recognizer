// Source: 06 Making the Decision - Argmax and Command FSM.md
// Argmax + margin + K-in-a-row + cooldown → lamp control.
module decision #(
    parameter signed [31:0] MARGIN   = 32'sd2000,  // from validation data
    parameter               K        = 4,          // consecutive agreements
    parameter               COOLDOWN = 62          // inferences (~1 s)
)(
    input  wire               clk,
    input  wire               rst,
    input  wire               valid,               // = mlp done
    input  wire signed [31:0] s0, s1, s2, s3,      // silence, unknown, on, off
    output reg         [1:0]  best,                // latest raw guess (debug)
    output reg                confident,           // latest guess passed margin
    output reg                fire_on,             // 1-clock pulses
    output reg                fire_off,
    output reg                lamp                 // the controlled output
);
    // ---------- argmax + second-best (comparison tree, combinational) ----------
    wire               a01 = (s1 > s0);
    wire signed [31:0] w01 = a01 ? s1 : s0,  l01 = a01 ? s0 : s1;
    wire         [1:0] i01 = a01 ? 2'd1 : 2'd0;
    wire               a23 = (s3 > s2);
    wire signed [31:0] w23 = a23 ? s3 : s2,  l23 = a23 ? s2 : s3;
    wire         [1:0] i23 = a23 ? 2'd3 : 2'd2;

    wire               top23   = (w23 > w01);
    wire         [1:0] b_idx   = top23 ? i23 : i01;
    wire signed [31:0] b_val   = top23 ? w23 : w01;
    // second best = larger of (the other pair's winner, the best's own pair loser)
    wire signed [31:0] other_w = top23 ? w01 : w23;
    wire signed [31:0] own_l   = top23 ? l23 : l01;
    wire signed [31:0] second  = (other_w > own_l) ? other_w : own_l;
    wire               conf    = (b_val - second) > MARGIN;
    wire               is_cmd  = conf && b_idx[1];   // class 2 or 3

    // ---------- command FSM ----------
    localparam LISTEN = 1'b0, COOL = 1'b1;
    reg       state;
    reg [1:0] last;
    reg [3:0] streak;
    reg [6:0] cd_cnt;

    always @(posedge clk) begin
        fire_on  <= 1'b0;
        fire_off <= 1'b0;
        if (rst) begin
            state <= LISTEN; streak <= 0; lamp <= 1'b0;
        end else if (valid) begin
            best      <= b_idx;
            confident <= conf;
            case (state)
                LISTEN: begin
                    if (is_cmd && b_idx == last && streak != 0) begin
                        if (streak == K-1) begin          // this is the K-th agreement
                            fire_on  <= (b_idx == 2'd2);
                            fire_off <= (b_idx == 2'd3);
                            lamp     <= (b_idx == 2'd2);
                            state    <= COOL;
                            cd_cnt   <= 0;
                            streak   <= 0;
                        end else
                            streak <= streak + 1'b1;
                    end else
                        streak <= is_cmd ? 4'd1 : 4'd0;   // start a new streak or clear
                    last <= b_idx;
                end
                COOL: begin
                    if (cd_cnt == COOLDOWN-1) begin state <= LISTEN; streak <= 0; end
                    else cd_cnt <= cd_cnt + 1'b1;
                end
            endcase
        end
    end
endmodule
