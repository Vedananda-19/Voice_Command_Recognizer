// butterfly: x = a + w*b, y = a - w*b
module butterfly #(parameter DW = 25) (
    input  wire                 clk,
    input  wire signed [DW-1:0] ar, ai, br, bi,
    input  wire signed [15:0]   wr, wi,          //twiddle
    output reg  signed [DW-1:0] xr, xi, yr, yi
);
    // multiply
    reg signed [DW+15:0] p_rr, p_ii, p_ri, p_ir;
    reg signed [DW-1:0]  ar1, ai1;
    always @(posedge clk) begin
        p_rr <= br * wr;   p_ii <= bi * wi;
        p_ri <= br * wi;   p_ir <= bi * wr;
        ar1  <= ar;        ai1  <= ai;           //delay a to match
    end

    // combine and scale
    wire signed [DW+16:0] tr_full = p_rr - p_ii;
    wire signed [DW+16:0] ti_full = p_ri + p_ir;
    wire signed [DW-1:0]  tr = tr_full >>> 15;
    wire signed [DW-1:0]  ti = ti_full >>> 15;

    // add and subtract
    always @(posedge clk) begin
        xr <= ar1 + tr;   xi <= ai1 + ti;
        yr <= ar1 - tr;   yi <= ai1 - ti;
    end
endmodule
