`timescale 1ns/1ps

// Whole pipeline after the mic, same wiring as top:
// wav samples → frame_buffer → fft512 → features → feature RAM → mlp → decision.
// Run by python/try_wav.py, which sets these parameters from rtl/top.v.
module tb_wav;
    parameter NSAMP    = 16128;
    parameter SHIFT1   = 10;
    parameter MARGIN   = 2000;
    parameter K        = 4;
    parameter COOLDOWN = 62;

    reg clk = 0, rst = 1;
    always #5 clk = ~clk;

    reg signed [15:0] samples [0:NSAMP-1];
    initial $readmemh("wav_samples.mem", samples);

    reg  signed [15:0] sample;
    reg                sample_valid = 0;

    // ---- frames ----
    wire               fb_we, frame_done;
    wire        [8:0]  fb_waddr;
    wire signed [15:0] fb_wdata;
    frame_buffer u_fb (.clk(clk), .rst(rst), .sample(sample), .sample_valid(sample_valid),
                       .fft_we(fb_we), .fft_waddr(fb_waddr), .fft_wdata(fb_wdata),
                       .frame_done(frame_done));

    // ---- FFT ----
    wire               fft_done;
    wire        [8:0]  fft_rd_addr;
    wire signed [24:0] fft_re, fft_im;
    fft512 u_fft (.clk(clk), .rst(rst), .in_we(fb_we), .in_addr(fb_waddr), .in_data(fb_wdata),
                  .start(frame_done), .done(fft_done),
                  .rd_addr(fft_rd_addr), .rd_re(fft_re), .rd_im(fft_im));

    // ---- features + feature RAM ----
    wire               feat_we, row_done, window_full;
    wire        [9:0]  feat_waddr, feat_raddr;
    wire signed [7:0]  feat_wdata;
    wire        [5:0]  newest;
    features u_feat (.clk(clk), .rst(rst), .start(fft_done), .fft_rd_addr(fft_rd_addr),
                     .fft_re(fft_re), .fft_im(fft_im), .feat_we(feat_we),
                     .feat_waddr(feat_waddr), .feat_wdata(feat_wdata), .newest(newest),
                     .row_done(row_done), .window_full(window_full));

    reg signed [7:0] feat_ram [0:1023];
    reg signed [7:0] feat_rdata;
    always @(posedge clk) begin
        if (feat_we) feat_ram[feat_waddr] <= feat_wdata;
        feat_rdata <= feat_ram[feat_raddr];
    end
    wire [5:0] oldest = (newest == 6'd61) ? 6'd0 : newest + 1'b1;

    // ---- network ----
    wire               mlp_done;
    wire signed [31:0] s0, s1, s2, s3;
    mlp #(.SHIFT1(SHIFT1)) u_mlp (
        .clk(clk), .rst(rst), .start(row_done & window_full), .oldest(oldest),
        .feat_raddr(feat_raddr), .feat_rdata(feat_rdata), .done(mlp_done),
        .score0(s0), .score1(s1), .score2(s2), .score3(s3));

    // ---- decision ----
    wire [1:0] best;
    wire       confident, fire_on, fire_off, lamp;
    decision #(.MARGIN(MARGIN), .K(K), .COOLDOWN(COOLDOWN)) u_dec (
        .clk(clk), .rst(rst), .valid(mlp_done), .s0(s0), .s1(s1), .s2(s2), .s3(s3),
        .best(best), .confident(confident), .fire_on(fire_on), .fire_off(fire_off), .lamp(lamp));

    // ---- stimulus: one sample every 200 clocks, so a hop (51,200 clocks) is longer
    //      than FFT + features + MLP (~42,000). The board has 6,250 clocks per sample. ----
    integer i, n_inf = 0;
    initial begin
        repeat (5) @(posedge clk);
        rst = 0;
        for (i = 0; i < NSAMP; i = i + 1) begin
            repeat (199) @(posedge clk);
            sample <= samples[i]; sample_valid <= 1'b1;
            @(posedge clk);
            sample_valid <= 1'b0;
        end
        repeat (60000) @(posedge clk);                  // let the last inference finish
        $display("DONE %0d %0d", n_inf, lamp);
        $finish;
    end

    // ---- report every inference and every command ----
    always @(posedge clk) begin
        if (mlp_done) begin
            $display("SCORES %0d %0d %0d %0d %0d", n_inf, s0, s1, s2, s3);
            n_inf = n_inf + 1;
        end
        if (fire_on)  $display("FIRE on %0d",  n_inf - 1);  // fires 1 clock after mlp_done
        if (fire_off) $display("FIRE off %0d", n_inf - 1);
    end
endmodule
