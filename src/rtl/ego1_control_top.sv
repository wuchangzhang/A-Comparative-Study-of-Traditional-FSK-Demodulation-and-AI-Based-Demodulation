module ego1_control_top(
    input wire sys_clk_in,sys_rst_n,
    input wire [4:0] btn_pin,
    input wire noise_switch,uart_rx,knob_p,knob_n,
    input wire adc_busy,adc_dout,
    output wire uart_tx,
    output wire [15:0] led_pin,
    output wire [7:0] seg_data_0_pin,seg_data_1_pin,seg_cs_pin,dac_data,
    output wire dac_ile,dac_cs_n,dac_wr1_n,dac_wr2_n,dac_xfer_n,
    output wire fsk_bit_test_pin,demod_bit_test_pin,
    output wire adc_convst,adc_cs_n,adc_sclk,adc_rst_n
);
    (* ASYNC_REG="TRUE" *) reg [1:0] reset_sync;
    always @(posedge sys_clk_in or negedge sys_rst_n)
        if(!sys_rst_n) reset_sync<=0; else reset_sync<={reset_sync[0],1'b1};
    reg reset_clocked;
    // Core reset assertion and release are clocked, including inferred ROM controls.
    always @(posedge sys_clk_in) reset_clocked<=reset_sync[1];
    wire rst_n;
    // Global distribution keeps the synchronous reset release bounded at high fanout.
    BUFG u_reset_distribution(.I(reset_clocked),.O(rst_n));
    wire [11:0] knob_adc;
    wire tx_bit_internal;
    reg tx_bit_registered,frame_registered;
    wire [15:0] led_internal;
    reg [15:0] led_registered;
    assign led_pin=led_registered;
    wire knob_valid,sample_valid,frame_active,tx_frame_end;
    wire [7:0] sample_data;
    wire [15:0] display_value;
    wire [1:0] display_wave,display_mode;
    wire adc_sample_valid,adc_error,adc_clip;
    wire signed [15:0] adc_sample_data;
    wire [31:0] adc_sample_index;
    wire [3:0] adc_state_code,adc_error_reason;
    wire adc_busy_level,adc_dout_level;
    wire [31:0] adc_reset_count;
    wire rx_update,rx_branch,rx_available,rx_lock,ai_available;
    wire [31:0] core_config,core_run;
    wire [31:0] rx_config,rx_run,rx_frame,rx_errors,rx_bits,rx_crc_failures,
        rx_captured,rx_lost,rx_adc_errors,rx_adc_clips,rx_model;
    wire signed [15:0] rx_offset,rx_agc,rx_signal_peak;
    xadc_knob u_knob(.clk(sys_clk_in),.rst_n(rst_n),.vauxp1(knob_p),.vauxn1(knob_n),.value(knob_adc),.valid(knob_valid));
    control_core u_core(.clk(sys_clk_in),.rst_n(rst_n),.buttons(btn_pin),
        .noise_switch(noise_switch),.uart_rx(uart_rx),.uart_tx(uart_tx),
        .knob_adc(knob_adc),.knob_valid(knob_valid),.sample_data(sample_data),.sample_valid(sample_valid),
        .led(led_internal),.display_value(display_value),.display_wave(display_wave),.display_mode(display_mode),
        .tx_bit(tx_bit_internal),.frame_active(frame_active),.frame_start(),.frame_end(tx_frame_end),.config_id(core_config),.run_id(core_run),
        .rx_update(rx_update),.rx_branch(rx_branch),.rx_available(rx_available),.ai_available(ai_available),.rx_lock(rx_lock),
        .rx_config(rx_config),.rx_run(rx_run),.rx_frame(rx_frame),.rx_errors(rx_errors),.rx_bits(rx_bits),
        .rx_crc_failures(rx_crc_failures),.rx_captured(rx_captured),.rx_lost(rx_lost),.rx_adc_errors(rx_adc_errors),
        .rx_adc_clips(rx_adc_clips),.rx_model(rx_model),.rx_offset(rx_offset),.rx_agc(rx_agc),.rx_signal_peak(rx_signal_peak),
        .adc_state_code(adc_state_code),.adc_error_reason(adc_error_reason),.adc_busy_level(adc_busy_level),
        .adc_dout_level(adc_dout_level),.adc_reset_count(adc_reset_count));
    // B16/A15 remain TX bit/frame debug outputs. RX data is reported over UART.
    always @(posedge sys_clk_in) begin
        if(!rst_n) begin tx_bit_registered<=0; frame_registered<=0; led_registered<=0; end
        else begin tx_bit_registered<=tx_bit_internal; frame_registered<=frame_active; led_registered<=led_internal; end
    end
    assign fsk_bit_test_pin=tx_bit_registered;
    assign demod_bit_test_pin=frame_registered;
    ad7606_spi_rx #(.CLK_HZ(100_000_000),.SAMPLE_HZ(50_000),.SCLK_HZ(10_000_000)) u_adc(
        .clk(sys_clk_in),.rst_n(rst_n),.adc_busy(adc_busy),.adc_dout(adc_dout),
        .adc_convst(adc_convst),.adc_cs_n(adc_cs_n),.adc_sclk(adc_sclk),.adc_rst_n(adc_rst_n),
        .adc_sample_data(adc_sample_data),.adc_sample_valid(adc_sample_valid),.sample_index(adc_sample_index),
        .adc_error(adc_error),.adc_clip(adc_clip),
        .adc_state_code(adc_state_code),.adc_busy_level(adc_busy_level),.adc_dout_level(adc_dout_level),
        .adc_error_reason(adc_error_reason),.adc_reset_count(adc_reset_count));
    fsk_receiver #(.SAMPLE_HZ(50_000),.SAMPLES_PER_BIT(500)) u_receiver(
        .clk(sys_clk_in),.rst_n(rst_n),.sample_valid(adc_sample_valid),.sample_data(adc_sample_data),
        .adc_error(adc_error),.adc_clip(adc_clip),.rx_config(core_config),.rx_run(core_run),
        .eval_tx_end(tx_frame_end),
        .rx_update(rx_update),.rx_branch(rx_branch),.rx_available(rx_available),.rx_lock(rx_lock),
        .ai_available(ai_available),
        .rx_config_out(rx_config),.rx_run_out(rx_run),.rx_frame(rx_frame),.rx_errors(rx_errors),.rx_bits(rx_bits),
        .rx_crc_failures(rx_crc_failures),.rx_captured(rx_captured),.rx_lost(rx_lost),
        .rx_adc_errors(rx_adc_errors),.rx_adc_clips(rx_adc_clips),.rx_model(rx_model),
        .rx_offset(rx_offset),.rx_agc(rx_agc),.rx_signal_peak(rx_signal_peak));
    dac0832_driver u_dac(.clk(sys_clk_in),.rst_n(rst_n),.sample_valid(sample_valid),.sample_data(sample_data),
        .busy(),.done(),.dac_data(dac_data),.dac_ile(dac_ile),.dac_cs_n(dac_cs_n),
        .dac_wr1_n(dac_wr1_n),.dac_wr2_n(dac_wr2_n),.dac_xfer_n(dac_xfer_n));
    dds_display u_display(.clk(sys_clk_in),.rst_n(rst_n),.frequency_hz(display_value),
        .wave_sel(display_wave),.step_sel(display_mode),.seg_data_0(seg_data_0_pin),
        .seg_data_1(seg_data_1_pin),.seg_cs(seg_cs_pin));
endmodule
