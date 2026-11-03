module statistics(
    input logic clk,rst_n,frame_start,frame_end,frame_prepare,frame_active,fsk_active,config_change,
    input logic [31:0] config_id,
    input logic dac_clip,
    input logic test_command,run_requested,
    input logic [1:0] test_action,
    input logic [31:0] target_frames,
    input logic rx_update,rx_branch,rx_available,rx_lock,ai_available,
    input logic [31:0] rx_config,rx_run,rx_frame,rx_errors,rx_bits,rx_crc_failures,rx_captured,rx_lost,
    input logic [31:0] rx_adc_errors,rx_adc_clips,rx_model,
    input logic signed [15:0] rx_offset,rx_agc,
    output logic signed [15:0] trad_offset,trad_agc,ai_offset,ai_agc,
    output logic test_running,test_exit,final_report,test_pending,
    output logic [31:0] run_id,tx_frames,dac_clips,test_frames,adc_errors,adc_clips,
    output logic [255:0] trad_stats,ai_stats
);
    logic [1:0] pending_action;
    logic action_pending;
    logic old_fsk,group_closed;
    function automatic [31:0] inc(input [31:0] x);
        inc=(x==32'hffffffff) ? x : x+1'b1;
    endfunction
    // Final pulse precedes the reset cycle so telemetry captures the old group.
    logic clear_next,stop_next,start_next;
    assign test_pending=action_pending || clear_next || test_command || stop_next || final_report;
    always_ff @(posedge clk) begin
        if(!rst_n) begin
            test_running<=0; test_exit<=0; final_report<=0; run_id<=0;
            tx_frames<=0; dac_clips<=0; test_frames<=0; adc_errors<=0; adc_clips<=0;
            trad_stats<=0; ai_stats<=0; action_pending<=0; pending_action<=0;
            clear_next<=0; stop_next<=0; start_next<=0; old_fsk<=0; group_closed<=0;
            trad_offset<=0; trad_agc<=0; ai_offset<=0; ai_agc<=0;
        end else begin
            test_exit<=0; final_report<=0; old_fsk<=fsk_active;
            if(final_report || config_change) group_closed<=1;
            if(frame_prepare && group_closed && !action_pending) begin clear_next<=1; start_next<=0; end
            if(dac_clip) dac_clips<=inc(dac_clips);
            if(frame_end) begin
                tx_frames<=inc(tx_frames);
                if(test_running) begin
                    test_frames<=inc(test_frames);
                    if(test_frames>=target_frames-1) begin
                        test_running<=0; test_exit<=1; stop_next<=1;
                    end
                end
            end
            if(stop_next) begin final_report<=1; stop_next<=0; end
            if(action_pending && pending_action==1 && !run_requested) pending_action<=0;
            if(config_change) begin clear_next<=1; start_next<=0; test_running<=0; end
            if(action_pending && !frame_active && !frame_end && !clear_next &&
               (pending_action!=1 || frame_prepare) && !test_command) begin
                action_pending<=0; final_report<=!config_change;
                if(pending_action==0) begin test_running<=0; test_exit<=1; end
                else begin clear_next<=1; start_next<=(pending_action==1); end
            end
            // STOP explicitly cancels a pending START; the manager rejects other overwrites.
            if(test_command) begin action_pending<=1; pending_action<=test_action; end
            if(old_fsk && !fsk_active) begin final_report<=1; test_running<=0; end
            if(clear_next) begin
                clear_next<=0; tx_frames<=0; dac_clips<=0; test_frames<=0;
                trad_stats<=0; ai_stats<=0; adc_errors<=0; adc_clips<=0;
                trad_offset<=0; trad_agc<=0; ai_offset<=0; ai_agc<=0; group_closed<=0;
                run_id<=run_id+1'b1; test_running<=start_next;
            end
            if(rx_update && rx_config==config_id && rx_run==run_id && !clear_next && !config_change) begin
                if(!rx_branch && (trad_stats[255:224]==0 || rx_frame>=trad_stats[63:32])) begin
                    trad_stats<={31'd0,rx_available,rx_errors,rx_bits,rx_crc_failures,rx_captured,rx_lost,rx_frame,rx_model};
                    trad_offset<=rx_offset; trad_agc<=rx_agc;
                end
                if(rx_branch && (ai_stats[255:224]==0 || rx_frame>=ai_stats[63:32])) begin
                    ai_stats<={31'd0,ai_available,rx_errors,rx_bits,rx_crc_failures,rx_captured,rx_lost,rx_frame,rx_model};
                    ai_offset<=rx_offset; ai_agc<=rx_agc;
                end
                adc_errors<=rx_adc_errors; adc_clips<=rx_adc_clips;
            end
        end
    end
endmodule
