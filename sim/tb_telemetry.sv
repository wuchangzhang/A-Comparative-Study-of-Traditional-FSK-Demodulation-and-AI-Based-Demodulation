`timescale 1ns/1ps
module tb_telemetry;
    logic clk=0,rst_n=0,status_request=0,final_valid=0,ready=0;
    logic session_reset=0;
    logic [15:0] status_seq=123;
    wire [15:0] seq;
    wire final_ready;
    logic [31:0] final_config=8;
    logic [1151:0] final_pages=0;
    always #5 clk=~clk;
    logic [31:0] config_id=7;
    logic [1151:0] status_pages=0,report_pages=0;
    wire valid;
    wire [7:0] cmd;
    wire [511:0] payload;
    telemetry #(.REPORT_CLKS(10000)) dut(.*);
    task tick; begin @(posedge clk); #1; @(negedge clk); end endtask
    task page(input integer c,input integer p,input integer cfg,input integer value);
        begin
            wait(valid); #1;
            if(cmd!=c || payload[503:496]!=p || payload[455:424]!=cfg || payload[423:392]!=value)
                $fatal(1,"Page mismatch");
            ready=1; tick(); ready=0;
        end
    endtask
    initial begin
        repeat(3) tick(); rst_n=1;
        status_pages[1151:1120]=11; status_pages[767:736]=22; status_pages[383:352]=33;
        status_request=1; tick(); status_request=0; repeat(3) tick();
        config_id=8; status_pages='1;
        report_pages[1151:1120]=77; report_pages[767:736]=88; report_pages[383:352]=99;
        final_pages=report_pages; final_pages[927:896]=2; final_valid=1;
        config_id=9; report_pages=0;
        repeat(10) tick();
        page('h82,0,7,11); page('h82,1,7,22); page('h82,2,7,33);
        if(seq!=123) $fatal(1,"STATUS request sequence lost");
        wait(final_ready); tick(); final_valid=0;
        wait(valid); #1;
        if(payload[199:168]!=2) $fatal(1,"Final flag not preserved");
        page('h83,0,8,77); page('h83,1,8,88); page('h83,2,8,99);
        status_request=1; tick(); status_request=0; tick();
        if(!valid || seq!=123) $fatal(1,"Missing reconnect fixture status");
        session_reset=1; tick(); session_reset=0; repeat(3) tick();
        if(valid || dut.status_pending) $fatal(1,"Old session status survived PING");
        $display("PASS tb_telemetry: frozen pages, concurrent final configuration, final flag, backpressure"); $finish;
    end
    initial begin #100000; $fatal(1,"Telemetry timeout"); end
endmodule
