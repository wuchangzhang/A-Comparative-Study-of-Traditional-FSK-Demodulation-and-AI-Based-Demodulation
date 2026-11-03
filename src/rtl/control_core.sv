module control_core #(
    parameter integer CLK_HZ=100_000_000, BAUD=115200, SAMPLE_HZ=100_000,
    DEBOUNCE_CLKS=2_000_000, KNOB_UPDATE_CLKS=2_000_000,
    SAMPLES_PER_BIT=1000, GAP_SAMPLES=20000, REPORT_CLKS=100_000_000,
    RX_DRAIN_CLKS=CLK_HZ
)(
    input logic clk,rst_n,
    input logic [4:0] buttons,
    input logic noise_switch,uart_rx,
    output logic uart_tx,
    input logic [11:0] knob_adc,
    input logic knob_valid,
    output logic [7:0] sample_data,
    output logic sample_valid,
    output logic [15:0] led,
    output logic [15:0] display_value,
    output logic [1:0] display_wave,display_mode,
    output logic tx_bit,frame_active,frame_start,frame_end,
    output logic [31:0] config_id,run_id,
    input logic rx_update,rx_branch,rx_available,ai_available,rx_lock,
    input logic [31:0] rx_config,rx_run,rx_frame,rx_errors,rx_bits,rx_crc_failures,
                       rx_captured,rx_lost,rx_adc_errors,rx_adc_clips,rx_model,
    input logic signed [15:0] rx_offset,rx_agc,rx_signal_peak,
    input logic [3:0] adc_state_code,adc_error_reason,
    input logic adc_busy_level,adc_dout_level,
    input logic [31:0] adc_reset_count
);
    import control_pkg::*;
    logic sample_ce,sample_slot,physical_noise;
    logic [2:0] sample_delay;
    logic [4:0] key_press;
    logic [1:0] knob_mode;
    logic knob_taken,knob_event,knob_rearm;
    logic signed [31:0] knob_setting;
    logic [11:0] knob_filtered;
    dds_t dds_requested,dds_active;
    fsk_t fsk_requested,fsk_active_cfg;
    logic run_requested,fsk_active,frame_prepare,bit_boundary,dds_pending,fsk_pending,config_change;
    logic [15:0] frame_id;
    logic [8:0] bit_index;
    logic [31:0] phase;
    logic dac_clip;
    logic [7:0] rx_byte,tx_byte;
    logic rx_byte_valid,rx_byte_error,tx_byte_valid,tx_byte_ready;
    logic request_valid;
    logic [7:0] request_cmd,request_len,request_error,execute_error;
    logic [15:0] request_seq;
    logic [511:0] request_payload;
    logic execute,status_request,response_valid,response_ready,session_reset;
    logic [7:0] execution_cmd,execution_len;
    logic [511:0] execution_payload;
    logic [7:0] response_cmd,response_len;
    logic [15:0] response_seq;
    logic [15:0] status_seq,telemetry_seq;
    logic [511:0] response_payload;
    logic [31:0] command_overflow;
    logic telemetry_valid,telemetry_ready,packet_ready;
    logic [7:0] telemetry_cmd;
    logic [511:0] telemetry_payload;
    logic [31:0] dropped;
    logic [1151:0] status_pages,report_pages;
    logic test_command,test_running,test_exit,final_report,test_pending,report_space;
    logic final_valid,final_ready;
    logic [31:0] final_config;
    logic [1151:0] final_pages;
    logic signed [15:0] trad_offset,trad_agc,ai_offset,ai_agc;
    logic [1:0] test_action;
    logic [31:0] target_frames,tx_frames,dac_clips,test_frames,adc_errors,adc_clips;
    logic [255:0] trad_stats,ai_stats;
    logic jam_enable, jam_burst;
    logic [7:0] jam_amplitude;
    logic [11:0] jam_hz;
    integer display_timer;
    genvar k;
    generate for(k=0;k<5;k=k+1) begin: keys
        button_event #(.DEBOUNCE_CLKS(DEBOUNCE_CLKS),.ENABLE_LONG_PRESS(0)) u_key(
            .clk(clk),.rst_n(rst_n),.button_in(buttons[k]),.press_pulse(key_press[k]),
            .button_state(),.release_pulse(),.repeat_pulse(),.event_pulse());
    end endgenerate
    button_event #(.DEBOUNCE_CLKS(DEBOUNCE_CLKS)) u_switch(
        .clk(clk),.rst_n(rst_n),.button_in(noise_switch),.button_state(physical_noise),
        .press_pulse(),.release_pulse(),.repeat_pulse(),.event_pulse());
    sample_tick #(.CLK_HZ(CLK_HZ),.SAMPLE_HZ(SAMPLE_HZ)) u_tick(.clk(clk),.rst_n(rst_n),.sample_ce(sample_ce));
    always_ff @(posedge clk) begin
        if(!rst_n) sample_delay<=0; else sample_delay<={sample_delay[1:0],sample_ce};
    end
    assign sample_slot=sample_delay[2];
    knob_control #(.CLK_HZ(CLK_HZ),.UPDATE_CLKS(KNOB_UPDATE_CLKS)) u_knob(
        .clk(clk),.rst_n(rst_n),.adc_value(knob_adc),.adc_valid(knob_valid),
        .key_press(key_press),.rearm(knob_rearm),.fsk_active(fsk_active),
        .dds_requested(dds_requested),.fsk_requested(fsk_requested),.mode(knob_mode),
        .taken(knob_taken),.event_valid(knob_event),.setting(knob_setting),.filtered(knob_filtered));
    parameter_manager u_manager(.*,.cmd_valid(execute),.cmd(execution_cmd),.cmd_len(execution_len),.payload(execution_payload),.cmd_error(execute_error));
    fsk_frame_tx #(.SAMPLES_PER_BIT(SAMPLES_PER_BIT),.GAP_SAMPLES(GAP_SAMPLES)) u_frame(
        .clk(clk),.rst_n(rst_n),.sample_ce(sample_slot),.run_requested(run_requested),
        .frame_allow(report_space),
        .fsk_active(fsk_active),.frame_active(frame_active),.frame_prepare(frame_prepare),
        .frame_start(frame_start),.frame_end(frame_end),.bit_boundary(bit_boundary),
        .data_bit(tx_bit),.frame_id(frame_id),.bit_index(bit_index));
    sample_path u_samples(.clk(clk),.rst_n(rst_n),.sample_ce(sample_slot),
        .fsk_active(fsk_active),.frame_active(frame_active),.fsk_bit(tx_bit),
        .dds_cfg(dds_active),.fsk_cfg(fsk_active_cfg),.sample_data(sample_data),
        .jam_enable(jam_enable && (!jam_burst || bit_index>=96)),.jam_burst(jam_burst),
        .jam_amplitude(jam_amplitude),.jam_hz(jam_hz),
        .sample_valid(sample_valid),.clipped(dac_clip),.phase_debug(phase));
    uart_bytes #(.CLK_HZ(CLK_HZ),.BAUD(BAUD)) u_uart(
        .clk(clk),.rst_n(rst_n),.rx(uart_rx),.tx(uart_tx),.rx_data(rx_byte),
        .rx_valid(rx_byte_valid),.rx_error(rx_byte_error),.tx_data(tx_byte),
        .tx_valid(tx_byte_valid),.tx_ready(tx_byte_ready));
    packet_rx #(.TIMEOUT_CLKS(CLK_HZ/10)) u_rx(
        .clk(clk),.rst_n(rst_n),.byte_data(rx_byte),.byte_valid(rx_byte_valid),.byte_error(rx_byte_error),
        .packet_valid(request_valid),.cmd(request_cmd),.length(request_len),.error(request_error),
        .seq(request_seq),.payload(request_payload));
    command_engine u_commands(.*,.overflow_count(command_overflow));
    statistics u_stats(.*);
    report_history #(.RX_DRAIN_CLKS(RX_DRAIN_CLKS)) u_history(.*,.close_event(final_report || config_change));
    telemetry #(.REPORT_CLKS(REPORT_CLKS)) u_telemetry(
        .clk(clk),.rst_n(rst_n),.status_request(status_request),.status_seq(status_seq),
        .session_reset(session_reset),
        .final_valid(final_valid),.final_ready(final_ready),.final_config(final_config),.final_pages(final_pages),
        .config_id(config_id),.status_pages(status_pages),.report_pages(report_pages),
        .valid(telemetry_valid),.ready(telemetry_ready),.cmd(telemetry_cmd),.seq(telemetry_seq),.payload(telemetry_payload));
    assign response_ready=packet_ready;
    assign telemetry_ready=packet_ready && !response_valid;
    packet_tx u_tx(.clk(clk),.rst_n(rst_n),.packet_valid(response_valid || telemetry_valid),
        .packet_ready(packet_ready),.cmd(response_valid ? response_cmd : telemetry_cmd),
        .length(response_valid ? response_len : 8'd59),.seq(response_valid ? response_seq : telemetry_seq),
        .payload(response_valid ? response_payload : telemetry_payload),
        .byte_data(tx_byte),.byte_valid(tx_byte_valid),.byte_ready(tx_byte_ready));
    always_comb begin
        status_pages=0; report_pages=0;
        status_pages[1151:1088]={7'd0,run_requested,7'd0,fsk_active,7'd0,frame_active,
            6'd0,knob_mode,7'd0,knob_taken,7'd0,dds_pending,7'd0,fsk_pending,7'd0,test_running};
        status_pages[1087:1024]=dds_requested; status_pages[1023:960]=dds_active;
        status_pages[959:944]={4'd0,knob_filtered}; status_pages[943:928]=frame_id;
        status_pages[927:896]=target_frames;
        status_pages[895:880]={7'd0,test_pending,7'd0,report_space};
        status_pages[767:696]=fsk_requested; status_pages[695:624]=fsk_active_cfg;
        status_pages[623:616]={7'd0,(frame_active && fsk_active_cfg.physical_noise[0] && fsk_active_cfg.software_noise[0])};
        status_pages[383:352]=32'h00030003; status_pages[351:320]=rx_model;
        // STATUS page 2 spare room: jammer configuration for CSV correlation.
        status_pages[191:184]={6'd0,jam_burst,jam_enable};
        status_pages[183:176]=jam_amplitude;
        status_pages[175:160]=jam_hz;
        status_pages[319:288]={8'd0,7'd0,rx_available,7'd0,ai_available,7'd0,rx_lock};
        status_pages[287:272]=rx_offset; status_pages[271:256]=rx_agc;
        status_pages[255:240]=rx_signal_peak;
        status_pages[239:232]={adc_state_code,adc_error_reason};
        status_pages[231:224]={adc_busy_level,adc_dout_level,6'd0};
        status_pages[223:192]=adc_reset_count;
        report_pages[1151:896]={tx_frames,dac_clips,run_id,test_frames,adc_errors,adc_clips,dropped+command_overflow,31'd0,test_running};
        report_pages[895:824]=fsk_active_cfg;
        report_pages[823:792]=32'h00030003;
        report_pages[767:512]=trad_stats; report_pages[383:128]=ai_stats;
        // REPORT page 1 spare room: jammer configuration frozen with the counters.
        report_pages[479:472]={6'd0,jam_burst,jam_enable};
        report_pages[471:464]=jam_amplitude;
        report_pages[463:448]=jam_hz;
        report_pages[511:480]={trad_offset,trad_agc}; report_pages[127:96]={ai_offset,ai_agc};
        led={3'd0,rx_lock,ai_available,rx_available,test_running,frame_active,
             fsk_active_cfg.physical_noise[0] && fsk_active_cfg.software_noise[0] && frame_active,
             fsk_active,knob_taken,knob_mode,dds_pending,dds_active.wave[1:0]};
        display_wave=dds_active.wave[1:0]; display_mode=knob_mode;
        if(fsk_active) display_value=frame_id;
        else if(display_timer!=0 && knob_mode==1) display_value=dds_active.bias+128;
        else if(display_timer!=0 && knob_mode==2) display_value={8'd0,dds_active.amplitude};
        else display_value=dds_active.hz[15:0];
    end
    always_ff @(posedge clk) begin
        if(!rst_n) display_timer<=0;
        else if(knob_event || key_press[2] || key_press[3]) display_timer<=CLK_HZ*2;
        else if(display_timer!=0) display_timer<=display_timer-1;
    end
endmodule
