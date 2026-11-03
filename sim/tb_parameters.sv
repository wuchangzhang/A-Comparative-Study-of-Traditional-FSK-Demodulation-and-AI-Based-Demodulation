`timescale 1ns/1ps
module tb_parameters;
    import control_pkg::*;
    logic clk=0,rst_n=0,sample_ce=0,frame_prepare=0,fsk_active=0;
    always #5 clk=~clk;
    logic [4:0] key_press=0;
    logic physical_noise=0,knob_event=0;
    logic [1:0] knob_mode=0;
    logic signed [31:0] knob_setting=0;
    logic cmd_valid=0;
    logic [7:0] cmd=0,cmd_len=0,cmd_error;
    logic [511:0] payload=0;
    logic test_running=0,test_exit=0,test_pending=0,report_space=1,run_requested;
    dds_t dds_requested,dds_active;
    fsk_t fsk_requested,fsk_active_cfg;
    logic dds_pending,fsk_pending,config_change,knob_rearm,test_command;
    logic [31:0] config_id,target_frames,prior_config;
    logic [1:0] test_action;
    logic jam_enable, jam_burst;
    logic [7:0] jam_amplitude;
    logic [11:0] jam_hz;
    parameter_manager dut(.*);
    task tick; begin @(posedge clk); #1; @(negedge clk); end endtask
    task request(input [7:0] command,input [7:0] len,input [511:0] p,input [7:0] expected);
        begin cmd=command; cmd_len=len; payload=p; cmd_valid=1; #1;
            if(cmd_error!==expected) $fatal(1,"cmd=%d expected error=%d got=%d",cmd,expected,cmd_error);
            tick(); cmd_valid=0; end
    endtask
    initial begin
        repeat(3) tick(); rst_n=1; tick();
        for(integer wave=1;wave<=4;wave=wave+1) begin
            key_press[0]=1; tick(); key_press[0]=0;
            if(dds_requested.wave!=(wave%4)) $fatal(1,"Four-wave key cycle");
            tick();
        end
        knob_event=1; knob_setting=1200;
        request(1,8,{32'd1500,8'd1,8'd128,16'd10,448'd0},0); knob_event=0;
        if(dds_requested.hz!=1500 || dds_active.hz!=1000 || !dds_pending) $fatal(1,"Arbitration/pending");
        sample_ce=1; tick(); sample_ce=0;
        if(dds_active.hz!=1500 || dds_active.bias!=10) $fatal(1,"Atomic commit");
        request(1,8,{32'd1600,8'd2,8'd255,16'd127,448'd0},OUT_OF_RANGE);
        if(dds_requested.hz!=1500) $fatal(1,"Rejected transaction partially applied");
        request(2,15,{32'd1000,32'd2000,16'd100,8'd128,16'd0,16'd100,392'd0},0);
        request(2,15,{32'd900,32'd2000,16'd100,8'd128,16'd0,16'd0,392'd0},UNSUPPORTED_PROFILE);
        fsk_active=1; request(3,1,{8'd1,504'd0},0);
        request(4,3,{8'd1,16'd512,488'd0},0);
        if(fsk_active_cfg.offset_hz!=0) $fatal(1,"Early FSK change");
        frame_prepare=1; tick(); frame_prepare=0;
        if(config_id!=1 || fsk_active_cfg.offset_hz!=100 || fsk_active_cfg.physical_noise!=0) $fatal(1,"FSK commit");
        physical_noise=1; tick(); frame_prepare=1; tick(); frame_prepare=0;
        if(config_id!=2 || !fsk_active_cfg.physical_noise) $fatal(1,"Physical switch boundary");
        request(1,8,{32'd1800,8'd2,8'd128,16'd0,448'd0},0);
        sample_ce=1; tick(); sample_ce=0;
        if(dds_active.hz!=1500) $fatal(1,"DDS changed while FSK");
        fsk_active=0; sample_ce=1; tick(); sample_ce=0;
        if(dds_active.hz!=1800) $fatal(1,"DDS restore");
        request(1,8,{32'd1800,8'd3,8'd128,16'd0,448'd0},0);
        if(dds_requested.wave!=3 || dds_active.wave!=2) $fatal(1,"Sawtooth pending");
        request(1,8,{32'd1900,8'd4,8'd128,16'd0,448'd0},OUT_OF_RANGE);
        if(dds_requested.wave!=3 || dds_requested.hz!=1800) $fatal(1,"Invalid wave mutated configuration");
        sample_ce=1; tick(); sample_ce=0;
        if(dds_active.wave!=3) $fatal(1,"Sawtooth boundary commit");
        test_pending=1;
        request(7,5,{8'd1,32'd2,472'd0},BUSY);
        request(7,1,{8'd2,504'd0},BUSY);
        request(7,1,{8'd0,504'd0},OK);
        test_pending=0; test_exit=1;
        request(7,5,{8'd1,32'd2,472'd0},BUSY);
        test_exit=0;
        test_pending=0; report_space=0;
        request(7,5,{8'd1,32'd2,472'd0},BUSY);
        request(7,1,{8'd2,504'd0},BUSY);
        request(7,1,{8'd0,504'd0},OK);
        if(jam_enable || jam_amplitude!=0 || jam_hz!=1500) $fatal(1,"Jammer default not quiescent");
        request(8,3,{8'd1,8'd64,16'd1500,480'd0},BAD_LENGTH);
        request(8,4,{8'd2,8'd64,16'd1500,480'd0},OUT_OF_RANGE);
        request(8,4,{8'd1,8'd64,16'd99,480'd0},OUT_OF_RANGE);
        request(8,4,{8'd1,8'd64,16'd2101,480'd0},OUT_OF_RANGE);
        request(8,4,{8'd1,8'd64,16'd1500,480'd0},OK);
        tick();
        if(!jam_enable || jam_amplitude!=64 || jam_hz!=1500) $fatal(1,"Jammer not committed");
        request(8,4,{8'd0,8'd0,16'd1200,480'd0},OK);
        tick();
        if(jam_enable || jam_hz!=1200) $fatal(1,"Jammer not cleared");
        request(8,5,{8'd1,8'd80,16'd1050,8'd2,472'd0},OUT_OF_RANGE);
        prior_config=config_id;
        request(8,5,{8'd1,8'd80,16'd1050,8'd1,472'd0},OK);
        if(jam_burst || jam_enable || config_id!=prior_config || !config_change)
            $fatal(1,"Staged jammer must preserve old values until report close");
        tick();
        if(!jam_burst || !jam_enable || jam_amplitude!=80) $fatal(1,"Burst command");
        if(config_id!=prior_config+1) $fatal(1,"Jammer change must advance config tag");
        prior_config=config_id;
        request(8,5,{8'd1,8'd80,16'd1050,8'd1,472'd0},OK);
        tick();
        if(config_id!=prior_config) $fatal(1,"Identical jammer must retain config tag");
        fsk_active=1;
        request(8,4,{8'd0,8'd0,16'd1200,480'd0},BUSY);
        if(!jam_burst || !jam_enable) $fatal(1,"Busy command mutated jammer");
        fsk_active=0;
        request(8,4,{8'd0,8'd0,16'd1200,480'd0},OK);
        tick();
        if(jam_burst) $fatal(1,"Legacy command must select continuous mode");
        $display("PASS tb_parameters: arbitration, atomic rejection, sample/frame commits, restore, jammer"); $finish;
    end
endmodule
