`timescale 1ns/1ps

// TEST 3: FFT. A single impulse at sample 0 has a flat real spectrum.
module tb_fft512;
    reg clk=0, rst=1, in_we=0, start=0;
    reg [8:0] in_addr=0, rd_addr=0;
    reg signed [15:0] in_data=0;
    wire done;
    wire signed [24:0] rd_re, rd_im;
    integer i, errors=0;
    real angle;
    always #5 clk=~clk;
    fft512 dut(.clk(clk),.rst(rst),.in_we(in_we),.in_addr(in_addr),.in_data(in_data),
       .start(start),.done(done),.rd_addr(rd_addr),.rd_re(rd_re),.rd_im(rd_im));
    initial begin
        // Populate ROMs directly, avoiding external .mem files for this simulation.
        #1;
        for(i=0;i<256;i=i+1) begin
            angle=6.2831853071795864769*i/512.0;
            dut.tw_re[i]=$rtoi(32767.0*$cos(angle));
            dut.tw_im[i]=$rtoi(-32767.0*$sin(angle));
        end
        repeat(4) @(negedge clk); rst=0;
        for(i=0;i<512;i=i+1) begin
            @(negedge clk); in_we=1; in_addr=i[8:0];
            in_data=(i==0)?16'sd256:16'sd0;
        end
        @(negedge clk); in_we=0; in_data=0; start=1;
        @(negedge clk); start=0;
        wait(done===1'b1);
        @(negedge clk);
        for(i=0;i<512;i=i+1) begin
            rd_addr=i[8:0]; @(posedge clk); #1;
            if ((rd_re < 25'sd248) || (rd_re > 25'sd264) ||
                (rd_im < -25'sd8) || (rd_im > 25'sd8)) begin
                errors=errors+1;
                if(errors<=8) $display("bin %0d: got %0d + j%0d",i,rd_re,rd_im);
            end
        end
        if(errors) $fatal(1,"FFT impulse spectrum had %0d bad bins",errors);
        $display("PASS tb_fft512: all 512 bins within tolerance");
        $finish;
    end
    initial begin #20000000; $fatal(1,"FFT timeout"); end
endmodule
