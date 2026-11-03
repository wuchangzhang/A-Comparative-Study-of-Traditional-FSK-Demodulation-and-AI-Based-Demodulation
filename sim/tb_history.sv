`timescale 1ns/1ps
module tb_history;
    logic clk=0,rst_n=0,close_event=0,final_ready=0;
    always #5 clk=~clk;
    logic [31:0] config_id=1;
    logic [1151:0] report_pages=0;
    logic rx_update=0,rx_branch=0,rx_available=1,ai_available=1;
    logic [31:0] rx_config=1,rx_run=1,rx_frame=1,rx_errors=2,rx_bits=256,
        rx_crc_failures=1,rx_captured=1,rx_lost=0,rx_adc_errors=3,rx_adc_clips=4,rx_model=9;
    logic signed [15:0] rx_offset=-42,rx_agc=3;
    wire report_space,final_valid;
    wire [31:0] final_config,dropped;
    wire [1151:0] final_pages;
    logic [1151:0] frozen;
    report_history #(.RX_DRAIN_CLKS(40)) dut(.*);
    task tick; begin @(posedge clk); #1; @(negedge clk); end endtask
    task close_group(input integer cfg,input integer run,input integer sent);
        begin config_id=cfg; report_pages=0; report_pages[1151:1120]=sent;
            report_pages[1087:1056]=run; close_event=1; tick(); close_event=0; tick(); end
    endtask
    task receive(input bit branch,input integer cfg,input integer run,input integer errors,input integer offset);
        begin rx_branch=branch; rx_config=cfg; rx_run=run; rx_errors=errors; rx_offset=offset;
            rx_update=1; tick(); rx_update=0; tick(); end
    endtask
    task pop_group(input integer cfg,input integer run);
        begin wait(final_valid); #1;
            if(final_config!=cfg || final_pages[1087:1056]!=run) $fatal(1,"Group order/tag");
            final_ready=1; tick(); final_ready=0; tick(); end
    endtask
    initial begin
        repeat(3) tick(); rst_n=1; tick();
        close_group(1,1,1);
        close_group(2,2,1);
        if(final_valid) $fatal(1,"Final sealed before delayed RX");
        receive(0,1,1,2,-42);
        if(final_valid) $fatal(1,"AI completion was not awaited");
        receive(1,1,1,5,17); tick();
        if(!final_valid || final_pages[703:672]!=256 || final_pages[319:288]!=256 ||
           $signed(final_pages[511:496])!=-42 || $signed(final_pages[127:112])!=17)
            $fatal(1,"Delayed old-group counters/measurements missing");
        frozen=final_pages;
        receive(1,1,1,99,99);
        if(final_pages!=frozen) $fatal(1,"Sealed record changed under backpressure");
        pop_group(1,1);
        repeat(45) tick();
        if(!final_valid || final_pages[927:896]!=32'h36) $fatal(1,"Timeout not explicitly incomplete");
        pop_group(2,2);
        rx_available=0; ai_available=0;
        close_group(3,3,1); close_group(4,4,1); close_group(5,5,1);
        if(report_space) $fatal(1,"Reserved slot not protected");
        close_group(6,6,1);
        repeat(4) tick();
        if(dropped || dut.count!=4) $fatal(1,"Final group lost");
        // Same-tag closure is deduplicated even when full.
        close_event=1; tick(); close_event=0; tick();
        if(dropped || dut.count!=4) $fatal(1,"Duplicate close consumed capacity");
        pop_group(3,3); pop_group(4,4); pop_group(5,5); pop_group(6,6);
        if(!report_space || final_valid || dropped) $fatal(1,"FIFO did not recover");
        close_group(7,7,0); wait(final_valid);
        final_ready=1; config_id=8; report_pages[1087:1056]=8; close_event=1;
        tick(); final_ready=0; close_event=0; tick();
        pop_group(8,8);
        $display("PASS tb_history: delayed old tags, independent branches, frozen measurements, timeout, four-slot FIFO, reservation, dedupe, simultaneous push/pop");
        $finish;
    end
    initial begin #100000; $fatal(1,"History timeout"); end
endmodule
