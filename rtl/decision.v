module decision #(parameter MARGIN = 400, WAIT_TIME = 50)(
    input clk,
    input rst,
    input valid,
    input signed [31:0] s0, s1, s2, s3, //silence, unknown, on, off
    output reg [1:0] best,
    output reg confident,
    output reg lamp
);
    // best and second best score
    reg [1:0] idx;
    reg signed [31:0] top, second;
    always @(*) begin
        idx = 0; top = s0; second = 32'sh80000000;
        if (s1 > top) begin
            second = top; 
            top = s1; 
            idx = 1;
        end else if (s1 > second) second = s1;
        if (s2 > top) begin
            second = top; 
            top = s2; 
            idx = 2;
        end else if (s2 > second) second = s2;
        if (s3 > top) begin
            second = top; 
            top = s3; 
            idx = 3;
        end else if (s3 > second) second = s3;
    end

    wire sure    = (top - second) > MARGIN;
    wire command = sure && (idx == 2 || idx == 3);

    localparam LISTEN = 0, WAIT = 1;
    reg state;
    reg [1:0] last;
    reg [6:0] wait_count;

    always @(posedge clk) begin
        if (rst) begin
            state <= LISTEN; last <= 0; lamp <= 0;
        end
        else if (valid) begin
            best <= idx; confident <= sure;
            case (state)
                LISTEN: begin
                    if (command && idx == last) begin   //same command twice in a row
                        lamp <= (idx == 2); wait_count <= 0;
                        state <= WAIT;
                    end
                    last <= command ? idx : 0;
                end
                WAIT: begin
                    if (wait_count == WAIT_TIME-1) begin
                        state <= LISTEN; last <= 0;
                    end
                    else wait_count <= wait_count + 1;
                end
            endcase
        end
    end
endmodule
