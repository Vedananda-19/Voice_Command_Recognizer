// Source: 03 Seeing Frequencies - The FFT.md
// 512-point in-place radix-2 DIT FFT. One butterfly every 4 clocks.
module fft512 (
    input  wire               clk,
    input  wire               rst,
    // load port: natural-order sample index n (from frame_buffer)
    input  wire               in_we,
    input  wire        [8:0]  in_addr,
    input  wire signed [15:0] in_data,
    input  wire               start,          // = frame_done
    output reg                done,           // 1-clock pulse
    // result port: bin k in natural order, data valid 1 clock after rd_addr
    input  wire        [8:0]  rd_addr,
    output wire signed [24:0] rd_re,
    output wire signed [24:0] rd_im
);
    localparam DW = 25;

    function [8:0] bitrev9(input [8:0] v);
        integer i;
        for (i = 0; i < 9; i = i + 1) bitrev9[i] = v[8-i];
    endfunction

    // ---------- controller ----------
    localparam S_IDLE = 3'd0, S_ADDR = 3'd1, S_READ = 3'd2, S_CALC = 3'd3, S_WRITE = 3'd4;
    reg [2:0] state;
    reg [3:0] s;                               // stage 0..8
    reg [7:0] b;                               // butterfly 0..255

    wire [8:0] half = 9'd1 << s;
    wire [8:0] k    = {1'b0, b} & (half - 1'b1);
    wire [8:0] top  = (({1'b0, b} >> s) << (s + 1)) | k;
    wire [8:0] bot  = top | half;
    wire [7:0] tw   = k << (4'd8 - s);

    always @(posedge clk) begin
        done <= 1'b0;
        if (rst) state <= S_IDLE;
        else case (state)
            S_IDLE:  if (start) begin s <= 0; b <= 0; state <= S_ADDR; end
            S_ADDR:  state <= S_READ;
            S_READ:  state <= S_CALC;
            S_CALC:  state <= S_WRITE;
            S_WRITE: begin
                if (b == 8'd255) begin
                    b <= 0;
                    if (s == 4'd8) begin state <= S_IDLE; done <= 1'b1; end
                    else begin s <= s + 1'b1; state <= S_ADDR; end
                end else begin
                    b <= b + 1'b1; state <= S_ADDR;
                end
            end
            default: state <= S_IDLE;
        endcase
    end

    // ---------- twiddle ROM (1-clock read) ----------
    reg signed [15:0] tw_re [0:255], tw_im [0:255];
    initial begin
        $readmemh("tw512_re_q15.mem", tw_re);
        $readmemh("tw512_im_q15.mem", tw_im);
    end
    reg signed [15:0] wr, wi;
    always @(posedge clk) begin wr <= tw_re[tw]; wi <= tw_im[tw]; end

    // ---------- butterfly ----------
    wire signed [DW-1:0] xr, xi, yr, yi;
    reg  [2*DW-1:0] a_dout, b_dout;
    butterfly #(.DW(DW)) bf (
        .clk(clk),
        .ar(a_dout[2*DW-1:DW]), .ai(a_dout[DW-1:0]),
        .br(b_dout[2*DW-1:DW]), .bi(b_dout[DW-1:0]),
        .wr(wr), .wi(wi),
        .xr(xr), .xi(xi), .yr(yr), .yi(yi)
    );

    // ---------- port muxing ----------
    reg  [8:0]      a_addr, b_addr;
    reg             a_we,   b_we;
    reg  [2*DW-1:0] a_din,  b_din;
    always @(*) begin
        b_addr = bot;  b_we = (state == S_WRITE);  b_din = {yr, yi};
        if (state == S_IDLE) begin
            a_addr = in_we ? bitrev9(in_addr) : rd_addr;          // load or read results
            a_we   = in_we;
            a_din  = {{(DW-16){in_data[15]}}, in_data, {DW{1'b0}}}; // re = sign-extended, im = 0
        end else begin
            a_addr = top;  a_we = (state == S_WRITE);  a_din = {xr, xi};
        end
    end

    // ---------- true dual-port RAM, 512 × 50 bits ----------
    reg [2*DW-1:0] mem [0:511];
    always @(posedge clk) begin
        if (a_we) mem[a_addr] <= a_din;
        a_dout <= mem[a_addr];
    end
    always @(posedge clk) begin
        if (b_we) mem[b_addr] <= b_din;
        b_dout <= mem[b_addr];
    end

    assign rd_re = a_dout[2*DW-1:DW];
    assign rd_im = a_dout[DW-1:0];
endmodule
