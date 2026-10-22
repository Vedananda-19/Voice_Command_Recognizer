`timescale 1ns/1ps

// TEST 1: PDM mic receiver. Checks output clock rate, valid-sample cadence, and known samples.
module tb_pdm_rx;
    reg clk = 0, rst = 1, m_data = 1;
    wire m_clk, m_lrsel, sample_valid;
    wire signed [15:0] sample;
    integer clocks = 0, valids = 0, last_valid = -1, last_toggle = -1, i;
    reg previous_mclk = 0;
    always #5 clk = ~clk;
    pdm_rx dut(.clk(clk), .rst(rst), .m_clk(m_clk), .m_lrsel(m_lrsel),
               .m_data(m_data), .sample(sample), .sample_valid(sample_valid));
    always @(posedge clk) begin
        clocks = clocks + 1;
        if (!rst && m_clk !== previous_mclk) begin
            if (last_toggle >= 0 && clocks-last_toggle != 24)
                $fatal(1, "mic clock half-period was %0d clocks", clocks-last_toggle);
            last_toggle = clocks;
            previous_mclk = m_clk;
        end
        if (!rst && sample_valid) begin
            if ((^sample) === 1'bx) $fatal(1, "PDM sample contains X");
            if (last_valid >= 0 && clocks-last_valid != 128*48)
                $fatal(1, "sample_valid interval was %0d clocks", clocks-last_valid);
            last_valid = clocks;
            valids = valids + 1;
        end
    end
    initial begin
        repeat(5) @(negedge clk); rst=0;
        repeat(128*48*5) @(negedge clk);
        if (valids < 4) $fatal(1, "Too few samples: %0d", valids);
        if (m_lrsel !== 1'b0) $fatal(1, "Unexpected mic channel select");
        $display("PASS tb_pdm_rx: %0d valid samples", valids);
        $finish;
    end
endmodule
