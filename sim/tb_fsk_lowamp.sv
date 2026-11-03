`timescale 1ns/1ps
// Regression for the search floor and the signal_peak diagnostic tap.
// A ~18-code carrier (~0.05% of full scale) sits BELOW the 102400 search floor,
// so it must NOT produce a false lock -- this is what stops residual DC and
// noise from being accepted as a preamble. It must still be reported honestly
// by signal_peak so an operator can tell "signal present but too weak" from
// "no signal reaching the ADC at all", which was the real bring-up failure.
// The reference level is 18 codes rather than the historical 50 because the
// frequency-agile 500-point search window carries ~10 dB more processing gain
// than the legacy 100-point one, so a correctly modulated 50-code frame is now
// legitimately decodable; the floor's job is only to reject noise and DC.
module tb_fsk_lowamp;
    logic clk=0,rst_n=0,valid=0,adc_error=0,adc_clip=0,eval_end=0;
    logic signed [15:0] sample_data=0;
    logic [31:0] config_id=1,run_id=0;
    wire update,branch,available,locked;
    wire [31:0] cfg,run,frame,errors,bits,crc_fail,captured,lost,adc_errors,clips,model;
    wire signed [15:0] offset,agc,peak;
    always #5 clk=~clk;
    fsk_receiver dut(.clk(clk),.rst_n(rst_n),.sample_valid(valid),.sample_data(sample_data),
        .adc_error(adc_error),.adc_clip(adc_clip),.rx_config(config_id),.rx_run(run_id),.eval_tx_end(eval_end),
        .rx_update(update),.rx_branch(branch),.rx_available(available),.rx_lock(locked),
        .rx_config_out(cfg),.rx_run_out(run),.rx_frame(frame),.rx_errors(errors),.rx_bits(bits),
        .rx_crc_failures(crc_fail),.rx_captured(captured),.rx_lost(lost),.rx_adc_errors(adc_errors),
        .rx_adc_clips(clips),.rx_model(model),.rx_offset(offset),.rx_agc(agc),.rx_signal_peak(peak));
    logic frame_bits[0:383];
    logic [15:0] crc_value;
    logic [14:0] prbs;
    logic [31:0] sync_word=32'h1acffc1d;
    integer n,k,idx;
    real phase=0.0;
    task automatic emit(input integer value);
        begin @(negedge clk); valid=1; sample_data=value;
            @(negedge clk); valid=0; repeat(499) @(negedge clk); end
    endtask
    task automatic make_frame(input integer number);
        logic b;
        begin
            crc_value=16'hffff; prbs=1;
            for(k=0;k<384;k=k+1) begin
                if(k<16) b=0;
                else if(k<32) b=1;
                else if(k<64) b=!(k%2);
                else if(k<96) b=sync_word[95-k];
                else if(k<112) b=(number>>(111-k))&1;
                else if(k<368) begin b=prbs[14]; prbs={prbs[13:0],prbs[14]^prbs[13]}; end
                else b=crc_value[383-k];
                frame_bits[k]=b;
                if(k>=96 && k<368) crc_value={crc_value[14:0],1'b0}^((crc_value[15]^b) ? 16'h1021 : 16'd0);
            end
        end
    endtask
    initial begin
        repeat(5) @(negedge clk); rst_n=1;
        // ~18-code sine: only ~0.05% of full scale. After the >>4 quantisation
        // the 500-point search window sees a power of ~62500 against the 102400
        // floor, so the preamble gate rejects it.
        make_frame(11);
        for(n=0;n<1149;n=n+1) emit(0);
        for(idx=0;idx<384;idx=idx+1) begin
            for(n=0;n<500;n=n+1) begin
                emit($rtoi(18.0*$sin(phase)));
                phase=phase+6.283185307179586*(frame_bits[idx] ? 2000 : 1000)/50000.0;
            end
        end
        @(negedge clk); eval_end=1; @(negedge clk); eval_end=0;
        for(n=0;n<1000;n=n+1) emit(0);
        // No lock is expected: this carrier is below the acquisition floor.
        if(captured!=0) $fatal(1,"false lock on sub-threshold carrier cap=%0d",captured);
        // The diagnostic tap must still report the real amplitude.
        if(peak<14 || peak>22) $fatal(1,"signal peak tracking wrong: %0d",peak);
        $display("PASS tb_fsk_lowamp: %0d-code sine rejected by search floor, peak=%0d reported",18,peak);
        $finish;
    end
    initial begin #(64'd8000000000); $fatal(1,"low-amplitude test timeout state=%0d peak=%0d",dut.state,peak); end
endmodule
