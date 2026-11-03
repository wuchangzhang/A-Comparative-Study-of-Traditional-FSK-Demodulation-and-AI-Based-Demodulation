`timescale 1ns/1ps
// Isolation test: a pure DC segment (the quiet interval the receiver sees
// between evaluation frames) must never be mistaken for a preamble. The
// receiver tracks DC continuously, so the step from the idle bias to the
// tail level leaves a low-frequency transient; that transient is what used to
// false-lock once the search window became more sensitive.
module tb_dc_tail;
    logic clk=0,rst_n=0,valid=0,adc_error=0,adc_clip=0,eval_end=0;
    logic signed [15:0] sample_data=0;
    logic [31:0] config_id=1,run_id=0;
    wire update,branch,available,locked;
    wire [31:0] cfg,run,frame,errors,bits,crc_fail,captured,lost,adc_errors,clips,model;
    wire signed [15:0] offset,agc,peak;
    always #5 clk=~clk;
    fsk_receiver dut(.clk(clk),.rst_n(rst_n),.sample_valid(valid),.sample_data(sample_data),
        .adc_error(adc_error),.adc_clip(adc_clip),.rx_config(config_id),.rx_run(run_id),.eval_tx_end(eval_end),
        .rx_update(update),.rx_branch(branch),.rx_available(available),.rx_lock(locked),
        .rx_config_out(cfg),.rx_run_out(run),.rx_frame(frame),.rx_errors(errors),.rx_bits(bits),
        .rx_crc_failures(crc_fail),.rx_captured(captured),.rx_lost(lost),.rx_adc_errors(adc_errors),
        .rx_adc_clips(clips),.rx_model(model),.rx_offset(offset),.rx_agc(agc),.rx_signal_peak(peak));
    integer n;
    integer locks=0;
    task automatic emit(input integer value);
        begin @(negedge clk); valid=1; sample_data=value;
            @(negedge clk); valid=0; repeat(499) @(negedge clk); end
    endtask
    always @(posedge clk) if(rst_n && dut.state==3) locks<=locks+1;
    initial begin
        repeat(5) @(negedge clk); rst_n=1;
        for(n=0;n<4000;n=n+1) emit(100);
        for(n=0;n<40000;n=n+1) begin
            emit(1234);
            if(n%5000==0) $display("  t=%0t state=%0d captured=%0d locks=%0d boundary=%0d",
                $time,dut.state,captured,locks,dut.boundary);
        end
        $display("  final state=%0d captured=%0d locks=%0d",dut.state,captured,locks);
        if(captured!=0 || locks!=0)
            $fatal(1,"DC tail false-locked: captured=%0d capture_entries=%0d",captured,locks);
        $display("PASS tb_dc_tail: 40k-sample DC segment produced no preamble candidate");
        $finish;
    end
    initial begin #(64'd4000000000); $fatal(1,"dc tail timeout state=%0d",dut.state); end
endmodule
