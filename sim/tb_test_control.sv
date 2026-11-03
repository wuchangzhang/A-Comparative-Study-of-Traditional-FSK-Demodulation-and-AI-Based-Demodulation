`timescale 1ns/1ps
module tb_test_control;
    import control_pkg::*;
    logic clk=0,rst_n=0,sample_ce=0,frame_prepare=0,fsk_active=0,frame_active=0;
    always #5 clk=~clk;
    logic [4:0] key_press=0;
    logic physical_noise=0,knob_event=0;
    logic [1:0] knob_mode=0;
    logic signed [31:0] knob_setting=0;
    logic cmd_valid=0;
    logic [7:0] cmd=7,cmd_len=0,cmd_error;
    logic [511:0] payload=0;
    wire test_running,test_exit,run_requested,test_pending;
    logic report_space=1,frame_start=0,frame_end=0,dac_clip=0;
    dds_t dds_requested,dds_active;
    fsk_t fsk_requested,fsk_active_cfg;
    wire dds_pending,fsk_pending,config_change,knob_rearm,test_command,final_report;
    wire [31:0] config_id,target_frames,run_id,tx_frames,dac_clips,test_frames,adc_errors,adc_clips;
    wire [255:0] trad_stats,ai_stats;
    wire signed [15:0] trad_offset,trad_agc,ai_offset,ai_agc;
    wire [1:0] test_action;
    wire jam_enable, jam_burst;
    wire [7:0] jam_amplitude;
    wire [11:0] jam_hz;
    parameter_manager manager(.*);
    statistics stats(.*,.rx_update(1'b0),.rx_branch(1'b0),.rx_available(1'b0),.ai_available(1'b0),.rx_lock(1'b0),
        .rx_config(32'd0),.rx_run(32'd0),.rx_frame(32'd0),.rx_errors(32'd0),.rx_bits(32'd0),
        .rx_crc_failures(32'd0),.rx_captured(32'd0),.rx_lost(32'd0),.rx_adc_errors(32'd0),
        .rx_adc_clips(32'd0),.rx_model(32'd0),.rx_offset(16'd0),.rx_agc(16'd0));
    task tick; begin @(posedge clk); #1; @(negedge clk); end endtask
    task request(input integer action,input integer expected);
        begin cmd=7; cmd_len=(action==1) ? 5 : 1; payload=0;
            payload[511:504]=action; payload[503:472]=2; cmd_valid=1; #1;
            if(cmd_error!=expected) $fatal(1,"Test command action=%d got=%d expected=%d",action,cmd_error,expected);
            tick(); cmd_valid=0; tick(); end
    endtask
    initial begin
        repeat(3) tick(); rst_n=1; tick();
        request(1,OK); repeat(300) tick();
        request(2,BUSY); request(1,BUSY);
        if(!run_requested || !test_pending || target_frames!=2) $fatal(1,"Pending START overwritten");
        fsk_active=1; frame_prepare=1; tick(); frame_prepare=0; repeat(3) tick();
        if(!test_running) $fatal(1,"Accepted START not committed");
        frame_active=1; request(0,OK);
        if(!test_running) $fatal(1,"STOP truncated frame");
        frame_active=0; frame_end=1; tick(); frame_end=0; repeat(6) tick(); fsk_active=0; repeat(3) tick();
        if(test_running || test_pending || run_requested) $fatal(1,"STOP did not finish");
        frame_active=1; request(2,OK); request(1,BUSY);
        frame_active=0; repeat(4) tick();
        request(1,OK); request(0,OK); repeat(5) tick();
        if(test_running || test_pending || run_requested) $fatal(1,"STOP did not cancel pending START");
        request(1,OK); key_press[4]=1; tick(); key_press=0; repeat(8) tick();
        if(test_pending || run_requested) $fatal(1,"Local exit left START pending");
        $display("PASS tb_test_control: pending START/CLEAR BUSY, boundary STOP, cancellation, local exit"); $finish;
    end
endmodule
