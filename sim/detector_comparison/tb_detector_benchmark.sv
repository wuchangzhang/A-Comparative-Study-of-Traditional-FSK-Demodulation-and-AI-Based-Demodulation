`timescale 1ns/1ps
module tb_detector_benchmark;
    logic clk=0,rst_n=0,start=0;
    always #5 clk=~clk;
    logic [23:0] step0,step1;
    logic signed [3:0] gain;
    wire [3:0] done,decision;
    wire [15:0] address[0:3];
    logic signed [15:0] samples[0:49999];
    integer sample_base=0;
    genvar mode;
    generate for(mode=0;mode<4;mode=mode+1) begin: detectors
        detector_benchmark #(.MODE(mode)) dut(
            .clk(clk),.rst_n(rst_n),.start(start),.first_address(16'd0),
            .step0(step0),.step1(step1),.dc(16'sd0),.gain(gain),
            .memory_data(samples[sample_base+address[mode]]),.address(address[mode]),
            .done(done[mode]),.decision(decision[mode]));
    end endgenerate
    integer vector_file,status,test_count=0,cycle,i;
    integer latency[0:3];
    logic [3:0] expected,seen;
    logic [159:0] expected_features;
    initial begin
        $readmemh("rtl_samples.mem",samples);
        vector_file=$fopen("rtl_vectors.txt","r");
        if(!vector_file) $fatal(1,"Missing vectors");
        repeat(5) @(negedge clk);
        rst_n=1;
        while(!$feof(vector_file)) begin
            status=$fscanf(vector_file,"%h %h %h %h %h\n",step0,step1,gain,expected,expected_features);
            if(status!=5) $fatal(1,"Invalid vector");
            @(negedge clk); start=1;
            @(negedge clk); start=0;
            seen=0; cycle=0;
            while(seen!=4'b1111 && cycle<6000) begin
                @(negedge clk);
                cycle=cycle+1;
                for(i=0;i<4;i=i+1) if(done[i]) begin
                    if(seen[i]) $fatal(1,"Duplicate done");
                    seen[i]=1; latency[i]=cycle;
                    if(decision[i]!==expected[i])
                        $fatal(1,"Decision mismatch vector=%0d mode=%0d expected=%0b got=%0b",test_count,i,expected[i],decision[i]);
                end
            end
            if(seen!=4'b1111) $fatal(1,"Timeout");
            if(detectors[3].dut.features!==expected_features)
                $fatal(1,"Feature mismatch vector=%0d",test_count);
            test_count=test_count+1;
            sample_base=sample_base+500;
        end
        $fclose(vector_file);
        $display("PASS tb_detector_benchmark: %0d vectors, four decisions and AI features match integer reference; cycles full=%0d majority=%0d trim=%0d ai=%0d",test_count,latency[0],latency[1],latency[2],latency[3]);
        $finish;
    end
    initial begin #10000000; $fatal(1,"Global timeout"); end
endmodule
