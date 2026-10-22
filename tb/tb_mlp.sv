`timescale 1ns/1ps

// TEST 5: MLP. Golden features in → 32 hidden values and 4 scores must match Python exactly.
// SHIFT1 must be the value printed by train.py (override with -Ptb_mlp.SHIFT1=<value>).
module tb_mlp;
    parameter SHIFT1 = 10;
    reg clk = 0, rst = 1, start = 0;
    always #5 clk = ~clk;

    reg signed [7:0]  feat_ram [0:1023];
    reg signed [7:0]  exp_h    [0:31];
    reg signed [31:0] exp_s    [0:3];
    initial begin
        $readmemh("tv_features.mem", feat_ram);
        $readmemh("tv_hidden.mem",   exp_h);
        $readmemh("tv_scores.mem",   exp_s);
    end

    // feature RAM with a 1-clock read, same as in top
    wire        [9:0] feat_raddr;
    reg  signed [7:0] feat_rdata;
    always @(posedge clk) feat_rdata <= feat_ram[feat_raddr];

    wire done;
    wire signed [31:0] s0, s1, s2, s3;
    mlp #(.SHIFT1(SHIFT1)) dut (.clk(clk), .rst(rst), .start(start), .oldest(6'd0),
        .feat_raddr(feat_raddr), .feat_rdata(feat_rdata), .done(done),
        .score0(s0), .score1(s1), .score2(s2), .score3(s3));

    integer i, errors = 0;
    task check_score(input integer k, input signed [31:0] got);
        if (got !== exp_s[k]) begin
            errors = errors + 1;
            $display("score %0d: got %0d expected %0d", k, got, exp_s[k]);
        end
    endtask

    initial begin
        repeat (5) @(negedge clk); rst = 0;
        @(negedge clk); start = 1;
        @(negedge clk); start = 0;
        wait (done === 1'b1);
        @(negedge clk);
        for (i = 0; i < 32; i = i + 1)
            if (dut.h[i] !== exp_h[i]) begin
                errors = errors + 1;
                $display("hidden %0d: got %0d expected %0d", i, dut.h[i], exp_h[i]);
            end
        check_score(0, s0); check_score(1, s1); check_score(2, s2); check_score(3, s3);
        if (errors) $fatal(1, "MLP had %0d mismatches", errors);
        $display("PASS tb_mlp: 32 hidden values and 4 scores match (%0d %0d %0d %0d)", s0, s1, s2, s3);
        $finish;
    end
    initial begin #2000000; $fatal(1, "MLP timeout"); end
endmodule
