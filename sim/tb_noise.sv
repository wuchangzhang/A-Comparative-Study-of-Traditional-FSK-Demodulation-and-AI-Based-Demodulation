`timescale 1ns/1ps
module tb_noise;
    import control_pkg::*;
    logic clk=0,rst_n=0,sample_ce=0,fsk_active=1,frame_active=1,fsk_bit=0;
    always #5 clk=~clk;
    dds_t dds_cfg=DDS_DEFAULT;
    fsk_t fsk_cfg=FSK_DEFAULT;
    wire [7:0] sample_data;
    wire sample_valid,clipped;
    wire [31:0] phase_debug;
    logic signed [15:0] table_values[0:255];
    logic [31:0] forced_rng;
    logic jam_enable=0, jam_burst=0;
    logic [7:0] jam_amplitude=0;
    logic [11:0] jam_hz=1500;
    integer scales[0:3];
    integer sum,expected,product;
    sample_path dut(.*);
    initial begin
        $readmemh("gaussian_q8.mem",table_values);
        scales[0]=0; scales[1]=1; scales[2]=256; scales[3]=2560;
        repeat(4) @(negedge clk); rst_n=1;
        fsk_cfg.amplitude=0; fsk_cfg.bias=0;
        fsk_cfg.physical_noise=1; fsk_cfg.software_noise=1;
        force dut.rng=forced_rng;
        for(integer s=0;s<4;s=s+1) begin
            fsk_cfg.noise_scale=scales[s]; sum=0;
            for(integer i=0;i<256;i=i+1) begin
                forced_rng=i<<24;
                repeat(8) @(negedge clk); sample_ce=1;
                @(negedge clk); sample_ce=0;
                wait(sample_valid); #1;
                product=$signed(table_values[i])*scales[s];
                expected=(product<0) ? -((-product+32768)/65536) : (product+32768)/65536;
                if(sample_data!=128+expected || clipped) $fatal(1,"Noise rounding scale=%d index=%d",scales[s],i);
                sum=sum+$signed({1'b0,sample_data})-128;
            end
            if(sum!=0) $fatal(1,"Noise DC bias scale=%d sum=%d",scales[s],sum);
        end
        release dut.rng;
        $display("PASS tb_noise: all 256 LUT entries at 0/1/256/2560, symmetric nearest rounding, zero DC bias");
        $finish;
    end
endmodule
