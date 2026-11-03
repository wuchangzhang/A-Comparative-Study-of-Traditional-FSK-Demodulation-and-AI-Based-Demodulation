`timescale 1ns/1ps
module tb_arithmetic;
    import control_pkg::*;
    logic clk=0,rst_n=0;
    always #5 clk=~clk;
    logic [15:0] frequency_hz=0;
    wire [7:0] seg_data_0,seg_data_1,seg_cs;
    dds_display display(.clk(clk),.rst_n(rst_n),.frequency_hz(frequency_hz),
        .wave_sel(2'd0),.step_sel(2'd0),.seg_data_0(seg_data_0),.seg_data_1(seg_data_1),.seg_cs(seg_cs));
    integer low_code,high_code,expected;
    reg [31:0] words[0:2100];
    reg [63:0] numerator;
    task check_display(input integer number);
        begin
            frequency_hz=number; repeat(40) @(negedge clk);
            expected=((number/1000)%10)*4096+((number/100)%10)*256+((number/10)%10)*16+number%10;
            if(display.bcd_ready!=expected) $fatal(1,"BCD conversion %d",number);
        end
    endtask
    initial begin
        $readmemh("fcw_100ksps.mem",words);
        for(integer hz=0;hz<=2100;hz=hz+1) begin
            numerator=64'd4294967296*hz+50000;
            if(words[hz]!=numerator/100000) $fatal(1,"FCW table %d",hz);
        end
        for(integer a=0;a<256;a=a+1) for(integer b=-129;b<=128;b=b+1) begin
            low_code=128+(a==255 ? -128 : ((-128*a)>>>8))+b;
            high_code=128+(a==255 ? 127 : ((127*a)>>>8))+b;
            if(legal_shape(a,b)!=(low_code>=0 && high_code<=255 && b>=-128 && b<=127))
                $fatal(1,"Shape validation %d %d",a,b);
        end
        for(integer raw=0;raw<4096;raw=raw+1) begin
            numerator=raw*190+2047;
            if((numerator>>12)+(((numerator&4095)+(numerator>>12))>=4095)!=numerator/4095)
                $fatal(1,"Knob mapping %d",raw);
        end
        repeat(3) @(negedge clk); rst_n=1;
        check_display(0); check_display(128); check_display(1000); check_display(2000);
        check_display(9999); check_display(10000); check_display(65535);
        $display("PASS tb_arithmetic: all FCWs, 66048 amplitude/bias pairs, all knob codes, decimal display wrap"); $finish;
    end
endmodule
