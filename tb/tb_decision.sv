`timescale 1ns/1ps

// TEST 6: decision. Streak, margin and cooldown rules decide when the lamp switches.
module tb_decision;
    reg clk = 0, rst = 1, valid = 0;
    reg signed [31:0] s0 = 0, s1 = 0, s2 = 0, s3 = 0;
    wire [1:0] best;
    wire confident, fire_on, fire_off, lamp;
    integer i, ons = 0, offs = 0;
    always #5 clk = ~clk;

    decision dut (.clk(clk), .rst(rst), .valid(valid), .s0(s0), .s1(s1), .s2(s2), .s3(s3),
                  .best(best), .confident(confident), .fire_on(fire_on), .fire_off(fire_off),
                  .lamp(lamp));          // defaults: MARGIN 2000, K 4, COOLDOWN 62

    always @(posedge clk) begin
        if (fire_on)  ons  = ons + 1;
        if (fire_off) offs = offs + 1;
    end

    // one network result: scores for silence, unknown, on, off
    task infer(input signed [31:0] a, b, c, d);
        begin
            @(negedge clk); s0 = a; s1 = b; s2 = c; s3 = d; valid = 1;
            @(negedge clk); valid = 0;
            repeat (3) @(negedge clk);
        end
    endtask

    localparam signed [31:0] HI = 10000, LO = 0;
    initial begin
        repeat (4) @(negedge clk); rst = 0;

        for (i = 0; i < 3; i = i + 1) infer(LO, LO, HI, LO);      // 3 "on", then silence
        infer(HI, LO, LO, LO);
        if (lamp !== 1'b0 || ons != 0) $fatal(1, "fired on a broken streak");

        for (i = 0; i < 4; i = i + 1) infer(LO, LO, 1000, LO);    // "on" but margin < 2000
        if (lamp !== 1'b0 || ons != 0) $fatal(1, "fired without confidence");

        for (i = 0; i < 4; i = i + 1) infer(LO, LO, HI, LO);      // 4 confident "on"
        if (lamp !== 1'b1 || ons != 1) $fatal(1, "lamp did not turn on");

        for (i = 0; i < 62; i = i + 1) infer(LO, LO, LO, HI);     // "off" during cooldown
        if (lamp !== 1'b1 || offs != 0) $fatal(1, "cooldown ignored");

        for (i = 0; i < 4; i = i + 1) infer(LO, LO, LO, HI);      // 4 "off" after cooldown
        if (lamp !== 1'b0 || offs != 1) $fatal(1, "lamp did not turn off");

        $display("PASS tb_decision: streak, margin and cooldown behave");
        $finish;
    end
endmodule
