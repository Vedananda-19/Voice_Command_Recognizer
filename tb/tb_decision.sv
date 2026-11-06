`timescale 1ns/1ps

// TEST 6: decision. Twice in a row, margin and wait rules decide when the lamp switches.
module tb_decision;
    reg clk = 0, rst = 1, valid = 0;
    reg signed [31:0] s0 = 0, s1 = 0, s2 = 0, s3 = 0;
    wire [1:0] best;
    wire confident, lamp;
    integer i;
    always #5 clk = ~clk;

    decision dut (.clk(clk), .rst(rst), .valid(valid), .s0(s0), .s1(s1), .s2(s2), .s3(s3),
                  .best(best), .confident(confident), .lamp(lamp));   // defaults: MARGIN 400, WAIT_TIME 50

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

        infer(LO, LO, HI, LO);                                    // one "on", then silence
        infer(HI, LO, LO, LO);
        infer(LO, LO, HI, LO);                                    // one "on" again
        if (lamp !== 1'b0) $fatal(1, "fired on a single guess");

        infer(LO, LO, LO, HI);                                    // "on" then "off": not the same
        if (lamp !== 1'b0) $fatal(1, "fired on two different commands");

        infer(HI, LO, LO, LO);
        for (i = 0; i < 2; i = i + 1) infer(LO, LO, 300, LO);     // "on" but margin < 400
        if (lamp !== 1'b0) $fatal(1, "fired without confidence");

        for (i = 0; i < 2; i = i + 1) infer(LO, LO, HI, LO);      // two confident "on"
        if (lamp !== 1'b1) $fatal(1, "lamp did not turn on");

        for (i = 0; i < 50; i = i + 1) infer(LO, LO, LO, HI);     // "off" while waiting
        if (lamp !== 1'b1) $fatal(1, "wait ignored");

        for (i = 0; i < 2; i = i + 1) infer(LO, LO, LO, HI);      // two "off" after the wait
        if (lamp !== 1'b0) $fatal(1, "lamp did not turn off");

        $display("PASS tb_decision: twice in a row, margin and wait behave");
        $finish;
    end
endmodule
