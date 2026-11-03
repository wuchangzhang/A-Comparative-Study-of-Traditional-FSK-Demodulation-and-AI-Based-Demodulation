`timescale 1ns/1ps
// Replay actual transmitter DAC codes through an ideal linear ADC conversion.
// The receiver only sees samples; TX symbol boundaries are not supplied.
module tb_burst_receiver;
    logic clk=0,rst_n=0,valid=0,eval_end=0;
    logic signed [15:0] sample_data=0;
    always #5 clk=~clk;
    wire update,branch,available,locked,ai_available;
    wire [31:0] cfg,run,frame,errors,bits,crc_fail,captured,lost,adc_errors,clips,model;
    wire signed [15:0] offset,agc,peak;
    integer trad_errors=0,ai_errors=0,trad_crc=0,ai_crc=0,trad_cap=0,ai_cap=0;
    fsk_receiver dut(.clk(clk),.rst_n(rst_n),.sample_valid(valid),.sample_data(sample_data),
        .adc_error(1'b0),.adc_clip(1'b0),.rx_config(32'd1),.rx_run(32'd1),.eval_tx_end(eval_end),
        .rx_update(update),.rx_branch(branch),.rx_available(available),.rx_lock(locked),
        .ai_available(ai_available),.rx_config_out(cfg),.rx_run_out(run),.rx_frame(frame),
        .rx_errors(errors),.rx_bits(bits),.rx_crc_failures(crc_fail),.rx_captured(captured),
        .rx_lost(lost),.rx_adc_errors(adc_errors),.rx_adc_clips(clips),.rx_model(model),
        .rx_offset(offset),.rx_agc(agc),.rx_signal_peak(peak));
    always @(posedge clk) if(update) begin
        if(branch) begin ai_errors=errors; ai_crc=crc_fail; ai_cap=captured; end
        else begin trad_errors=errors; trad_crc=crc_fail; trad_cap=captured; end
    end
    integer input_file,value,status,n=0;
    initial begin
        input_file=$fopen("../tb_burst_tx/burst_adc.txt","r");
        if(!input_file) $fatal(1,"Run tb_burst_tx first");
        repeat(5) @(negedge clk); rst_n=1;
        while(!$feof(input_file)) begin
            status=$fscanf(input_file,"%d\n",value);
            if(status!=1) $fatal(1,"Bad ADC capture");
            @(negedge clk); sample_data=value; valid=1;
            @(negedge clk); valid=0;
            repeat(499) @(negedge clk);
            n=n+1;
        end
        $fclose(input_file);
        repeat(1000) @(negedge clk);
        if(trad_cap!=1 || ai_cap!=1 || bits!=256 || adc_errors!=0)
            $fatal(1,"Capture trad=%0d AI=%0d bits=%0d ADC=%0d",trad_cap,ai_cap,bits,adc_errors);
        if(trad_errors==0 || ai_errors>=trad_errors || trad_crc!=1 || ai_crc!=0)
            $fatal(1,"No burst benefit: trad err=%0d crc=%0d AI err=%0d crc=%0d",trad_errors,trad_crc,ai_errors,ai_crc);
        $display("PASS tb_burst_receiver: RTL TX/ADC replay, traditional=%0d/256 CRC=%0d AI=%0d/256 CRC=%0d",trad_errors,trad_crc,ai_errors,ai_crc);
        $finish;
    end
    initial begin #(64'd2000000000); $fatal(1,"Burst receiver timeout"); end
endmodule
