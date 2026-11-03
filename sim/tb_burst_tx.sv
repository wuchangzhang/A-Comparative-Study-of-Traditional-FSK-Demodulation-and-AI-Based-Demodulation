`timescale 1ns/1ps
module tb_burst_tx;
    import control_pkg::*;
    logic clk=0, rst_n=0, sample_ce=0, run_requested=0;
    always #5 clk=~clk;
    wire fsk_active, frame_active, frame_prepare, frame_start, frame_end, bit_boundary, data_bit;
    wire [15:0] frame_id;
    wire [8:0] bit_index;
    wire [7:0] sample_data;
    wire sample_valid, clipped;
    wire [31:0] phase_debug;
    dds_t dds_cfg=DDS_DEFAULT;
    fsk_t fsk_cfg=FSK_DEFAULT;
    fsk_frame_tx tx(.*,.frame_allow(1'b1));
    sample_path path(.clk(clk),.rst_n(rst_n),.sample_ce(sample_ce),
        .fsk_active(fsk_active),.frame_active(frame_active),.fsk_bit(data_bit),
        .dds_cfg(dds_cfg),.fsk_cfg(fsk_cfg),.jam_enable(frame_active && bit_index>=96),
        .jam_burst(1'b1),.jam_amplitude(8'd80),.jam_hz(12'd1050),
        .sample_data(sample_data),.sample_valid(sample_valid),.clipped(clipped),.phase_debug(phase_debug));
    integer output_file, n, fired=0, gate_count=0, quarters[0:3];
    integer decimate=0, captured=0, clips=0;
    always @(posedge clk) begin
        if(frame_end) run_requested<=0;
        if(sample_valid) begin
            if(clipped) clips=clips+1;
            decimate=decimate+1;
            if(decimate%2==0) begin
                $fdisplay(output_file,"%0d",(integer'(sample_data)-128)*128);
                captured=captured+1;
            end
        end
    end
    initial begin
        output_file=$fopen("burst_adc.txt","w");
        if(!output_file) $fatal(1,"Cannot create capture");
        fsk_cfg.amplitude=32;
        fsk_cfg.software_noise=0; fsk_cfg.physical_noise=0;
        for(n=0;n<4;n=n+1) quarters[n]=0;
        repeat(4) @(negedge clk); rst_n=1; run_requested=1;
        for(n=0;n<424000;n=n+1) begin
            @(negedge clk); sample_ce=1;
            #1;
            if(frame_active && bit_index>=96 && path.burst_gate) begin
                gate_count=gate_count+1;
                quarters[path.selected_slot]=quarters[path.selected_slot]+1;
            end
            if(frame_active && bit_index<96 && path.jam_latched) $fatal(1,"Preamble jammer leak");
            @(negedge clk); sample_ce=0;
            repeat(8) @(negedge clk);
        end
        repeat(10) @(negedge clk);
        $fclose(output_file);
        if(clips!=0) $fatal(1,"DAC clipping: %0d",clips);
        if(gate_count<20000 || gate_count>50000) $fatal(1,"Unexpected burst duty: %0d",gate_count);
        for(n=0;n<4;n=n+1) if(quarters[n]==0) $fatal(1,"Slot %0d unused",n);
        $display("PASS tb_burst_tx: %0d ADC samples, gate=%0d, four slots exercised, no DAC clipping",captured,gate_count);
        $finish;
    end
endmodule
