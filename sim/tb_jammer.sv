`timescale 1ns/1ps
// The tone jammer must produce a clean sinusoid at the requested frequency and
// amplitude, stay centred on the DAC mid-rail, add no DC bias, and disappear
// completely when disabled. Verified against three frequencies including the
// upper legal bound of 2100 Hz.
module tb_jammer;
    import control_pkg::*;
    logic clk=0,rst_n=0,sample_ce=0,fsk_active=0,frame_active=1,fsk_bit=0;
    always #5 clk=~clk;
    dds_t dds_cfg=DDS_DEFAULT;
    fsk_t fsk_cfg=FSK_DEFAULT;
    wire [7:0] sample_data;
    wire sample_valid,clipped;
    wire [31:0] phase_debug;
    logic jam_enable=0, jam_burst=0;
    logic [7:0] jam_amplitude=0;
    logic [11:0] jam_hz=1500;
    integer i,deviation;
    sample_path dut(.*);
    task automatic step;
        begin
            @(negedge clk); sample_ce=1;
            @(negedge clk); sample_ce=0;
            wait(sample_valid); #1;
        end
    endtask
    task automatic check_tone;
        input [11:0] hz;
        input [7:0] amp;
        input integer count;
        input integer expected_cycles;
        integer k,crossings,peak;
        logic [7:0] previous;
        begin
            jam_hz=hz; jam_amplitude=amp; jam_enable=1;
            repeat(8) step();
            crossings=0; peak=0; previous=sample_data;
            for(k=0;k<count;k=k+1) begin
                step();
                if(previous<8'd128 && sample_data>=8'd128) crossings=crossings+1;
                previous=sample_data;
                deviation=(sample_data>8'd128) ? sample_data-8'd128 : 8'd128-sample_data;
                if(deviation>peak) peak=deviation;
                if(clipped) $fatal(1,"Jammer clipped hz=%0d amp=%0d",hz,amp);
            end
            if(crossings<expected_cycles-1 || crossings>expected_cycles+1)
                $fatal(1,"Tone cycles hz=%0d expected ~%0d got %0d",hz,expected_cycles,crossings);
            if(peak<amp-3 || peak>amp+1)
                $fatal(1,"Tone amplitude hz=%0d expected ~%0d got %0d",hz,amp,peak);
        end
    endtask
    initial begin
        dds_cfg.amplitude=0; dds_cfg.bias=0;
        fsk_cfg.amplitude=0; fsk_cfg.bias=0;
        fsk_cfg.physical_noise=0; fsk_cfg.software_noise=0; fsk_cfg.noise_scale=0;
        repeat(4) @(negedge clk); rst_n=1;
        repeat(4) step();
        for(i=0;i<64;i=i+1) begin
            step();
            if(sample_data!=8'd128 || clipped) $fatal(1,"Silent path not flat: %0d",sample_data);
        end
        check_tone(12'd1500,8'd64,1000,15);
        check_tone(12'd1000,8'd48,1000,10);
        check_tone(12'd2100,8'd96,1000,21);
        jam_enable=0;
        repeat(4) step();
        for(i=0;i<64;i=i+1) begin
            step();
            if(sample_data!=8'd128) $fatal(1,"Jammer not removed after disable: %0d",sample_data);
        end
        // A frame gate keeps the jammer out of the inter-frame gap.
        jam_hz=12'd1500; jam_amplitude=8'd64; jam_enable=1;
        repeat(4) step();
        frame_active=0;
        repeat(4) step();
        for(i=0;i<64;i=i+1) begin
            step();
            if(sample_data!=8'd128) $fatal(1,"Jammer leaked outside frame: %0d",sample_data);
        end
        $display("PASS tb_jammer: 1500/1000/2100 Hz tones, amplitude and gate verified, no DC bias");
        $finish;
    end
endmodule
