`timescale 1ns/1ps
module tb_uart_system;
    import control_pkg::*;
    logic clk=0,rst_n=0,uart_rx=1,noise_switch=0;
    always #5 clk=~clk;
    logic [4:0] buttons=0;
    wire uart_tx;
    wire [7:0] sample_data;
    wire sample_valid,tx_bit,frame_active,frame_start,frame_end;
    wire [15:0] led,display_value;
    wire [1:0] display_wave,display_mode;
    wire [31:0] config_id,run_id;
    logic rx_update=0,rx_branch=0,rx_available=0,ai_available=0;
    logic [31:0] rx_errors=0,rx_bits=0;
    control_core #(.CLK_HZ(1_000_000),.BAUD(100_000),.SAMPLE_HZ(10_000),
        .DEBOUNCE_CLKS(4),.KNOB_UPDATE_CLKS(100),.SAMPLES_PER_BIT(2),
        .GAP_SAMPLES(100),.REPORT_CLKS(20000)) dut(
        .clk(clk),.rst_n(rst_n),.buttons(buttons),.noise_switch(noise_switch),
        .uart_rx(uart_rx),.uart_tx(uart_tx),.knob_adc(12'd0),.knob_valid(1'b0),
        .sample_data(sample_data),.sample_valid(sample_valid),.led(led),
        .display_value(display_value),.display_wave(display_wave),.display_mode(display_mode),
        .tx_bit(tx_bit),.frame_active(frame_active),.frame_start(frame_start),.frame_end(frame_end),
        .config_id(config_id),.run_id(run_id),
        .rx_update(rx_update),.rx_branch(rx_branch),.rx_available(rx_available),.ai_available(ai_available),.rx_lock(1'b0),
        .rx_config(config_id),.rx_run(run_id),.rx_frame(32'd3),.rx_errors(rx_errors),.rx_bits(rx_bits),
        .rx_crc_failures(32'd0),.rx_captured(32'd0),.rx_lost(32'd0),.rx_adc_errors(32'd0),
        .rx_adc_clips(32'd0),.rx_model(32'd0),.rx_offset(-16'sd42),.rx_agc(-16'sd2),.rx_signal_peak(16'sd0),
        .adc_state_code(4'd0),.adc_error_reason(4'd0),.adc_busy_level(1'b0),
        .adc_dout_level(1'b0),.adc_reset_count(32'd0));
    logic [7:0] incoming=0;
    logic incoming_valid=0;
    wire packet_valid;
    wire [7:0] cmd,length,error;
    wire [15:0] seq;
    wire [511:0] payload;
    packet_rx monitor(.clk(clk),.rst_n(rst_n),.byte_data(incoming),.byte_valid(incoming_valid),
        .byte_error(1'b0),.packet_valid(packet_valid),.cmd(cmd),.length(length),.error(error),.seq(seq),.payload(payload));
    integer capture, executions=0, replies=0, last_seq=-1,last_cmd=-1,last_error=-1;
    integer status_received=0;
    integer key_counts[0:4];
    always @(negedge clk) if(rst_n) begin
        if(dut.execute) executions=executions+1;
        for(integer k=0;k<5;k=k+1) if(dut.key_press[k]) key_counts[k]=key_counts[k]+1;
        if(packet_valid) begin
            if(error!==0) $fatal(1,"Response CRC failed or unknown");
            if(cmd==8'h82) status_received=status_received+1;
            if(cmd==8'h80 || cmd==8'h81 || cmd==8'h84) begin
                replies=replies+1; last_seq=seq; last_cmd=cmd; last_error=payload[503:496];
            end
        end
    end
    // Independent wire sampler; the Python codec also checks this byte capture.
    initial begin
        capture=$fopen("uart_tx.hex","w");
        forever begin
            @(negedge uart_tx); repeat(15) @(posedge clk);
            for(integer b=0;b<8;b=b+1) begin incoming[b]=uart_tx; repeat(10) @(posedge clk); end
            if(!uart_tx) $fatal(1,"UART stop bit");
            @(negedge clk); incoming_valid=1; $fdisplay(capture,"%02x",incoming);
            @(negedge clk); incoming_valid=0;
        end
    end
    task send_byte(input [7:0] value);
        begin
            @(negedge clk); uart_rx=0; repeat(10) @(negedge clk);
            for(integer b=0;b<8;b=b+1) begin uart_rx=value[b]; repeat(10) @(negedge clk); end
            uart_rx=1; repeat(10) @(negedge clk);
        end
    endtask
    function automatic [15:0] crc_ref(input [15:0] c,input [7:0] d);
        reg [15:0] r;
        begin
            r=c;
            for(integer b=7;b>=0;b=b-1) begin
                if(r[15]^d[b]) r=(r<<1)^16'h1021; else r=r<<1;
            end
            crc_ref=r;
        end
    endfunction
    task request(input [7:0] c,input [7:0] n,input [15:0] s,input [511:0] data,input bit bad);
        reg [15:0] check;
        begin
            send_byte('h55); send_byte('haa); send_byte(c); send_byte(n); send_byte(s[15:8]); send_byte(s[7:0]);
            check=crc_ref(crc_ref(crc_ref(crc_ref(16'hffff,c),n),s[15:8]),s[7:0]);
            if(n<=64) begin
                for(integer i=0;i<n;i=i+1) begin send_byte(data[511-i*8 -:8]); check=crc_ref(check,data[511-i*8 -:8]); end
                send_byte(check[15:8]); send_byte(check[7:0]^{7'd0,bad});
            end
        end
    endtask
    task expect_reply(input integer s,input integer c,input integer e);
        integer count;
        begin
            count=0;
            while(last_seq!=s && count<50000) begin @(negedge clk); count=count+1; end
            if(last_seq!=s || last_cmd!=c || (c==129 && last_error!=e))
                $fatal(1,"Reply expected %d/%d/%d got %d/%d/%d",s,c,e,last_seq,last_cmd,last_error);
            last_seq=-1;
        end
    endtask
    task key(input integer k);
        begin
            buttons[k]=1; repeat(2) @(negedge clk); buttons[k]=0; repeat(2) @(negedge clk);
            buttons[k]=1; repeat(100) @(negedge clk); buttons[k]=0; repeat(20) @(negedge clk);
            if(key_counts[k]!=1) $fatal(1,"Key %d repeated or missed",k);
        end
    endtask
    reg [511:0] data;
    integer before_exec;
    initial begin
        for(integer k=0;k<5;k=k+1) key_counts[k]=0;
        repeat(5) @(negedge clk); rst_n=1;
        request(6,0,1,0,0); expect_reply(1,132,0);
        data=0; data[511:448]={32'd1500,8'd3,8'd128,16'd10};
        request(1,8,2,data,0); expect_reply(2,128,0);
        repeat(200) @(negedge clk);
        if(dut.dds_active.hz!=1500 || dut.dds_active.bias!=10) $fatal(1,"DDS not applied");
        before_exec=executions;
        request(1,8,2,data,0); expect_reply(2,128,0);
        if(executions!=before_exec) $fatal(1,"Duplicate executed");
        data[511:480]=1600; request(1,8,2,data,0); expect_reply(2,129,6);
        data[511:480]=99999; request(1,8,3,data,0); expect_reply(3,129,3);
        data[511:480]=1700; request(1,8,4,data,1); expect_reply(4,129,1);
        request(1,65,5,0,0); expect_reply(5,129,2);
        send_byte('h55); send_byte('haa); send_byte(1); send_byte(8);
        repeat(100100) @(negedge clk);
        if(dut.dds_active.hz!=1500) $fatal(1,"Invalid command mutated DDS");
        request(6,0,2,0,0); expect_reply(2,132,0);
        request(1,8,2,data,0); expect_reply(2,128,0);
        for(integer k=0;k<4;k=k+1) key(k);
        if(dut.knob_mode!=2 || dut.dds_requested.wave!=0) $fatal(1,"Local controls");
        data[511:448]={32'd1700,8'd3,8'd128,16'd10};
        request(1,8,15,data,0); expect_reply(15,128,0);
        repeat(200) @(negedge clk);
        if(dut.dds_active.wave!=3 || display_wave!=3) $fatal(1,"UART sawtooth not applied/displayed");
        request(5,0,10,0,0); expect_reply(10,128,0);
        noise_switch=1;
        data=0; data[511:488]={8'd1,16'd512}; request(4,3,11,data,0); expect_reply(11,128,0);
        data=0; data[511:392]={32'd1000,32'd2000,16'd100,8'd128,16'd0,16'hff9c};
        request(2,15,12,data,0); expect_reply(12,128,0);
        data=0; data[511:472]={8'd1,32'd2}; request(7,5,13,data,0); expect_reply(13,128,0);
        wait(dut.test_running); if(config_id!=1) $fatal(1,"Initial pending configuration");
        before_exec=executions; request(7,5,13,data,0); expect_reply(13,128,0);
        if(executions!=before_exec) $fatal(1,"Test start repeated");
        wait(!dut.fsk_active); repeat(30000) @(negedge clk);
        if(dut.tx_frames!=2 || dut.test_frames!=2 || dut.test_running) $fatal(1,"Target frame count");
        if(dut.dds_active.hz!=1700 || dut.dds_active.wave!=3) $fatal(1,"Sawtooth DDS restore");
        if(dut.trad_stats!=0 || dut.ai_stats!=0) $fatal(1,"Fabricated receiver statistics");
        key(4); wait(frame_active); buttons[4]=1; repeat(100) @(negedge clk); buttons[4]=0;
        if(!frame_active) $fatal(1,"Early exit"); wait(!dut.fsk_active);
        @(negedge clk); rx_available=1; rx_errors=2; rx_bits=768; rx_update=1;
        @(negedge clk); rx_update=0; repeat(22000) @(negedge clk);
        rx_branch=1; ai_available=1; rx_errors=5; rx_bits=512; rx_update=1;
        @(negedge clk); rx_update=0;
        request(5,0,14,0,0); expect_reply(14,128,0); wait(status_received==6);
        repeat(22000) @(negedge clk);
        $fclose(capture);
        $display("PASS tb_uart_system: wire CRC, length, timeout, retry, reconnect, five keys, pending test start, target stop, DDS restore"); $finish;
    end
    initial begin #20000000; $fatal(1,"System timeout"); end
endmodule
