// Source: 04 Building the Voice Fingerprint - Features.md
// Bins 2..255 → 16 mel-spaced band sums → log2 (Q3) → int8 → feature RAM row.
module features (
    input  wire               clk,
    input  wire               rst,
    input  wire               start,          // = fft done
    output wire        [8:0]  fft_rd_addr,
    input  wire signed [24:0] fft_re,         // valid 1 clock after fft_rd_addr
    input  wire signed [24:0] fft_im,
    output reg                feat_we,
    output reg         [9:0]  feat_waddr,     // {frame_idx, band}
    output reg  signed [7:0]  feat_wdata,
    output reg         [5:0]  newest,         // frame slot just completed (0..61)
    output reg                row_done,       // 1-clock pulse per completed row
    output reg                window_full     // 62 rows written since reset
);
    // ---- band end ROM ----
    function [7:0] band_end(input [3:0] b);
        case (b)
            4'd0: band_end = 8'd5;    4'd1: band_end = 8'd10;
            4'd2: band_end = 8'd15;   4'd3: band_end = 8'd21;
            4'd4: band_end = 8'd29;   4'd5: band_end = 8'd37;
            4'd6: band_end = 8'd47;   4'd7: band_end = 8'd59;
            4'd8: band_end = 8'd73;   4'd9: band_end = 8'd88;
            4'd10: band_end = 8'd107; 4'd11: band_end = 8'd128;
            4'd12: band_end = 8'd153; 4'd13: band_end = 8'd182;
            4'd14: band_end = 8'd216; default: band_end = 8'd255;
        endcase
    endfunction

    // ---- log2 in Q3: 8*(leading-one position) + next 3 bits ----
    function [7:0] log2q3(input [31:0] v);
        integer i;
        reg [4:0] p;
        reg [2:0] fr;
        reg       found;
        begin
            p = 0; found = 0;
            for (i = 31; i >= 0; i = i - 1)
                if (!found && v[i]) begin p = i; found = 1; end
            if (p >= 3) fr = v >> (p - 3);      // keeps the 3 bits under the leading 1
            else        fr = v << (3 - p);
            log2q3 = found ? ({p, 3'b000} + fr) : 8'd0;
        end
    endfunction

    // ---- stage 0: bin counter ----
    reg       busy;
    reg [7:0] k;                                // bins 2..255
    assign fft_rd_addr = {1'b0, k};

    always @(posedge clk) begin
        if (rst) busy <= 0;
        else if (start && !busy) begin busy <= 1; k <= 8'd2; end
        else if (busy) begin
            if (k == 8'd255) busy <= 0;
            k <= k + 1'b1;
        end
    end

    // FFT read data arrives 1 clock after the address, so delay k and busy to match it
    reg [7:0] k0;  reg v0;
    always @(posedge clk) begin
        k0 <= k;  v0 <= busy;
    end

    // ---- stage 1: absolute values ----
    reg [24:0] ar, ai;  reg [7:0] k1;  reg v1;
    always @(posedge clk) begin
        ar <= fft_re[24] ? -fft_re : fft_re;
        ai <= fft_im[24] ? -fft_im : fft_im;
        k1 <= k0;  v1 <= v0;
    end

    // ---- stage 2: magnitude ≈ max + min/2 ----
    reg [25:0] mag;  reg [7:0] k2;  reg v2;
    always @(posedge clk) begin
        mag <= (ar > ai) ? (ar + (ai >> 1)) : (ai + (ar >> 1));
        k2 <= k1;  v2 <= v1;
    end

    // ---- stage 3: band accumulation ----
    reg [31:0] acc, band_sum;
    reg [3:0]  band, band_out;
    reg        emit;
    always @(posedge clk) begin
        emit <= 1'b0;
        if (rst || start) begin acc <= 0; band <= 0; end
        else if (v2) begin
            if (k2 == band_end(band)) begin
                band_sum <= acc + mag;           // finished band
                band_out <= band;
                emit     <= 1'b1;
                acc      <= 0;
                band     <= band + 1'b1;
            end else
                acc <= acc + mag;
        end
    end

    // ---- stage 4: log2 → int8 → feature RAM; frame bookkeeping ----
    reg [5:0] fidx;                              // current row slot 0..61
    reg [5:0] rows;                              // saturating row count
    wire [7:0] L = log2q3(band_sum);
    always @(posedge clk) begin
        feat_we  <= 1'b0;
        row_done <= 1'b0;
        if (rst) begin
            fidx <= 0; rows <= 0; window_full <= 0;
        end else if (emit) begin
            feat_we    <= 1'b1;
            feat_waddr <= {fidx, band_out};
            feat_wdata <= {~L[7], L[6:0]};       // L - 128 as signed int8
            if (band_out == 4'd15) begin         // row complete
                newest   <= fidx;
                row_done <= 1'b1;
                fidx     <= (fidx == 6'd61) ? 6'd0 : fidx + 1'b1;
                if (rows != 6'd62) rows <= rows + 1'b1;
                if (rows == 6'd61) window_full <= 1'b1;
            end
        end
    end
endmodule
