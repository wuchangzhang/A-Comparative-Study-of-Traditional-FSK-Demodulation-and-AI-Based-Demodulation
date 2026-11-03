`timescale 1ns/1ps
module tb_statistics;
    logic clk=0,rst_n=0;
    always #5 clk=~clk;
    logic frame_start=0,frame_end=0,frame_prepare=0,frame_active=0,fsk_active=0,config_change=0,dac_clip=0;
    logic [31:0] config_id=1;
    logic test_command=0,run_requested=1;
    logic signed [15:0] rx_offset=-42,rx_agc=3;
    wire signed [15:0] trad_offset,trad_agc,ai_offset,ai_agc;
    wire test_pending;
    logic [1:0] test_action=0;
    logic [31:0] target_frames=2;
    logic rx_update=0,rx_branch=0,rx_available=1,rx_lock=1,ai_available=1;
    logic [31:0] rx_config=1,rx_run=1,rx_frame=1,rx_errors=2,rx_bits=256,rx_crc_failures=1,rx_captured=1,rx_lost=0;
    logic [31:0] rx_adc_errors=0,rx_adc_clips=0,rx_model=7;
    wire test_running,test_exit,final_report;
    wire [31:0] run_id,tx_frames,dac_clips,test_frames,adc_errors,adc_clips;
    wire [255:0] trad_stats,ai_stats;
    statistics dut(.*);
    task tick; begin @(posedge clk); #1; @(negedge clk); end endtask
    initial begin
        repeat(3) tick(); rst_n=1; tick();
        test_command=1; test_action=1; tick(); test_command=0; repeat(3) tick();
        if(test_running) $fatal(1,"Test started before frame configuration");
        frame_prepare=1; config_change=1; tick(); frame_prepare=0; config_change=0; repeat(2) tick();
        if(!test_running || run_id!=1) $fatal(1,"Test start");
        rx_update=1; tick(); rx_update=0;
        if(trad_stats[223:192]!=2 || ai_stats!=0 || trad_offset!=-42 || trad_agc!=3) $fatal(1,"Traditional snapshot");
        rx_branch=1; rx_errors=3; repeat(5) tick(); rx_update=1; tick(); rx_update=0;
        if(ai_stats[223:192]!=3) $fatal(1,"Delayed AI snapshot");
        rx_config=0; rx_errors=99; rx_update=1; tick(); rx_update=0;
        if(ai_stats[223:192]!=3) $fatal(1,"Stale config accepted");
        rx_config=1; ai_available=0; rx_update=1; tick(); rx_update=0;
        if(ai_stats[255:224]!=0) $fatal(1,"Unavailable AI retained valid status");
        frame_end=1; tick(); frame_end=0; tick(); frame_end=1; tick(); frame_end=0;
        if(test_running || !test_exit || tx_frames!=2 || test_frames!=2) $fatal(1,"Target stop");
        tick(); if(!final_report) $fatal(1,"Missing final report");
        config_change=1; tick(); config_change=0; config_id=2; tick();
        if(tx_frames!=0 || trad_stats!=0 || ai_stats!=0) $fatal(1,"Config reset");
        test_command=1; test_action=1; tick(); test_command=0; tick();
        if(!test_pending) $fatal(1,"Missing pending state");
        run_requested=0; repeat(4) tick();
        if(test_running || test_pending) $fatal(1,"Cancelled start stuck pending");
        $display("PASS tb_statistics: delayed branches, stale tags, target stop, config reset"); $finish;
    end
endmodule
