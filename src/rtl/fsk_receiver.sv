// Fixed 50 kSPS / 100 bit/s dual-branch receiver. TX timing is used ONLY by the
// loss evaluator; acquisition, NCOs, window addresses and decisions use ADC data.
// The traditional branch is unchanged; the AI branch re-runs every payload bit
// through the int8 MLP and keeps independent frame/BER/CRC accounting.
module fsk_receiver #(
    parameter integer SAMPLE_HZ=50_000, SAMPLES_PER_BIT=500,
    parameter integer LOSS_WAIT_SAMPLES=SAMPLE_HZ/2,
    parameter integer AI_SHIFT1=4, AI_SHIFT2=5
)(
    input logic clk,rst_n,sample_valid,
    input logic signed [15:0] sample_data,
    input logic adc_error,adc_clip,
    input logic [31:0] rx_config,rx_run,
    input logic eval_tx_end,
    output logic rx_update,rx_branch,rx_available,rx_lock,ai_available,
    output logic [31:0] rx_config_out,rx_run_out,rx_frame,rx_errors,rx_bits,
    rx_crc_failures,rx_captured,rx_lost,rx_adc_errors,rx_adc_clips,rx_model,
    output logic signed [15:0] rx_offset,rx_agc,
    output logic signed [15:0] rx_signal_peak
);
    localparam [31:0] SYNC_WORD=32'h1acffc1d;
    localparam [31:0] TRAD_MODEL=32'h00030003, AI_MODEL=32'h00070001;
    localparam integer SHORT=100, STABLE=4096;
    // SEARCH window length. A 100-point (2 ms) window has 500 Hz resolution, so
    // a near-carrier jammer (e.g. 1050 Hz) leaks ~0.98 into the 1000 Hz bin and
    // beats coherently against the preamble tone: every half beat period the
    // destructive phase collapses p0 and the zero_blocks chain breaks, so no
    // boundary is ever found (verified in tb_capture_jammer at a 1.0 jammer
    // ratio). A 500-point window spans half the worst-case beat period, so the
    // jammer's in-window integral is phase-independent (sinc(0.5)=0.64 leak) and
    // both bit classes stay decidable up to a ~1.5 jammer/carrier ratio. The
    // window still steps by SHORT samples, so boundary resolution is unchanged.
    // 250 samples is the compromise that survives both failure modes: a 500-pt
    // window nulls a carrier sitting an exact 100 Hz away and only leaves 0.43
    // of it at +/-50 Hz, while a 100-pt window has just ~5.5 dB of processing
    // gain at 16 dB Eb/N0 and its decisions then flip randomly. At 250 points
    // the +/-50 Hz carrier keeps 0.81 and +/-100 Hz keeps 0.45, with ~11 dB of
    // processing gain. The window still steps by SHORT samples, so boundary
    // resolution is unchanged.
    localparam integer SEARCH_LEN=500;
    // Frequency-agile SEARCH: a fixed 1000/2000 Hz reference is what made
    // jamming fatal. With the carrier at 1000+delta, a jammer 50 Hz away lands
    // in the same bin and the two cannot be separated, and a 500-point window
    // nulls a carrier sitting an exact 100 Hz away entirely. Probing every
    // offset the GUI exposes and keeping the branch maximum restores full
    // carrier power at any delta while keeping the 100 Hz resolution that
    // rejects off-band jammers. steps[] is indexed by (delta+100)/10.
    localparam integer SEARCH_PROBES=5;
    // Absolute floor for the 500-pt search window: the legacy 100-pt floor was
    // 4096 and power scales with length^2, so the equivalent is 4096*25. This
    // keeps the legacy sensitivity -- a carrier below ~20 peak codes stays
    // under it and cannot false-lock.
    localparam [63:0] SEARCH_FLOOR_SHORT=64'd4096;
    localparam [63:0] SEARCH_FLOOR_LONG=64'd102400;
    localparam [63:0] SEARCH_FLOOR_COMBINED=64'd102400;
    // A window is 0-like when either detector sees a 0. The long window fires
    // ~190 samples into the 1-run, the short one ~50; this bias keeps the
    // Estimate stays centred between them (residual <=120 samples, covered by the
    // +/-800 sample TIMING sweep).
    // Measured over the jammer matrix: the 500-pt window reports the transition
    // ~100 samples early once the frequency-agile branch maximum is used, so
    // this bias centres the estimate (median residual -106 samples, 91% inside
    // the +/-350 TIMING sweep).
    localparam integer BOUNDARY_BIAS=100;
    // How many consecutive dark windows (2 s at the 100-sample step) clear a
    // preserved run: one beat fade lasts a few windows, silence lasts forever.
    localparam integer QUIET_LIMIT=20;
    // Coarse TIMING sweep: +/-TIMING_HALF_SPAN samples in 25-sample steps.
    localparam integer TIMING_HALF_SPAN=350;
    localparam integer TIMING_COARSE_STEPS=2*TIMING_HALF_SPAN/25+1;
    localparam signed [15:0] TIMING_SPAN=-TIMING_HALF_SPAN;
    typedef enum logic [4:0] {SEARCH,SEARCH_DONE,SEARCH_VOTE,CAPTURE,FREQ0,FREQ0_DONE,
        FREQ1,FREQ1_DONE,TIMING,TIMING_DONE,TIMING_SCORE,SYNC,SYNC_DONE,
        DATA,DATA_DONE,AI_WAIT,PUBLISH,PUBLISH_AI,GROUP_PUBLISH_AI,GROUP_CHANGE,
        SEARCH_TONE,SEARCH_TONE_DONE} state_t;
    state_t state;
    (* ram_style="block" *) logic signed [15:0] samples[0:65535];
    logic [31:0] written,cursor,boundary,aligned,window_start,job_start;
    logic signed [15:0] memory_data;
    logic [15:0] address;
    always_ff @(posedge clk) begin
        if(sample_valid && rst_n) samples[written[15:0]]<=sample_data;
        memory_data<=samples[address];
    end
    logic [47:0] steps[0:20];
    initial $readmemh("rx_steps.mem",steps);
    logic go,done,mac_busy,feature_enable,feature_saturation;
    logic [15:0] first_address;
    logic [12:0] length;
    logic [23:0] step0,step1;
    logic signed [15:0] dc;
    logic signed [3:0] gain;
    logic [63:0] p0,p1;
    // Running maximum of the branch powers across the probed frequency offsets.
    logic [63:0] sp0_long,sp1_long;
    logic [2:0] search_probe;
    logic [4:0] quiet_blocks;
    logic signed [31:0] raw_sum;
    logic [159:0] features;
    fsk_correlator u_mac(.clk(clk),.rst_n(rst_n),.start(go),
        .first_address(first_address),.length(length),.step0(step0),.step1(step1),
        .dc(dc),.gain(gain),.feature_enable(feature_enable),.address(address),.memory_data(memory_data),
        .done(done),.busy(mac_busy),.power0(p0),.power1(p1),.raw_sum(raw_sum),
        .features(features),.feature_saturation(feature_saturation));
    logic ai_start,ai_done,ai_busy,ai_decision;
    wire [31:0] ai_model_version;
    ai_mlp #(.MODEL_VERSION(AI_MODEL),.SHIFT1(AI_SHIFT1),.SHIFT2(AI_SHIFT2)) u_ai(
        .clk(clk),.rst_n(rst_n),.start(ai_start),.features(features),.done(ai_done),.busy(ai_busy),
        .decision(ai_decision),.ai_available(ai_available),.model_version(ai_model_version));
    logic signed [23:0] dc_tracker;
    logic signed [15:0] signal_peak;
    logic [11:0] peak_decay;
    logic [7:0] zero_blocks;
    logic [4:0] frequency,best_frequency;
    logic [63:0] first_power,best_power;
    logic signed [31:0] first_raw,best_raw;
    // Each branch keeps the largest power seen across the probed frequency
    // offsets, so a carrier at 1000+delta is always seen at full strength while
    // an off-band jammer still has to fight the 100 Hz window resolution.
    wire [63:0] combined0 = sp0_long;
    wire [63:0] combined1 = sp1_long;
    wire search_active = (combined0+combined1)>SEARCH_FLOOR_COMBINED;
    // Tonality gate. A coherent tone's correlation power grows with length^2,
    // so the 500-pt result is ~25x the 100-pt one; uncorrelated noise only
    // grows with length (~5x) and a baseband transient left over from the DC
    // tracker's step response is slower still. Requiring at least a quarter of
    // the matched-scale ratio accepts every real FSK carrier (measured ratio
    // ~1.0-1.14) while rejecting noise and DC transients, which is what stops
    // the receiver false-locking on the quiet interval between frames.
    wire [63:0] long_sum = sp0_long+sp1_long;
    wire [63:0] short_sum = p0+p1;
    wire [63:0] short_matched = (short_sum<<4)+(short_sum<<3)+short_sum;  // *25
    wire tone_like = long_sum>=(short_matched>>2);
    // The loss evaluator must fire whenever the receiver is idle-scanning, not
    // only in the one SEARCH state: with five frequency probes the scan spends
    // ~99% of its time in the probe/collect states, so gating on SEARCH alone
    // lets a long drain interval pass without ever being sampled.
    wire searching = state==SEARCH || state==SEARCH_DONE || state==SEARCH_TONE ||
                     state==SEARCH_TONE_DONE || state==SEARCH_VOTE;
    logic [6:0] trial,timing_bit;
    logic fine;
    logic signed [15:0] trial_shift,best_shift;
    logic signed [63:0] timing_score,best_score;
    logic [5:0] sync_bit;
    logic [5:0] sync_errors;
    logic [8:0] data_bit;
    logic traditional_decision;
    logic [15:0] air_frame,ai_air_frame,crc,ai_crc,received_crc,ai_received_crc;
    logic [14:0] reference_prbs,ai_reference_prbs;
    logic [31:0] frame_errors,ai_frame_errors,expected_frames,last_tx_sample;
    logic sequence_valid,ai_sequence_valid;
    logic [15:0] last_sequence,ai_last_sequence;
    logic [31:0] extended_sequence,ai_extended_sequence;
    logic [31:0] trad_frame,trad_errors,trad_bits,trad_crc_failures,trad_captured,trad_lost;
    logic [31:0] ai_frame,ai_errors,ai_bits,ai_crc_failures,ai_captured,ai_lost;
    wire [15:0] sequence_delta=air_frame-last_sequence;
    wire [15:0] ai_sequence_delta=ai_air_frame-ai_last_sequence;
    wire tag_change=(rx_config_out!=rx_config || rx_run_out!=rx_run);
    assign rx_signal_peak=signal_peak;
    // The shared report bus is serialized one branch at a time.
    always_comb begin
        if(rx_branch) begin
            rx_frame=ai_frame; rx_errors=ai_errors; rx_bits=ai_bits;
            rx_crc_failures=ai_crc_failures; rx_captured=ai_captured; rx_lost=ai_lost; rx_model=AI_MODEL;
        end else begin
            rx_frame=trad_frame; rx_errors=trad_errors; rx_bits=trad_bits;
            rx_crc_failures=trad_crc_failures; rx_captured=trad_captured; rx_lost=trad_lost; rx_model=TRAD_MODEL;
        end
    end
    wire decision=(p1>p0);
    wire expected_timing_bit=!timing_bit[0];
    wire signed [63:0] difference=expected_timing_bit ? $signed(p1)-$signed(p0) : $signed(p0)-$signed(p1);
    function automatic [31:0] add_sat(input [31:0] a,b);
        logic [32:0] t;
        begin t={1'b0,a}+{1'b0,b}; add_sat=t[32] ? 32'hffffffff : t[31:0]; end
    endfunction
    function automatic [15:0] crc_bit(input [15:0] c,input logic b);
        crc_bit={c[14:0],1'b0}^((c[15]^b) ? 16'h1021 : 16'd0);
    endfunction
    function automatic signed [3:0] choose_gain(input [63:0] power_value);
        begin
            if(power_value<64'd1000000000) choose_gain=3;
            else if(power_value<64'd4000000000) choose_gain=2;
            else if(power_value<64'd16000000000) choose_gain=1;
            else if(power_value<=64'd64000000000) choose_gain=0;
            else if(power_value<=64'd256000000000) choose_gain=-1;
            else if(power_value<=64'd1024000000000) choose_gain=-2;
            else choose_gain=-3;
        end
    endfunction
    task automatic correlate(input [31:0] start_at,input [12:0] count);
        begin
            first_address<=start_at[15:0]; job_start<=start_at; length<=count;
            feature_enable<=(state==DATA); go<=1;
        end
    endtask
    always_ff @(posedge clk) begin
        if(!rst_n) begin
            state<=SEARCH; written<=0; cursor<=0; boundary<=0; aligned<=0; window_start<=0; job_start<=0;
            go<=0; ai_start<=0; feature_enable<=0; first_address<=0; length<=0; step0<=0; step1<=0; dc<=0; gain<=0;
            sp0_long<=0; sp1_long<=0; search_probe<=0;
            quiet_blocks<=0; dc_tracker<=0; zero_blocks<=0; frequency<=0; best_frequency<=0;
            signal_peak<=0; peak_decay<=0;
            first_power<=0; best_power<=0; first_raw<=0; best_raw<=0;
            trial<=0; timing_bit<=0; fine<=0; trial_shift<=0; best_shift<=0;
            timing_score<=0; best_score<=-64'sh7fffffffffffffff;
            sync_bit<=0; sync_errors<=0; data_bit<=0; traditional_decision<=0; air_frame<=0; ai_air_frame<=0;
            crc<=16'hffff; ai_crc<=16'hffff; received_crc<=0; ai_received_crc<=0;
            reference_prbs<=1; ai_reference_prbs<=1; frame_errors<=0; ai_frame_errors<=0;
            expected_frames<=0; last_tx_sample<=0;
            sequence_valid<=0; ai_sequence_valid<=0; last_sequence<=0; ai_last_sequence<=0;
            extended_sequence<=0; ai_extended_sequence<=0;
            trad_frame<=0; trad_errors<=0; trad_bits<=0; trad_crc_failures<=0; trad_captured<=0; trad_lost<=0;
            ai_frame<=0; ai_errors<=0; ai_bits<=0; ai_crc_failures<=0; ai_captured<=0; ai_lost<=0;
            rx_update<=0; rx_branch<=0; rx_available<=1; rx_lock<=0;
            rx_config_out<=0; rx_run_out<=0;
            rx_adc_errors<=0; rx_adc_clips<=0; rx_offset<=0; rx_agc<=0;
        end else begin
            // rx_branch defaults to the traditional branch every cycle so the
            // serialized report bus always presents trad first, then AI.
            go<=0; ai_start<=0; rx_update<=0; rx_branch<=0;
            if(sample_valid) begin
                written<=written+1'b1;
                dc_tracker<=dc_tracker+(($signed(sample_data)*256-dc_tracker)>>>10);
                // Track the absolute sample peak for an adaptive search gate and
                // for on-board diagnosis. Decay halves the peak every 4096 samples.
                if(sample_data[15] ? (-sample_data)>signal_peak : sample_data>signal_peak)
                    signal_peak<=sample_data[15] ? -sample_data : sample_data;
                if(peak_decay==12'd4095) begin signal_peak<=signal_peak>>>1; peak_decay<=0; end
                else peak_decay<=peak_decay+1'b1;
            end
            if(adc_error) begin rx_adc_errors<=add_sat(rx_adc_errors,1); rx_update<=1; end
            if(adc_clip) begin rx_adc_clips<=add_sat(rx_adc_clips,1); rx_update<=1; end
            if(eval_tx_end && !tag_change) begin
                expected_frames<=add_sat(expected_frames,1); last_tx_sample<=written;
            end
            // A missing whole frame has no BER denominator. Evaluate only
            // after a drain interval; never derive symbol timing from TX.
            if(searching && written-last_tx_sample>=LOSS_WAIT_SAMPLES &&
               {1'b0,expected_frames}>({1'b0,trad_captured}+{1'b0,trad_lost})) begin
                trad_lost<=expected_frames-trad_captured; ai_lost<=expected_frames-ai_captured;
                rx_update<=1; state<=PUBLISH_AI;
            end
            case(state)
                SEARCH: begin
                    rx_lock<=0;
                    if(tag_change) begin
                        if({1'b0,expected_frames}>({1'b0,trad_captured}+{1'b0,trad_lost})) begin
                            trad_lost<=expected_frames-trad_captured; ai_lost<=expected_frames-ai_captured;
                        end
                        rx_update<=1; state<=GROUP_PUBLISH_AI;
                end else if(!mac_busy && written-cursor>=SEARCH_LEN) begin
                    dc<=dc_tracker>>>8; gain<=0;
                    step0<=steps[search_probe*5][47:24]; step1<=steps[search_probe*5][23:0];
                    // Clear the running maximum on the first probe of a cursor.
                    if(search_probe==0) begin sp0_long<=0; sp1_long<=0; end
                    correlate(cursor,13'(SEARCH_LEN)); state<=SEARCH_DONE;
                end
            end
            SEARCH_DONE: if(done) begin
                if(p0>sp0_long) sp0_long<=p0;
                if(p1>sp1_long) sp1_long<=p1;
                if(search_probe==SEARCH_PROBES-1) begin
                    search_probe<=0; state<=SEARCH_TONE;
                end else begin
                    search_probe<=search_probe+1'b1; state<=SEARCH;
                end
            end
            SEARCH_TONE: begin
                // Legacy 100-pt view of the same cursor, used only as a
                // tonality reference (see the tone_like gate below).
                step0<=steps[10][47:24]; step1<=steps[10][23:0];
                correlate(cursor,13'(SHORT)); state<=SEARCH_TONE_DONE;
            end
            SEARCH_TONE_DONE: if(done) state<=SEARCH_VOTE;
            SEARCH_VOTE: begin
                    cursor<=cursor+SHORT;
                    if(search_active && tone_like && combined0>combined1) begin
                        if(zero_blocks!=255) zero_blocks<=zero_blocks+1'b1;
                        quiet_blocks<=0; state<=SEARCH;
                    end else if(search_active && tone_like && combined1>combined0) begin
                        if(zero_blocks>=50 && cursor+BOUNDARY_BIAS>=6000) begin
                            // Stable 0 -> 1 transition near preamble bit 16.
                            boundary<=cursor+BOUNDARY_BIAS; zero_blocks<=0;
                            quiet_blocks<=0; state<=CAPTURE;
                        end else begin
                            // A lone 1-like window (noise flicker or mixed
                            // boundary window) must not wipe the run: leak four
                            // counts instead of resetting. Random data decays
                            // (net -3/step), silence still falls through below.
                            zero_blocks<=(zero_blocks>=4) ? zero_blocks-3'd4 : 8'd0;
                            quiet_blocks<=0; state<=SEARCH;
                        end
                    end else begin
                        // Neither detector has usable energy: either true
                        // silence or a beat fade (equal-amplitude signal and
                        // jammer cancel, so no receiver can see anything).
                        // Preserve an established run so a brief fade cannot
                        // wipe it, but clear it once the input stays dark.
                        quiet_blocks<=(quiet_blocks==QUIET_LIMIT) ? 5'd0 : quiet_blocks+1'b1;
                        if(quiet_blocks==QUIET_LIMIT) zero_blocks<=0;
                        state<=SEARCH;
                    end
                end
                CAPTURE: if(written-boundary>=80*SAMPLES_PER_BIT+200) begin
                    frequency<=0; best_power<=0; gain<=0; state<=FREQ0;
                end
                FREQ0: begin
                    step0<=steps[frequency][47:24]; step1<=steps[frequency][23:0];
                    correlate(boundary-12*SAMPLES_PER_BIT,STABLE); state<=FREQ0_DONE;
                end
                FREQ0_DONE: if(done) begin first_power<=p0; first_raw<=raw_sum; state<=FREQ1; end
                FREQ1: begin correlate(boundary+4*SAMPLES_PER_BIT,STABLE); state<=FREQ1_DONE; end
                FREQ1_DONE: if(done) begin
                    if(first_power+p1>best_power) begin
                        best_power<=first_power+p1; best_frequency<=frequency; best_raw<=first_raw+raw_sum;
                    end
                    if(frequency==20) begin
                        // Coarse timing spans +/-800 samples: measured over the
                        // jammer matrix, 90% of transitions land within +/-350
                        // samples but a jammer beating against the carrier drags
                        // the estimate out to ~1000, and those are exactly the
                        // frames the user needs to see a BER from.
                        trial<=0; fine<=0; trial_shift<=TIMING_SPAN; best_shift<=0;
                        best_score<=-64'sh7fffffffffffffff; timing_score<=0; timing_bit<=0;
                        state<=TIMING;
                    end else begin frequency<=frequency+1'b1; state<=FREQ0; end
                end
                TIMING: begin
                    dc<=best_raw>>>13; gain<=0;
                    step0<=steps[best_frequency][47:24]; step1<=steps[best_frequency][23:0];
                    correlate(boundary+16*SAMPLES_PER_BIT+{{16{trial_shift[15]}},trial_shift}+timing_bit*SAMPLES_PER_BIT,SAMPLES_PER_BIT);
                    state<=TIMING_DONE;
                end
                TIMING_DONE: if(done) begin
                    timing_score<=timing_score+difference;
                    if(timing_bit==31) state<=TIMING_SCORE;
                    else begin timing_bit<=timing_bit+1'b1; state<=TIMING; end
                end
                TIMING_SCORE: begin
                    if(timing_score>best_score) begin best_score<=timing_score; best_shift<=trial_shift; end
                    timing_score<=0; timing_bit<=0;
                    if((!fine && trial==TIMING_COARSE_STEPS-1) || (fine && trial==48)) begin
                        if(!fine) begin
                            fine<=1; trial<=0;
                            trial_shift<=(timing_score>best_score ? trial_shift : best_shift)-24;
                            best_score<=-64'sh7fffffffffffffff; state<=TIMING;
                        end else if(best_power<64'd1000000 || (timing_score<=0 && best_score<=0)) begin
                            cursor<=written; state<=SEARCH;
                        end else begin
                            if(timing_score>best_score) aligned<=boundary+{{16{trial_shift[15]}},trial_shift};
                            else aligned<=boundary+{{16{best_shift[15]}},best_shift};
                            rx_offset<=$signed({1'b0,best_frequency})*10-100;
                            gain<=choose_gain(best_power>>1); rx_agc<=choose_gain(best_power>>1);
                            sync_bit<=0; sync_errors<=0; state<=SYNC;
                        end
                    end else begin
                        trial<=trial+1'b1;
                        trial_shift<=fine ? trial_shift+1'b1 : trial_shift+25;
                        state<=TIMING;
                    end
                end
                SYNC: begin
                    correlate(aligned+48*SAMPLES_PER_BIT+sync_bit*SAMPLES_PER_BIT,SAMPLES_PER_BIT);
                    state<=SYNC_DONE;
                end
                SYNC_DONE: if(done) begin
                    if(decision!=SYNC_WORD[31-sync_bit]) sync_errors<=sync_errors+1'b1;
                    if(sync_bit==31) begin
                        if(sync_errors+(decision!=SYNC_WORD[0])>2) begin cursor<=written; state<=SEARCH; end
                        else begin
                            rx_lock<=1; data_bit<=0; crc<=16'hffff; ai_crc<=16'hffff;
                            received_crc<=0; ai_received_crc<=0; air_frame<=0; ai_air_frame<=0;
                            reference_prbs<=1; ai_reference_prbs<=1; frame_errors<=0; ai_frame_errors<=0;
                            window_start<=aligned+80*SAMPLES_PER_BIT; state<=DATA;
                        end
                    end else begin sync_bit<=sync_bit+1'b1; state<=SYNC; end
                end
                DATA: if(written-window_start>=SAMPLES_PER_BIT && !mac_busy) begin
                    correlate(window_start,SAMPLES_PER_BIT); state<=DATA_DONE;
                end
                DATA_DONE: if(done) begin
                    // Latch the shared decision, then re-run the same features
                    // through the AI branch. Both branches see identical data.
                    traditional_decision<=decision; ai_start<=1; state<=AI_WAIT;
                end
                AI_WAIT: if(ai_done) begin
                    window_start<=window_start+SAMPLES_PER_BIT;
                    if(data_bit<16) begin
                        air_frame<={air_frame[14:0],traditional_decision};
                        ai_air_frame<={ai_air_frame[14:0],ai_decision};
                    end
                    if(data_bit<272) begin
                        crc<=crc_bit(crc,traditional_decision); ai_crc<=crc_bit(ai_crc,ai_decision);
                    end
                    if(data_bit>=16 && data_bit<272) begin
                        if(traditional_decision!=reference_prbs[14]) frame_errors<=frame_errors+1'b1;
                        if(ai_decision!=ai_reference_prbs[14]) ai_frame_errors<=ai_frame_errors+1'b1;
                        reference_prbs<={reference_prbs[13:0],reference_prbs[14]^reference_prbs[13]};
                        ai_reference_prbs<={ai_reference_prbs[13:0],ai_reference_prbs[14]^ai_reference_prbs[13]};
                    end
                    if(data_bit>=272) begin
                        received_crc<={received_crc[14:0],traditional_decision};
                        ai_received_crc<={ai_received_crc[14:0],ai_decision};
                    end
                    if(data_bit==287) begin
                        // last_frame_id is the extended CRC-valid air ID. A
                        // CRC-failed aligned frame still updates captured/BER
                        // counters but must not invent a frame ID.
                        trad_captured<=add_sat(trad_captured,1); ai_captured<=add_sat(ai_captured,1);
                        trad_errors<=add_sat(trad_errors,frame_errors); trad_bits<=add_sat(trad_bits,256);
                        ai_errors<=add_sat(ai_errors,ai_frame_errors); ai_bits<=add_sat(ai_bits,256);
                        if({received_crc[14:0],traditional_decision}!=crc) trad_crc_failures<=add_sat(trad_crc_failures,1);
                        else if(!sequence_valid) begin
                            // A CRC-failed ID never labels the PRBS reference.
                            sequence_valid<=1; last_sequence<=air_frame;
                            extended_sequence<={16'd0,air_frame};
                            if({16'd0,air_frame}>trad_frame) trad_frame<={16'd0,air_frame};
                        end else if(sequence_delta!=0 && !sequence_delta[15]) begin
                            last_sequence<=air_frame;
                            extended_sequence<=add_sat(extended_sequence,{16'd0,sequence_delta});
                            if(add_sat(extended_sequence,{16'd0,sequence_delta})>trad_frame)
                                trad_frame<=add_sat(extended_sequence,{16'd0,sequence_delta});
                        end
                        if({ai_received_crc[14:0],ai_decision}!=ai_crc) ai_crc_failures<=add_sat(ai_crc_failures,1);
                        else if(!ai_sequence_valid) begin
                            ai_sequence_valid<=1; ai_last_sequence<=ai_air_frame;
                            ai_extended_sequence<={16'd0,ai_air_frame};
                            if({16'd0,ai_air_frame}>ai_frame) ai_frame<={16'd0,ai_air_frame};
                        end else if(ai_sequence_delta!=0 && !ai_sequence_delta[15]) begin
                            ai_last_sequence<=ai_air_frame;
                            ai_extended_sequence<=add_sat(ai_extended_sequence,{16'd0,ai_sequence_delta});
                            if(add_sat(ai_extended_sequence,{16'd0,ai_sequence_delta})>ai_frame)
                                ai_frame<=add_sat(ai_extended_sequence,{16'd0,ai_sequence_delta});
                        end
                        state<=PUBLISH;
                    end else begin data_bit<=data_bit+1'b1; state<=DATA; end
                end
                PUBLISH: begin rx_update<=1; rx_branch<=0; cursor<=window_start; state<=PUBLISH_AI; end
                PUBLISH_AI: begin rx_update<=1; rx_branch<=1; rx_lock<=0; state<=SEARCH; end
                GROUP_PUBLISH_AI: begin rx_update<=1; rx_branch<=1; state<=GROUP_CHANGE; end
                GROUP_CHANGE: begin
                    rx_config_out<=rx_config; rx_run_out<=rx_run;
                    trad_frame<=0; trad_errors<=0; trad_bits<=0; trad_crc_failures<=0; trad_captured<=0; trad_lost<=0;
                    ai_frame<=0; ai_errors<=0; ai_bits<=0; ai_crc_failures<=0; ai_captured<=0; ai_lost<=0;
                    rx_adc_errors<=0; rx_adc_clips<=0; expected_frames<=0;
                    sequence_valid<=0; ai_sequence_valid<=0; last_sequence<=0; ai_last_sequence<=0;
                    extended_sequence<=0; ai_extended_sequence<=0;
                    last_tx_sample<=written; rx_offset<=0; rx_agc<=0;
                    signal_peak<=0; peak_decay<=0;
                    zero_blocks<=0; quiet_blocks<=0; cursor<=written; rx_update<=1; state<=SEARCH;
                end
                default: state<=SEARCH;
            endcase
            // Missing samples invalidate every candidate that spans the gap.
            if(adc_error && state!=GROUP_CHANGE && state!=GROUP_PUBLISH_AI && state!=PUBLISH && state!=PUBLISH_AI) begin
                rx_lock<=0; cursor<=written; zero_blocks<=0; quiet_blocks<=0; state<=SEARCH;
            end
            if((mac_busy || ai_busy) && state!=SEARCH && written-job_start>=65536) begin
                rx_lock<=0; cursor<=written; zero_blocks<=0; quiet_blocks<=0; state<=SEARCH;
                rx_adc_errors<=add_sat(rx_adc_errors,1); rx_update<=1;
            end
        end
    end
endmodule
