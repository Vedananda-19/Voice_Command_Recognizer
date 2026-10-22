// UART transmitter, 8 data bits, no parity, 1 stop bit (8N1).
// Pulse start for one clock with data; busy stays high until the stop bit ends.
module uart_tx #(
    parameter CLKS_PER_BIT = 109
)(
    input  wire       clk,
    input  wire       rst,
    input  wire       start,
    input  wire [7:0] data,
    output wire       tx,
    output reg        busy
);
    reg [9:0] shift;                            // {stop, data[7:0], start}, sent LSB first
    reg [3:0] bits;                             // which of the 10 bits is on the line
    reg [7:0] cnt;                              // clocks within the current bit

    always @(posedge clk) begin
        if (rst) busy <= 1'b0;
        else if (!busy && start) begin
            shift <= {1'b1, data, 1'b0};
            bits  <= 0;
            cnt   <= 0;
            busy  <= 1'b1;
        end else if (busy) begin
            if (cnt == CLKS_PER_BIT-1) begin
                cnt   <= 0;
                shift <= {1'b1, shift[9:1]};
                if (bits == 4'd9) busy <= 1'b0;
                else              bits <= bits + 1'b1;
            end else
                cnt <= cnt + 1'b1;
        end
    end

    assign tx = busy ? shift[0] : 1'b1;         // line idles high
endmodule
