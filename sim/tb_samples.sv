`timescale 1ns/1ps
module tb_samples;
    import control_pkg::*;
    logic clk=0,rst_n=0,sample_ce=0,fsk_active=0,frame_active=0,fsk_bit=0;
    always #5 clk=~clk;
    dds_t dds_cfg=DDS_DEFAULT;
    fsk_t fsk_cfg=FSK_DEFAULT;
    wire [7:0] sample_data;
    wire sample_valid,clipped;
    wire [31:0] phase_debug;
    logic jam_enable=0, jam_burst=0;
    logic [7:0] jam_amplitude=0;
    logic [11:0] jam_hz=1500;
    integer clips=0,valids=0;
    logic [31:0] old_phase;
    logic [31:0] expected_word;
    logic [7:0] expected_saw;
    integer saw_wraps=0;
    logic [7:0] rom_address=0;
    wire [11:0] saw_rom_data;
    rom_sawtooth reference_rom(.clock(clk),.address(rom_address),.q(saw_rom_data));
    sample_path dut(.*);
    task sample;
        begin
            @(negedge clk); old_phase=phase_debug; expected_word=fcw(fsk_active ?
                ((fsk_bit ? 32'd2000 : 32'd1000)+{{16{fsk_cfg.offset_hz[15]}},fsk_cfg.offset_hz}) : dds_cfg.hz); sample_ce=1;
            @(posedge clk); #1; if(sample_valid) $fatal(1,"Early valid");
            @(negedge clk); sample_ce=0;
            wait(sample_valid); #1; if(^sample_data===1'bx) $fatal(1,"Pipeline invalid");
            if(phase_debug!==old_phase+expected_word) $fatal(1,"Phase discontinuity or incorrect frequency");
            if(clipped) clips=clips+1; valids=valids+1;
            repeat(8) @(negedge clk);
        end
    endtask
    initial begin
        repeat(4) @(negedge clk); rst_n=1; repeat(10) @(negedge clk);
        for(integer code=0;code<256;code=code+1) begin
            rom_address=code; @(posedge clk); #1;
            if(saw_rom_data!==((code*4095)/255)) $fatal(1,"Sawtooth ROM code %d",code);
            @(negedge clk);
        end
        dds_cfg.amplitude=0; dds_cfg.bias=10; repeat(5) sample();
        if(sample_data!=138) $fatal(1,"Amplitude/bias");
        dds_cfg.amplitude=128; dds_cfg.bias=0;
        for(integer wave=0;wave<4;wave=wave+1) begin dds_cfg.wave=wave; repeat(30) sample(); end
        dds_cfg.wave=3; dds_cfg.amplitude=255; dds_cfg.bias=0;
        repeat(300) begin
            sample();
            if(sample_data!==phase_debug[31:24]) $fatal(1,"Sawtooth sample/phase mismatch");
            if(phase_debug<old_phase) saw_wraps=saw_wraps+1;
        end
        if(saw_wraps<2) $fatal(1,"Sawtooth wrap not exercised");
        @(negedge clk); sample_ce=1;
        @(posedge clk); #1; expected_saw=phase_debug[31:24];
        @(negedge clk); sample_ce=0; dds_cfg.wave=1; dds_cfg.amplitude=0; dds_cfg.bias=10;
        wait(sample_valid); #1;
        if(sample_data!==expected_saw) $fatal(1,"Sawtooth in-flight metadata mixed");
        repeat(8) @(negedge clk);
        fsk_active=1; frame_active=0; fsk_cfg.bias=20; repeat(5) sample();
        if(sample_data!=148) $fatal(1,"FSK idle bias");
        frame_active=1; fsk_cfg.amplitude=128; fsk_cfg.noise_scale=65535;
        fsk_cfg.software_noise=1; fsk_cfg.physical_noise=0; repeat(30) sample();
        if(clips!=0) $fatal(1,"Software bypassed physical switch");
        fsk_cfg.physical_noise=1; repeat(500) sample();
        if(clips==0) $fatal(1,"Noise saturation not counted");
        fsk_bit=1; fsk_cfg.offset_hz=-100; repeat(5) sample();
        if(dut.word_reg!==fcw(1900)) $fatal(1,"Negative offset FCW");
        fsk_cfg.offset_hz=100; fsk_bit=0; repeat(5) sample();
        if(dut.word_reg!==fcw(1100)) $fatal(1,"Positive offset FCW");
        fsk_active=0; frame_active=0; dds_cfg.amplitude=0; dds_cfg.bias=-20;
        repeat(5) @(negedge clk); sample_ce=1; @(negedge clk); sample_ce=0;
        dds_cfg.amplitude=255; dds_cfg.bias=0; dds_cfg.wave=1;
        wait(sample_valid); #1;
        if(sample_data!=108) $fatal(1,"In-flight sample mixed configurations");
        $display("PASS tb_samples: four waves, sawtooth values/wrap/in-flight metadata, idle, noise gate, saturation, signed FCW"); $finish;
    end
endmodule
