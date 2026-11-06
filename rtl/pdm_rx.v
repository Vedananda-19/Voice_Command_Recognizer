// pdm_rx: mic bits to 16 bit samples (cic filter)
module pdm_rx (
    input  wire               clk,
    input  wire               rst,
    output reg                m_clk,
    output wire               m_lrsel,
    input  wire               m_data,
    output reg signed [15:0]  sample,
    output reg                sample_valid
);
    assign m_lrsel = 1'b0;                       //left channel

    // mic clock, about 2 MHz
    reg  [4:0] div;
    wire       toggle = (div == 5'd23);
    always @(posedge clk) begin
        if (rst)         begin div <= 0; m_clk <= 1'b0; end
        else if (toggle) begin div <= 0; m_clk <= ~m_clk; end
        else             div <= div + 1'b1;
    end
    // read the bit just before the rising edge
    wire take = ~m_clk && (div == 5'd22);

    // synchronizer
    reg d_meta, d_s;
    always @(posedge clk) begin
        d_meta <= m_data;
        d_s    <= d_meta;
    end

    // integrators
    wire signed [29:0] x = d_s ? 30'sd1 : -30'sd1;
    reg  signed [29:0] i1, i2, i3, i4;
    reg         [6:0]  dec;
    reg                dec_tick;
    always @(posedge clk) begin
        dec_tick <= 1'b0;
        if (rst) begin
            i1 <= 0; i2 <= 0; i3 <= 0; i4 <= 0; dec <= 0;
        end else if (take) begin
            i1 <= i1 + x;                             //overflow is fine here
            i2 <= i2 + i1;
            i3 <= i3 + i2;
            i4 <= i4 + i3;
            dec <= dec + 1'b1;
            if (dec == 7'd127) dec_tick <= 1'b1;
        end
    end

    // combs and output
    reg signed [29:0] c1, c2, c3, c4, z0, z1, z2, z3;   //z holds the previous input
    always @(posedge clk) begin
        sample_valid <= 1'b0;
        if (rst) begin
            c1 <= 0; c2 <= 0; c3 <= 0; c4 <= 0;
            z0 <= 0; z1 <= 0; z2 <= 0; z3 <= 0;
        end else if (dec_tick) begin
            c1 <= i4 - z0;  z0 <= i4;
            c2 <= c1 - z1;  z1 <= c1;
            c3 <= c2 - z2;  z2 <= c2;
            c4 <= c3 - z3;  z3 <= c3;
            // scale down to 16 bits
            sample <= (c4 >= 30'sd268435456) ? 16'sd32767 : c4[28:13];
            sample_valid <= 1'b1;
        end
    end
endmodule
