// Source: 03 Seeing Frequencies - The FFT.md
// Radix-2 butterfly, 2 register stages.  a' = a + W*b,  b' = a - W*b
module butterfly #(parameter DW = 25) (
    input  wire                 clk,
    input  wire signed [DW-1:0] ar, ai, br, bi,
    input  wire signed [15:0]   wr, wi,          // twiddle, Q15
    output reg  signed [DW-1:0] xr, xi, yr, yi   // x = a', y = b'
);
    // stage 1: the four real products (4 DSP48 slices)
    reg signed [DW+15:0] p_rr, p_ii, p_ri, p_ir;
    reg signed [DW-1:0]  ar1, ai1;
    always @(posedge clk) begin
        p_rr <= br * wr;   p_ii <= bi * wi;      // t_r = br*wr - bi*wi
        p_ri <= br * wi;   p_ir <= bi * wr;      // t_i = br*wi + bi*wr
        ar1  <= ar;        ai1  <= ai;           // delay a to line up with t
    end

    // combine and rescale Q15 → data scale
    wire signed [DW+16:0] tr_full = p_rr - p_ii;
    wire signed [DW+16:0] ti_full = p_ri + p_ir;
    wire signed [DW-1:0]  tr = tr_full >>> 15;
    wire signed [DW-1:0]  ti = ti_full >>> 15;

    // stage 2: add / subtract
    always @(posedge clk) begin
        xr <= ar1 + tr;   xi <= ai1 + ti;
        yr <= ar1 - tr;   yi <= ai1 - ti;
    end
endmodule
