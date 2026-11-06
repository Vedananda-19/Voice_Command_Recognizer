// frame buffer: keeps the last 512 samples, sends a windowed frame every 256
module frame_buffer (
    input  wire               clk,
    input  wire               rst,
    input  wire signed [15:0] sample,
    input  wire               sample_valid,
    output reg                fft_we,
    output reg        [8:0]   fft_waddr,
    output reg signed [15:0]  fft_wdata,
    output reg                frame_done
);
    localparam N = 512, HOP = 256;

    // ring buffer
    reg signed [15:0] ring [0:N-1];
    reg        [8:0]  wptr;                 //wraps by itself
    reg        [7:0]  hop_cnt;              //wraps by itself
    reg        [9:0]  filled;               //stops at 512

    wire hop_tick = sample_valid && (hop_cnt == HOP-1) && (filled >= N-1);

    always @(posedge clk) begin
        if (rst) begin
            wptr <= 0; hop_cnt <= 0; filled <= 0;
        end else if (sample_valid) begin
            wptr    <= wptr + 1'b1;
            hop_cnt <= hop_cnt + 1'b1;
            if (filled != N) filled <= filled + 1'b1;
        end
    end

    // window rom
    reg signed [15:0] win [0:N-1];
    initial $readmemh("hann512_q15.mem", win);   //made by train.py

    // copy control
    reg        busy;
    reg  [8:0] n;                           //position in frame
    reg  [8:0] base;                        //oldest sample
    wire [8:0] raddr = base + n;

    always @(posedge clk) begin
        if (rst) begin
            busy <= 0; n <= 0;
        end else if (hop_tick && !busy) begin
            busy <= 1'b1;
            n    <= 0;
            base <= wptr + 1'b1;            //oldest is the slot after the newest
        end else if (busy) begin
            n <= n + 1'b1;
            if (n == N-1) busy <= 1'b0;
        end
    end

    // read memories
    reg signed [15:0] x1, w1;
    reg        [8:0]  n1;
    reg               v1;
    always @(posedge clk) begin
        if (sample_valid) ring[wptr] <= sample;
        x1 <= ring[raddr];
        w1 <= win[n];
        n1 <= n;
        v1 <= busy;
    end

    // multiply
    reg signed [31:0] prod;
    reg        [8:0]  n2;
    reg               v2;
    always @(posedge clk) begin
        prod <= x1 * w1;
        n2   <= n1;
        v2   <= v1;
    end

    // scale and write to fft
    always @(posedge clk) begin
        fft_we     <= v2;
        fft_waddr  <= n2;
        fft_wdata  <= prod[30:15];                //same as prod >>> 15
        frame_done <= fft_we && (fft_waddr == N-1);
    end
endmodule
