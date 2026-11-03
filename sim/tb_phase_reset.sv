`timescale 1ns/1ps
module tb_phase_reset;
    logic clk=0,rst_n=0,sample_ce=0;
    always #5 clk=~clk;
    wire [31:0] sync_phase,baseline_phase;
    logic board_reset_n=0;
    ego1_control_top board(.sys_clk_in(clk),.sys_rst_n(board_reset_n),
        .btn_pin(5'b11111),.noise_switch(1'b0),.uart_rx(1'b1),.knob_p(1'b0),.knob_n(1'b0));
    phase_acc_ce #(.SYNC_RESET(1)) current(.clk(clk),.rst_n(rst_n),.sample_ce(sample_ce),
        .freq_word(32'd100),.phase(sync_phase),.rom_addr());
    phase_acc_ce baseline(.clk(clk),.rst_n(rst_n),.sample_ce(sample_ce),
        .freq_word(32'd100),.phase(baseline_phase),.rom_addr());
    initial begin
        repeat(3) @(negedge clk); rst_n=1; sample_ce=1;
        repeat(4) @(posedge clk); #1;
        if(sync_phase!=400 || baseline_phase!=400) $fatal(1,"Phase accumulation changed");
        @(negedge clk); #1; rst_n=0; #1;
        if(sync_phase!=400 || baseline_phase!=0) $fatal(1,"Reset modes not distinct");
        @(posedge clk); #1;
        if(sync_phase!=0) $fatal(1,"Synchronous reset not clocked");
        @(negedge clk); rst_n=1;
        @(posedge clk); #1;
        if(sync_phase!=100 || baseline_phase!=100) $fatal(1,"Reset recovery changed increment");
        if(board.rst_n!==0 || board.u_core.u_samples.sample_valid!==0)
            $fatal(1,"Board core did not reset");
        @(negedge clk); board_reset_n=1;
        repeat(2) begin
            @(posedge clk); #1;
            if(board.rst_n!==0) $fatal(1,"Board reset released before synchronization");
        end
        @(posedge clk); #1;
        if(board.rst_n!==1) $fatal(1,"Board reset did not release at clock edge");
        repeat(1200) @(posedge clk);
        @(negedge clk); #1; board_reset_n=0; #1;
        if(board.rst_n!==1) $fatal(1,"ROM controls received asynchronous reset assertion");
        @(posedge clk); #1;
        if(board.rst_n!==0) $fatal(1,"Board reset assertion was not clocked");
        repeat(6) @(posedge clk); #1;
        if(board.u_core.u_samples.sample_valid!==0 || board.u_core.u_samples.phase_debug!==0)
            $fatal(1,"Board sample pipeline not flushed by reset");
        $display("PASS tb_phase_reset: clocked board reset, synchronous ROM address reset, baseline mode retained, recovery increment"); $finish;
    end
endmodule
