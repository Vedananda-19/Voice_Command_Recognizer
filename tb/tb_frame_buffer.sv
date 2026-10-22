`timescale 1ns/1ps

// TEST 2: frame buffer/window. Constant samples and unity window make every output predictable.
module tb_frame_buffer;
    reg clk=0, rst=1, sample_valid=0;
    reg signed [15:0] sample=16'sd1000;
    wire fft_we, frame_done;
    wire [8:0] fft_waddr;
    wire signed [15:0] fft_wdata;
    integer i, writes=0, frames=0, expected_addr=0;
    always #5 clk=~clk;
    frame_buffer dut(.clk(clk), .rst(rst), .sample(sample), .sample_valid(sample_valid),
      .fft_we(fft_we), .fft_waddr(fft_waddr), .fft_wdata(fft_wdata), .frame_done(frame_done));
    always @(posedge clk) if (!rst) begin
        if (fft_we) begin
            if (fft_waddr !== expected_addr[8:0]) $fatal(1,"Frame address expected %0d got %0d",expected_addr,fft_waddr);
            if (fft_wdata !== 16'sd999) $fatal(1,"Windowed data expected 999 got %0d at %0d",fft_wdata,fft_waddr);
            writes=writes+1;
            if (expected_addr==511) expected_addr=0; else expected_addr=expected_addr+1;
        end
        if(frame_done) frames=frames+1;
    end
    initial begin
        // Override the design's ROM for a deterministic unity-window test.
        #1; for(i=0;i<512;i=i+1) dut.win[i]=16'sd32767;
        repeat(4) @(negedge clk); rst=0;
        for(i=0;i<1800;i=i+1) begin
            @(negedge clk); sample_valid=1;
            @(negedge clk); sample_valid=0;
        end
        repeat(600) @(negedge clk);
        if(writes < 512) $fatal(1,"Expected at least one full frame; writes=%0d",writes);
        if(writes%512 != 0) $fatal(1,"Partial frame write count: %0d",writes);
        if(frames != writes/512) $fatal(1,"frame_done count %0d, writes imply %0d",frames,writes/512);
        $display("PASS tb_frame_buffer: %0d samples written, %0d frames",writes,frames);
        $finish;
    end
endmodule
