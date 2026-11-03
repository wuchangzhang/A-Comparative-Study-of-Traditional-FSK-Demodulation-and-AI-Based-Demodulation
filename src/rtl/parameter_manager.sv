module parameter_manager (
    input logic clk, rst_n, sample_ce, frame_prepare, fsk_active,
    input logic [4:0] key_press,
    input logic physical_noise,
    input logic knob_event,
    input logic [1:0] knob_mode,
    input logic signed [31:0] knob_setting,
    input logic cmd_valid,
    input logic [7:0] cmd, cmd_len,
    input logic [511:0] payload,
    input logic test_running, test_exit, test_pending, report_space,
    output logic [7:0] cmd_error,
    output logic run_requested,
    output control_pkg::dds_t dds_requested, dds_active,
    output control_pkg::fsk_t fsk_requested, fsk_active_cfg,
    output logic dds_pending, fsk_pending,
    output logic [31:0] config_id,
    output logic config_change,
    output logic knob_rearm,
    output logic test_command,
    output logic [1:0] test_action,
    output logic [31:0] target_frames,
    output logic jam_enable, jam_burst,
    output logic [7:0] jam_amplitude,
    output logic [11:0] jam_hz
);
    import control_pkg::*;
    dds_t dn, da, candidate_dds;
    fsk_t fn, fa, candidate_fsk;
    logic rn, rearm_n, test_n, jam_n, jam_burst_n;
    logic [1:0] action_n;
    logic [31:0] target_n;
    logic [7:0] jam_amp_n;
    logic [11:0] jam_hz_n;
    logic jam_commit;
    logic [21:0] jam_commit_values;
    assign dds_pending = (dds_requested != dds_active);
    assign fsk_pending = (fsk_requested != fsk_active_cfg);
    // The sender reserves a prepare cycle before the first sample of every frame.
    assign config_change = (frame_prepare && fsk_pending) || jam_commit;
    always_comb begin
        dn=dds_requested; fn=fsk_requested; rn=run_requested;
        da=dds_active; fa=fsk_active_cfg;
        rearm_n=0; test_n=0; action_n=0; target_n=target_frames;
        jam_n=jam_enable; jam_amp_n=jam_amplitude; jam_hz_n=jam_hz;
        jam_burst_n=jam_burst;
        cmd_error=OK;
        candidate_dds=dds_requested; candidate_fsk=fsk_requested;
        fn.physical_noise={7'd0,physical_noise};
        if (key_press[0]) dn.wave=(dn.wave==3) ? 0 : dn.wave+1'b1;
        if (key_press[4]) rn=!rn;
        if (knob_event) begin
            if (knob_mode==0) dn.hz=knob_setting;
            else if (fsk_active) begin
                if (knob_mode==1) fn.bias=knob_setting[15:0];
                else fn.amplitude=knob_setting[7:0];
                if (!legal_shape(fn.amplitude,fn.bias)) begin
                    fn.bias=fsk_requested.bias; fn.amplitude=fsk_requested.amplitude;
                end
            end else begin
                if (knob_mode==1) dn.bias=knob_setting[15:0];
                else dn.amplitude=knob_setting[7:0];
                if (!legal_shape(dn.amplitude,dn.bias)) begin
                    dn.bias=dds_requested.bias; dn.amplitude=dds_requested.amplitude;
                end
            end
        end
        if (cmd_valid) begin
            case(cmd)
                1: begin
                    candidate_dds=payload[511:448];
                    if (cmd_len!=8) cmd_error=BAD_LENGTH;
                    else if (candidate_dds.hz<100 || candidate_dds.hz>2000 ||
                             candidate_dds.wave>3 || !legal_shape(candidate_dds.amplitude,candidate_dds.bias)) cmd_error=OUT_OF_RANGE;
                    else begin dn=candidate_dds; rearm_n=1; end
                end
                2: begin
                    candidate_fsk.amplitude=payload[431:424];
                    candidate_fsk.bias=payload[423:408];
                    candidate_fsk.offset_hz=payload[407:392];
                    if (cmd_len!=15) cmd_error=BAD_LENGTH;
                    else if (payload[511:480]!=1000 || payload[479:448]!=2000 || payload[447:432]!=100) cmd_error=UNSUPPORTED_PROFILE;
                    else if (!legal_shape(candidate_fsk.amplitude,candidate_fsk.bias) ||
                             candidate_fsk.offset_hz < -100 || candidate_fsk.offset_hz > 100) cmd_error=OUT_OF_RANGE;
                    else begin
                        fn.amplitude=candidate_fsk.amplitude; fn.bias=candidate_fsk.bias;
                        fn.offset_hz=candidate_fsk.offset_hz; rearm_n=1;
                    end
                end
                3: begin
                    if(cmd_len!=1) cmd_error=BAD_LENGTH;
                    else if(payload[511:504]>1) cmd_error=OUT_OF_RANGE;
                    else rn=payload[504];
                end
                4: begin
                    if(cmd_len!=3) cmd_error=BAD_LENGTH;
                    else if(payload[511:504]>1) cmd_error=OUT_OF_RANGE;
                    else begin fn.software_noise=payload[511:504]; fn.noise_scale=payload[503:488]; end
                end
                5,6: if(cmd_len!=0) cmd_error=BAD_LENGTH;
                7: begin
                    if ((payload[511:504]==1 && cmd_len!=5) ||
                        (payload[511:504]!=1 && cmd_len!=1)) cmd_error=BAD_LENGTH;
                    else if(payload[511:504]>2 || (payload[511:504]==1 && payload[503:472]==0)) cmd_error=OUT_OF_RANGE;
                    else if((test_running || test_pending || test_exit || !report_space) && payload[511:504]!=0) cmd_error=BUSY;
                    else begin
                        test_n=1; action_n=payload[505:504];
                        if(payload[511:504]==1) begin rn=1; target_n=payload[503:472]; end
                        if(payload[511:504]==0) rn=0;
                    end
                end
                8: begin
                    // Narrowband jammer: payload[511:504] enable,
                    // [503:496] amplitude in DAC codes, [495:480] frequency u16.
                    if(cmd_len!=4 && cmd_len!=5) cmd_error=BAD_LENGTH;
                    else if(payload[511:504]>1 || payload[495:480]<100 || payload[495:480]>2100) cmd_error=OUT_OF_RANGE;
                    else if(cmd_len==5 && payload[479:472]>1) cmd_error=OUT_OF_RANGE;
                    else if(fsk_active || test_running || test_pending || jam_commit) cmd_error=BUSY;
                    else begin
                        jam_n=payload[504]; jam_amp_n=payload[503:496]; jam_hz_n=payload[495:480];
                        jam_burst_n=(cmd_len==5) && payload[472];
                    end
                end
                default: cmd_error=UNKNOWN_CMD;
            endcase
        end
        if(test_exit) rn=0;
        // Commit the pre-existing request. Events arriving on the boundary
        // are unambiguously pending for the following boundary.
        if(sample_ce && !fsk_active) da=dds_requested;
        if(frame_prepare) fa=fsk_requested;
    end
    always_ff @(posedge clk) begin
        if(!rst_n) begin
            dds_requested<=DDS_DEFAULT; dds_active<=DDS_DEFAULT;
            fsk_requested<=FSK_DEFAULT; fsk_active_cfg<=FSK_DEFAULT;
            run_requested<=0; config_id<=0; knob_rearm<=0;
            test_command<=0; test_action<=0; target_frames<=0;
            jam_enable<=0; jam_burst<=0; jam_amplitude<=0; jam_hz<=12'd1500;
            jam_commit<=0; jam_commit_values<=22'd1500;
        end else begin
            dds_requested<=dn; dds_active<=da;
            fsk_requested<=fn; fsk_active_cfg<=fa;
            run_requested<=rn; knob_rearm<=rearm_n;
            test_command<=test_n; test_action<=action_n; target_frames<=target_n;
            // Stage validation before the high-fanout report-close event. Commit
            // values and config_id together, after history snapshots the old group.
            jam_commit<=cmd_valid && cmd==8 && cmd_error==OK &&
                ({jam_n,jam_burst_n,jam_amp_n,jam_hz_n}!=
                 {jam_enable,jam_burst,jam_amplitude,jam_hz});
            if(cmd_valid && cmd==8 && cmd_error==OK)
                jam_commit_values<={jam_n,jam_burst_n,jam_amp_n,jam_hz_n};
            if(jam_commit)
                {jam_enable,jam_burst,jam_amplitude,jam_hz}<=jam_commit_values;
            if(config_change) config_id<=config_id+1'b1;
        end
    end
endmodule
