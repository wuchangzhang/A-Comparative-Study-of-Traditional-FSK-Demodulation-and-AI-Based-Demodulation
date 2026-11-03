`timescale 1ns/1ps
module tb_frame_gate;
    logic clk=0,rst_n=0,sample_ce=1,run_requested=1,frame_allow=0;
    always #5 clk=~clk;
    wire fsk_active,frame_active,frame_prepare,frame_start,frame_end,bit_boundary,data_bit;
    wire [15:0] frame_id;
    wire [8:0] bit_index;
    integer ends=0;
    fsk_frame_tx #(.SAMPLES_PER_BIT(1),.GAP_SAMPLES(8)) dut(.*);
    task tick; begin @(posedge clk); #1; @(negedge clk); end endtask
    always @(negedge clk) if(frame_end) ends=ends+1;
    initial begin
        repeat(3) tick(); rst_n=1; repeat(30) tick();
        if(frame_active || frame_prepare || dut.gap_count!=6) $fatal(1,"Queue gate failed to hold gap");
        frame_allow=1; wait(frame_active); @(negedge clk); frame_allow=0;
        wait(frame_end); repeat(30) tick();
        if(ends!=1 || frame_active || frame_prepare || dut.gap_count!=6) $fatal(1,"Gate truncated or launched frame");
        run_requested=0; repeat(3) tick();
        if(fsk_active) $fatal(1,"Queue pressure blocked safe exit");
        $display("PASS tb_frame_gate: full queue holds DC gap, running frame completes, exit stays available"); $finish;
    end
    initial begin #20000; $fatal(1,"Gate timeout"); end
endmodule
