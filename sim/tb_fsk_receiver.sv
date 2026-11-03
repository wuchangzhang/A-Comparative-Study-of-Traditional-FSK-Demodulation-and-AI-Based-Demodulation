`timescale 1ns/1ps
module tb_fsk_receiver;
    logic clk=0,rst_n=0,valid=0,adc_error=0,adc_clip=0,eval_end=0;
    logic signed [15:0] sample_data=0;
    logic [31:0] config_id=1,run_id=0;
    wire update,branch,available,locked,ai_available;
    wire [31:0] cfg,run,frame,errors,bits,crc_fail,captured,lost,adc_errors,clips,model;
    wire signed [15:0] offset,agc,peak;
    always #5 clk=~clk;
    fsk_receiver dut(.clk(clk),.rst_n(rst_n),.sample_valid(valid),.sample_data(sample_data),
        .adc_error(adc_error),.adc_clip(adc_clip),.rx_config(config_id),.rx_run(run_id),.eval_tx_end(eval_end),
        .rx_update(update),.rx_branch(branch),.rx_available(available),.rx_lock(locked),
        .ai_available(ai_available),
        .rx_config_out(cfg),.rx_run_out(run),.rx_frame(frame),.rx_errors(errors),.rx_bits(bits),
        .rx_crc_failures(crc_fail),.rx_captured(captured),.rx_lost(lost),.rx_adc_errors(adc_errors),
        .rx_adc_clips(clips),.rx_model(model),.rx_offset(offset),.rx_agc(agc),.rx_signal_peak(peak));
    // Branch-monitoring latches: the shared bus is serialized, so latch each branch.
    reg [31:0] trad_captured=0,trad_bits=0,trad_errors=0,trad_crc=0,trad_lost=0,trad_frame=0;
    reg [31:0] ai_captured=0,ai_bits=0,ai_errors=0,ai_crc=0,ai_lost=0,ai_frame=0;
    always @(posedge clk) begin
        if(update) begin
            if(!branch) begin
                trad_captured<=captured; trad_bits<=bits; trad_errors<=errors;
                trad_crc<=crc_fail; trad_lost<=lost; trad_frame<=frame;
            end else begin
                ai_captured<=captured; ai_bits<=bits; ai_errors<=errors;
                ai_crc<=crc_fail; ai_lost<=lost; ai_frame<=frame;
            end
        end
    end
    wire [255:0] traditional_stats;
    wire [31:0] stats_adc_errors,stats_adc_clips;
    statistics u_stats(.clk(clk),.rst_n(rst_n),.frame_start(1'b0),.frame_end(eval_end),
        .frame_prepare(1'b0),.frame_active(1'b0),.fsk_active(1'b1),.config_change(1'b0),
        .config_id(config_id),.dac_clip(1'b0),.test_command(1'b0),.run_requested(1'b1),
        .test_action(2'd0),.target_frames(32'd0),.rx_update(update),.rx_branch(branch),
        .rx_available(available),.rx_lock(locked),.ai_available(ai_available),
        .rx_config(cfg),.rx_run(run),.rx_frame(frame),.rx_errors(errors),.rx_bits(bits),
        .rx_crc_failures(crc_fail),.rx_captured(captured),.rx_lost(lost),.rx_adc_errors(adc_errors),
        .rx_adc_clips(clips),.rx_model(model),.rx_offset(offset),.rx_agc(agc),
        .trad_stats(traditional_stats),.adc_errors(stats_adc_errors),.adc_clips(stats_adc_clips));
    logic frame_bits[0:383];
    logic [15:0] crc_value;
    logic [14:0] prbs;
    logic [31:0] sync_word=32'h1acffc1d;
    integer case_no,idx,n,k,amplitude,frequency_offset,bias,symbol_samples,noise_value;
    logic [31:0] noise_state=32'h1234abcd;
    real phase=1.2345;
    task automatic emit(input integer value);
        begin
            @(negedge clk); valid=1; sample_data=value;
            @(negedge clk); valid=0;
            repeat(499) @(negedge clk);
        end
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
        for(case_no=0;case_no<6;case_no=case_no+1) begin
            make_frame(7+case_no);
            frequency_offset=(case_no<3) ? (case_no-1)*100 : ((case_no==3) ? 50 : -50);
            amplitude=(case_no==0) ? 512 : ((case_no==2) ? 24000 : 4096);
            bias=1234;
            if(case_no==1) frame_bits[152]=~frame_bits[152];
            if(case_no==3) begin frame_bits[67]=~frame_bits[67]; frame_bits[90]=~frame_bits[90]; end
            if(case_no==5) begin
                frame_bits[67]=~frame_bits[67]; frame_bits[75]=~frame_bits[75]; frame_bits[90]=~frame_bits[90];
            end
            for(n=0;n<1149+case_no*117;n=n+1) emit(bias);
            for(idx=0;idx<384;idx=idx+1) begin
                symbol_samples=500;
                if(idx%20==19 && case_no==3) symbol_samples=501;
                if(idx%20==19 && case_no==4) symbol_samples=499;
                for(n=0;n<symbol_samples;n=n+1) begin
                    noise_value=0;
                    if(case_no==3 || case_no==4) begin
                        // Deterministic 12-uniform Gaussian approximation,
                        // sigma about 363 ADC codes, sample SNR about 18 dB.
                        for(k=0;k<12;k=k+1) begin
                            noise_state={noise_state[30:0],noise_state[31]^noise_state[21]^noise_state[1]^noise_state[0]};
                            noise_value=noise_value+noise_state[7:0];
                        end
                        noise_value=(noise_value-1530)*363/256;
                    end
                    emit($rtoi(bias+amplitude*$sin(phase))+noise_value);
                    phase=phase+6.283185307179586*((frame_bits[idx] ? 2000 : 1000)+frequency_offset)/50000.0;
                end
            end
            @(negedge clk); eval_end=1; @(negedge clk); eval_end=0;
            for(n=0;n<1000;n=n+1) emit(bias);
            if(trad_captured!=(case_no==5 ? 5 : case_no+1) || trad_bits!=(case_no==5 ? 5 : case_no+1)*256 || trad_errors!=(case_no>=1 ? 1 : 0) ||
               trad_crc!=(case_no>=1 ? 1 : 0) || trad_lost!=0)
                $fatal(1,"case %0d traditional counters cap=%0d bits=%0d err=%0d crc=%0d lost=%0d state=%0d boundary=%0d aligned=%0d",
                    case_no,trad_captured,trad_bits,trad_errors,trad_crc,trad_lost,dut.state,dut.boundary,dut.aligned);
            if(ai_available!==1) $fatal(1,"AI unavailable");
            if(ai_captured!=trad_captured) $fatal(1,"case %0d AI capture %0d vs trad %0d",case_no,ai_captured,trad_captured);
            if(case_no<5 && (offset<frequency_offset-10 || offset>frequency_offset+10))
                $fatal(1,"offset estimate %0d expected %0d",offset,frequency_offset);
            if(case_no==0 && agc<=0) $fatal(1,"small signal AGC");
            if(case_no==0 && frame!=7) $fatal(1,"first valid air frame ID");
            if(case_no==1 && frame!=7) $fatal(1,"CRC-failed frame changed valid air frame ID");
            if(case_no==2 && agc>=0) $fatal(1,"large signal AGC");
            if(traditional_stats[223:192]!=trad_errors || traditional_stats[191:160]!=trad_bits ||
               traditional_stats[159:128]!=trad_crc || traditional_stats[127:96]!=trad_captured)
                $fatal(1,"statistics snapshot contract");
            $display("receiver case %0d: offset=%0d gain=%0d trad_bits=%0d trad_errors=%0d ai_bits=%0d ai_errors=%0d peak=%0d",
                case_no,offset,agc,trad_bits,trad_errors,ai_bits,ai_errors,peak);
        end
        // Three sync errors reject the last frame. It has no BER denominator.
        for(n=0;n<50100;n=n+1) emit(1234);
        if(trad_lost!=1 || trad_bits!=1280 || trad_errors!=1)
            $fatal(1,"loss evaluation lost=%0d bits=%0d errors=%0d captured=%0d crc=%0d expected=%0d state=%0d drain=%0d",
                trad_lost,trad_bits,trad_errors,trad_captured,trad_crc,
                dut.expected_frames,dut.state,dut.written-dut.last_tx_sample);
        run_id=2;
        // The tag is only noticed when the receiver next returns to the idle
        // scan, which can be a full symbol pipeline away if it is mid-capture,
        // so wait for the update rather than a fixed handful of clocks.
        for(n=0;n<4000000 && run!=2;n=n+1) @(negedge clk);
        if(run!=2 || bits!=0 || captured!=0 || lost!=0) $fatal(1,"tag reset run=%0d bits=%0d cap=%0d lost=%0d",run,bits,captured,lost);
        @(negedge clk); adc_error=1; adc_clip=1;
        @(negedge clk); adc_error=0; adc_clip=0;
        repeat(10) @(negedge clk);
        if(adc_errors!=1 || clips!=1) $fatal(1,"ADC statistics");
        $display("PASS tb_fsk_receiver: offsets, AGC, 18 dB noise, +/-100 ppm, sync tolerance/rejection, CRC, true BER, loss, statistics, tags");
        $finish;
    end
    initial begin #(64'd8000000000); $fatal(1,"receiver test timeout"); end
endmodule
