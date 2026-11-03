`timescale 1ns/1ps
module tb_knob;
    import control_pkg::*;
    logic clk=0,rst_n=0,adc_valid=1,rearm=0,fsk_active=0;
    always #5 clk=~clk;
    logic [11:0] adc_value=1940;
    logic [4:0] key_press=0;
    dds_t dds_requested=DDS_DEFAULT;
    fsk_t fsk_requested=FSK_DEFAULT;
    wire [1:0] mode;
    wire taken,event_valid;
    wire signed [31:0] setting;
    wire [11:0] filtered;
    integer events=0;
    knob_control #(.UPDATE_CLKS(20)) dut(.*);
    always @(negedge clk) if(event_valid) events=events+1;
    task settle; repeat(100) @(negedge clk); endtask
    initial begin
        repeat(4) @(negedge clk); rst_n=1; settle();
        if(!taken || events!=0) $fatal(1,"Initial pickup");
        adc_value=2500; settle();
        if(events==0 || setting<1200) $fatal(1,"Frequency mapping");
        dds_requested.hz=1800; rearm=1; @(negedge clk); rearm=0; events=0; settle();
        if(taken || events!=0) $fatal(1,"Software value overwritten by stationary knob");
        adc_value=3800; settle();
        if(!taken) $fatal(1,"Crossing pickup failed");
        key_press=5'b00100; @(negedge clk); key_press=0; settle();
        if(mode!=1 || taken) $fatal(1,"Mode switch jumped");
        adc_value=2048; settle(); if(!taken) $fatal(1,"Bias pickup");
        events=0; adc_value=2052; settle(); if(events!=0) $fatal(1,"ADC jitter escaped deadzone");
        fsk_active=1; settle(); if(mode!=1) $fatal(1,"FSK mode");
        key_press=5'b01000; @(negedge clk); key_press=0; adc_value=2048; settle();
        if(mode!=2 || !taken) $fatal(1,"FSK amplitude pickup");
        $display("PASS tb_knob: mapping, deadzone, crossing, software/mode pickup"); $finish;
    end
endmodule
