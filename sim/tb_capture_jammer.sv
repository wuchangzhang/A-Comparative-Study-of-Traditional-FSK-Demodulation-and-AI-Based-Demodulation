`timescale 1ns/1ps
// Capture-chain diagnosis under a narrowband tone jammer. Reuses the frame
// format of tb_fsk_receiver but adds a single-tone interferer (only during
// the frame, exactly like the hardware sample_path gating) and reports which
// acquisition stage rejects the frame: SEARCH boundary, TIMING rejection, or
// SYNC tolerance. State encoding (fsk_receiver state_t):
//   0 SEARCH 1 SEARCH_DONE 2 SEARCH_SHORT 3 CAPTURE 4 FREQ0 5 FREQ0_DONE
//   6 FREQ1 7 FREQ1_DONE 8 TIMING 9 TIMING_DONE 10 TIMING_SCORE 11 SYNC
//   12 SYNC_DONE 13 DATA 14 DATA_DONE 15 AI_WAIT 16 PUBLISH 17 PUBLISH_AI
module tb_capture_jammer;
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

    // Branch-monitoring latches: the report bus is serialized trad-then-AI.
    reg [31:0] trad_captured=0,trad_lost=0,trad_errors=0,ai_captured=0,ai_lost=0,ai_errors=0;
    always @(posedge clk) begin
        if(update) begin
            if(!branch) begin trad_captured<=captured; trad_lost<=lost; trad_errors<=errors; end
            else begin ai_captured<=captured; ai_lost<=lost; ai_errors<=errors; end
        end
    end

    // ---- stage-transition diagnosis --------------------------------------
    integer boundaries=0,timing_rejects=0,sync_rejects=0,locks=0,max_zero=0;
    integer last_timing_best_power_hi=0,last_sync_errors=0;
    logic [4:0] prev_state=0;
    logic prev_lock=0;
    always @(posedge clk) begin
        if(rst_n) begin
            prev_state<=dut.state; prev_lock<=locked;
            if(dut.zero_blocks>max_zero) max_zero<=dut.zero_blocks;
            if(prev_state==2 && dut.state==3) begin
                boundaries=boundaries+1;
                $display("  [diag] t=%0t boundary found at cursor=%0d",$time,dut.cursor);
            end
            if(prev_state==10 && dut.state==0) begin
                timing_rejects=timing_rejects+1;
                $display("  [diag] t=%0t TIMING reject: best_power=%0d best_score=%0d timing_score=%0d",
                    $time,dut.best_power,dut.best_score,dut.timing_score);
            end
            if(prev_state==12 && dut.state==0) begin
                sync_rejects=sync_rejects+1; last_sync_errors=dut.sync_errors;
                $display("  [diag] t=%0t SYNC reject: sync_errors=%0d (limit 2)",$time,dut.sync_errors);
            end
            if(!prev_lock && locked) begin
                locks=locks+1;
                $display("  [diag] t=%0t LOCK achieved, offset=%0d agc=%0d",$time,offset,agc);
            end
        end
    end

    // ---- frame generator (identical layout to tb_fsk_receiver) -----------
    logic frame_bits[0:383];
    logic [15:0] crc_value;
    logic [14:0] prbs;
    logic [31:0] sync_word=32'h1acffc1d;
    integer idx,n,k;
    real phase=1.2345;
    real jam_phase=0.0;
    integer jam_hz=0,jam_amp=0;
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
    integer expected_captured=0;
    task automatic run_case(input integer hz,input integer ratio_pct,input bit expect_capture);
        integer amplitude,bias;
        begin
            amplitude=4096; bias=1234; jam_hz=hz;
            // ratio_pct is the physical jammer/carrier amplitude ratio in
            // percent. NOTE the DAC path scales the FSK tone by amp/256, so a
            // carrier at amplitude code 128 peaks at ~64 DAC codes while the
            // jammer peaks at its code: physical ratio = jam_code/64. The
            // user's failing setting (1050 Hz, code 64) is therefore ratio 100.
            jam_amp=amplitude*ratio_pct/100;
            $display("case: jammer %0d Hz ratio %0d%% -> sim amplitude %0d (signal 4096)",hz,ratio_pct,jam_amp);
            boundaries=0; timing_rejects=0; sync_rejects=0; locks=0; max_zero=0;
            make_frame(42);
            for(n=0;n<1149;n=n+1) emit(bias);
            for(idx=0;idx<384;idx=idx+1) begin
                for(n=0;n<500;n=n+1) begin
                    emit($rtoi(bias+amplitude*$sin(phase)+jam_amp*$sin(jam_phase)));
                    phase=phase+6.283185307179586*((frame_bits[idx] ? 2000 : 1000))/50000.0;
                    jam_phase=jam_phase+6.283185307179586*jam_hz/50000.0;
                end
            end
            @(negedge clk); eval_end=1; @(negedge clk); eval_end=0;
            for(n=0;n<30000;n=n+1) emit(bias);
            $display("  result: trad captured=%0d lost=%0d errors=%0d | ai captured=%0d lost=%0d errors=%0d | offset=%0d",
                trad_captured,trad_lost,trad_errors,ai_captured,ai_lost,ai_errors,offset);
            $display("  diag: boundaries=%0d max_zero_blocks=%0d timing_rejects=%0d sync_rejects=%0d locks=%0d",
                boundaries,max_zero,timing_rejects,sync_rejects,locks);
            // Every capturable case must capture exactly one frame and lose
            // none. Ratios above ~1.2 exceed the design envelope (the jammer
            // peak can capture the FREQ sweep itself); those are stress-only.
            if(expect_capture) begin
                expected_captured=expected_captured+1;
                if(trad_captured!=expected_captured || ai_captured!=expected_captured)
                    $fatal(1,"jammer %0d/%0d%%: capture failed trad=%0d ai=%0d expected=%0d",
                        hz,ratio_pct,trad_captured,ai_captured,expected_captured);
                if(trad_lost!=0 || ai_lost!=0)
                    $fatal(1,"jammer %0d/%0d%%: unexpected loss trad=%0d ai=%0d",hz,ratio_pct,trad_lost,ai_lost);
                if(ratio_pct==0 && (trad_errors!=0 || ai_errors!=0))
                    $fatal(1,"baseline errors trad=%0d ai=%0d",trad_errors,ai_errors);
            end
        end
    endtask
    initial begin
        repeat(5) @(negedge clk); rst_n=1;
        run_case(0,0,1);        // baseline: no jammer, must capture
        run_case(1050,50,1);    // ratio 0.5
        run_case(1050,25,1);    // ratio 0.25
        run_case(1500,100,1);   // mid-band jammer at carrier strength
        run_case(1980,70,1);    // near the 2000 Hz tone, ratio 0.7
        run_case(1050,100,1);   // jammer as strong as the carrier (user's case)
        run_case(1050,140,0);   // beyond the design envelope: stress only
        $display("PASS tb_capture_jammer: diagnosis complete (see [diag] lines)");
        $finish;
    end
    initial begin #(64'd20000000000); $fatal(1,"capture jammer test timeout"); end
endmodule
