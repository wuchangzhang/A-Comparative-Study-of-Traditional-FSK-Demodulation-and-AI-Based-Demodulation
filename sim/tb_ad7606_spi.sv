`timescale 1ns/1ps
module tb_ad7606_spi;
    logic clk=0,rst_n=0,busy=0,dout=0;
    always #5 clk=~clk;
    wire convst,cs_n,sclk,reset_adc,valid,error,clip;
    wire signed [15:0] sample_data;
    wire [31:0] sample_index;
    wire [3:0] state_code,error_reason;
    wire busy_level,dout_level;
    wire [31:0] reset_count;
    logic [15:0] code=16'h255a,latched_code;
    logic [127:0] frame;
    integer rises=0,falls=0,count=0,error_count=0,conversions=0;
    integer mode=0;
    time previous_start=0,low_start=0,cs_start=0;
    ad7606_spi_rx #(.BUSY_TIMEOUT_CLKS(800)) dut(
        .clk(clk),.rst_n(rst_n),.adc_busy(busy),.adc_dout(dout),
        .adc_convst(convst),.adc_cs_n(cs_n),.adc_sclk(sclk),.adc_rst_n(reset_adc),
        .adc_sample_data(sample_data),.adc_sample_valid(valid),.sample_index(sample_index),
        .adc_error(error),.adc_clip(clip),
        .adc_state_code(state_code),.adc_busy_level(busy_level),.adc_dout_level(dout_level),
        .adc_error_reason(error_reason),.adc_reset_count(reset_count));
    always @(negedge convst) low_start=$time;
    always @(posedge convst) if(rst_n && !reset_adc) begin
        if(busy) $fatal(1,"conversion started while BUSY");
        if($time-low_start<25) $fatal(1,"short CONVST low");
        if(previous_start!=0 && mode==0 && count>1 && $time-previous_start!=20000)
            $fatal(1,"not 50 kSPS: %0t",$time-previous_start);
        previous_start=$time; conversions=conversions+1;
        if(mode!=1) begin
            #30 busy=1;
            if(mode!=2) begin #4120 busy=0; end
        end
    end
    always @(posedge reset_adc) begin busy=0; previous_start=0; end
    always @(negedge cs_n) begin
        if(busy) $fatal(1,"read during conversion");
        rises=0; falls=0; cs_start=$time; latched_code=code;
        frame={code,16'h0123,16'h4567,16'h89ab,16'hcdef,16'h1357,16'h2468,16'hfedc};
        #27 dout=frame[127];
    end
    always @(negedge sclk) if(!cs_n) falls=falls+1;
    // AD7606 datasheet: data changes after RISING SCLK, including a
    // worst-case 27 ns access delay. The first MSB is exposed by CS.
    always @(posedge sclk) if(!cs_n) begin
        rises=rises+1;
        #27 dout=(rises<128) ? frame[127-rises] : 1'b0;
    end
    always @(posedge cs_n) if(rst_n && rises!=0) begin
        if(rises!=128 || falls!=128) $fatal(1,"incomplete read: %0d/%0d",rises,falls);
        if($time-cs_start<12800) $fatal(1,"read too short");
    end
    always @(negedge clk) begin
        if(valid) begin
            count=count+1;
            if(sample_data!==$signed(latched_code)) $fatal(1,"AIN1 mismatch %h != %h",sample_data,latched_code);
            if(sample_index!=count) $fatal(1,"sample index");
            if(clip!==($signed(latched_code)>=16'sh7a00 || $signed(latched_code)<=-16'sh7a00)) $fatal(1,"clip");
        end
        if(error) error_count=error_count+1;
    end
    initial begin
        repeat(4) @(negedge clk); rst_n=1;
        wait(count==3); @(negedge clk); code=16'ha55a;
        wait(count==4); @(negedge clk); code=16'h8001;
        wait(count==5); @(negedge clk); code=16'h7fff;
        wait(count==6); @(negedge clk); mode=1;
        wait(error_count==1); @(negedge clk); mode=2;
        wait(error_count==2); @(negedge clk); mode=0; code=16'h0001;
        wait(count==8);
        $display("PASS tb_ad7606_spi: 50 kSPS, 128 clocks, signed codes, delayed DOUT, clip, missing/stuck BUSY recovery");
        $finish;
    end
    initial begin #500000; $fatal(1,"ADC test timed out"); end
endmodule
