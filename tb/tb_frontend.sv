`timescale 1ns/1ps

// Source: 08 Building It Step by Step - Lab Plan and Testing.md
// Front-end test: samples → frame_buffer → fft512 → features, vs Python golden features.
module tb_frontend;
    reg clk = 0, rst = 1;
    always #5 clk = ~clk;                               // 100 MHz

    reg signed [15:0] samples  [0:16127];
    reg signed [7:0]  expected [0:991];
    initial begin
        $readmemh("tv_samples.mem",  samples);
        $readmemh("tv_features.mem", expected);
    end

    // ---- DUT chain (pdm_rx replaced by the testbench) ----
    reg  signed [15:0] sample;
    reg                sample_valid = 0;
    wire               fb_we, frame_done, fft_done, feat_we, row_done, window_full;
    wire        [8:0]  fb_waddr, fft_rd_addr;
    wire signed [15:0] fb_wdata;
    wire signed [24:0] fft_re, fft_im;
    wire        [9:0]  feat_waddr;
    wire signed [7:0]  feat_wdata;
    wire        [5:0]  newest;

    frame_buffer u_fb (.clk(clk), .rst(rst), .sample(sample), .sample_valid(sample_valid),
                       .fft_we(fb_we), .fft_waddr(fb_waddr), .fft_wdata(fb_wdata),
                       .frame_done(frame_done));
    fft512 u_fft (.clk(clk), .rst(rst), .in_we(fb_we), .in_addr(fb_waddr), .in_data(fb_wdata),
                  .start(frame_done), .done(fft_done),
                  .rd_addr(fft_rd_addr), .rd_re(fft_re), .rd_im(fft_im));
    features u_feat (.clk(clk), .rst(rst), .start(fft_done), .fft_rd_addr(fft_rd_addr),
                     .fft_re(fft_re), .fft_im(fft_im), .feat_we(feat_we),
                     .feat_waddr(feat_waddr), .feat_wdata(feat_wdata), .newest(newest),
                     .row_done(row_done), .window_full(window_full));

    // ---- stimulus: one sample every 50 clocks (a hop = 12,800 clocks > FFT time) ----
    integer i, n_out = 0, errors = 0;
    initial begin
        repeat (5) @(posedge clk);
        rst = 0;
        for (i = 0; i < 16128; i = i + 1) begin
            repeat (49) @(posedge clk);
            sample <= samples[i]; sample_valid <= 1'b1;
            @(posedge clk);
            sample_valid <= 1'b0;
        end
        repeat (20000) @(posedge clk);                  // let the last frame finish
        $display("features checked: %0d   mismatches: %0d", n_out, errors);
        $finish;
    end

    // ---- checker ----
    always @(posedge clk) if (feat_we) begin
        if (feat_wdata !== expected[n_out]) begin
            errors = errors + 1;
            if (errors <= 10)
                $display("MISMATCH frame %0d band %0d: got %0d expected %0d",
                         n_out / 16, n_out % 16, feat_wdata, expected[n_out]);
        end
        n_out = n_out + 1;
    end
endmodule
