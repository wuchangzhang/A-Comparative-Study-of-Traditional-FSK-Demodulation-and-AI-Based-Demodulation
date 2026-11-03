`timescale 1ns/1ps
module tb_dac;
    import control_pkg::*;
    logic clk=0,rst_n=0;
    always #5 clk=~clk;
    wire sample_ce,sample_valid,clipped,busy,done,dac_ile,dac_cs_n,dac_wr1_n,dac_wr2_n,dac_xfer_n;
    wire [7:0] sample_data,dac_data;
    wire [31:0] phase_debug;
    dds_t dds_cfg=DDS_DEFAULT;
    fsk_t fsk_cfg=FSK_DEFAULT;
    sample_tick tick(.clk(clk),.rst_n(rst_n),.sample_ce(sample_ce));
    sample_path path(.clk(clk),.rst_n(rst_n),.sample_ce(sample_ce),.fsk_active(1'b0),.frame_active(1'b0),
        .fsk_bit(1'b0),.dds_cfg(dds_cfg),.fsk_cfg(fsk_cfg),.sample_data(sample_data),
        .jam_enable(1'b0),.jam_burst(1'b0),.jam_amplitude(8'd0),.jam_hz(12'd1500),
        .sample_valid(sample_valid),.clipped(clipped),.phase_debug(phase_debug));
    dac0832_driver dac(.*);
    integer cycle=0,last_sample=0,samples=0,finished=0;
    time wr1_start,wr2_start;
    always @(posedge clk) if(rst_n) begin
        cycle=cycle+1;
        if(sample_valid) begin
            if(busy) $fatal(1,"DAC overrun");
            if(samples>0 && cycle-last_sample!=1000) $fatal(1,"Sample interval");
            last_sample=cycle; samples=samples+1;
        end
        if(done) finished=finished+1;
    end
    always @(negedge dac_wr1_n) wr1_start=$time;
    always @(posedge dac_wr1_n) if(rst_n && $time-wr1_start!=1000) $fatal(1,"WR1 pulse width");
    always @(negedge dac_wr2_n) wr2_start=$time;
    always @(posedge dac_wr2_n) if(rst_n && $time-wr2_start!=1000) $fatal(1,"WR2 pulse width");
    initial begin
        repeat(4) @(negedge clk); rst_n=1;
        wait(finished==100);
        if(samples!=100) $fatal(1,"DAC sample loss");
        $display("PASS tb_dac: 100 MHz / 100 kSPS, 100 complete DAC writes, 1 us strobes, no overrun"); $finish;
    end
endmodule
