// Source: 08 Building It Step by Step - Lab Plan and Testing.md
// Voice command recognizer — top level (Nexys 4 DDR, XC7A100T).
module top (
    input  wire        clk,          // CLK100MHZ, pin E3
    input  wire        cpu_resetn,   // CPU_RESETN button, pin C12, ACTIVE-LOW
    output wire        m_clk,        // on-board PDM mic
    output wire        m_lrsel,
    input  wire        m_data,
    input  wire        btn_c,        // BTNC, pin N17: hold to stream audio over UART
    output wire        uart_txd,     // UART_RXD_OUT, pin D4 (FPGA → PC)
    output wire [15:0] led
);
    // ---- reset: invert (button is active-low) and synchronise (2 flip-flops) ----
    reg rst_meta, rst;
    always @(posedge clk) begin rst_meta <= ~cpu_resetn; rst <= rst_meta; end

    // ---- stage 1: microphone ----
    wire signed [15:0] sample;
    wire               sample_valid;
    pdm_rx u_mic (.clk(clk), .rst(rst), .m_clk(m_clk), .m_lrsel(m_lrsel), .m_data(m_data),
                  .sample(sample), .sample_valid(sample_valid));

    // ---- stage 2: frames ----
    wire               fb_we, frame_done;
    wire        [8:0]  fb_waddr;
    wire signed [15:0] fb_wdata;
    frame_buffer u_fb (.clk(clk), .rst(rst), .sample(sample), .sample_valid(sample_valid),
                       .fft_we(fb_we), .fft_waddr(fb_waddr), .fft_wdata(fb_wdata),
                       .frame_done(frame_done));

    // ---- stage 3: FFT ----
    wire               fft_done;
    wire        [8:0]  fft_rd_addr;
    wire signed [24:0] fft_re, fft_im;
    fft512 u_fft (.clk(clk), .rst(rst), .in_we(fb_we), .in_addr(fb_waddr), .in_data(fb_wdata),
                  .start(frame_done), .done(fft_done),
                  .rd_addr(fft_rd_addr), .rd_re(fft_re), .rd_im(fft_im));

    // ---- stage 4: features + feature RAM (1024 × 8, simple dual-port BRAM) ----
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

    // ---- stage 5: network ----
    wire               mlp_done;
    wire signed [31:0] s0, s1, s2, s3;
    mlp #(.SHIFT1(11)) u_mlp (                         // SHIFT1 printed by quant.py
        .clk(clk), .rst(rst), .start(row_done & window_full), .oldest(oldest),
        .feat_raddr(feat_raddr), .feat_rdata(feat_rdata), .done(mlp_done),
        .score0(s0), .score1(s1), .score2(s2), .score3(s3));

    // ---- stage 6: decision ----
    wire [1:0] best;
    wire       confident, lamp;
    decision #(.MARGIN(32'sd500), .K(4), .COOLDOWN(62)) u_dec (   // MARGIN from note 07
        .clk(clk), .rst(rst), .valid(mlp_done), .s0(s0), .s1(s1), .s2(s2), .s3(s3),
        .best(best), .confident(confident), .fire_on(), .fire_off(), .lamp(lamp));

    // ---- debug: loudness bar (log scale) on LED[15:8] ----
    reg [15:0] level;
    always @(posedge clk) if (sample_valid) level <= sample[15] ? -sample : sample;
    genvar g;
    generate for (g = 0; g < 8; g = g + 1) begin : bar
        assign led[8 + g] = (level[15:7] > (9'd1 << g));
    end endgenerate

    // ---- recording: while BTNC is held, send each sample as 2 bytes (low byte first) ----
    reg       btn_meta, btn;
    reg       tx_start, send_hi;
    reg [7:0] tx_data, hi_byte;
    wire      tx_busy;
    always @(posedge clk) begin btn_meta <= btn_c; btn <= btn_meta; end

    always @(posedge clk) begin
        tx_start <= 1'b0;
        if (rst) send_hi <= 1'b0;
        else if (sample_valid && btn && !tx_busy && !send_hi) begin
            tx_data <= sample[7:0];  hi_byte <= sample[15:8];
            tx_start <= 1'b1;        send_hi <= 1'b1;
        end else if (send_hi && !tx_busy && !tx_start) begin
            tx_data <= hi_byte;
            tx_start <= 1'b1;        send_hi <= 1'b0;
        end
    end

    uart_tx #(.CLKS_PER_BIT(109)) u_tx (                // 100 MHz / 109 ≈ 921,600 baud
        .clk(clk), .rst(rst), .start(tx_start), .data(tx_data), .tx(uart_txd), .busy(tx_busy));

    assign led[7:0] = {3'b000, confident, best, btn, lamp};
endmodule
