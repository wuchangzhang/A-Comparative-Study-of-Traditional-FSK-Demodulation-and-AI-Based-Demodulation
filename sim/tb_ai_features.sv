`timescale 1ns/1ps
module tb_ai_features;
    logic clk=0,rst_n=0,start=0,feature_enable=0,done,busy,feature_saturation;
    logic [15:0] first_address=0;
    logic [12:0] length=13'd500;
    logic [23:0] step0=0,step1=0;
    logic signed [15:0] dc=0;
    logic signed [3:0] gain=0;
    logic [15:0] address;
    logic signed [15:0] memory_data=0;
    logic [63:0] power0,power1;
    logic signed [31:0] raw_sum;
    logic [159:0] features;
    always #5 clk=~clk;
    // Simple synchronous-read sample memory.
    logic signed [15:0] mem[0:2047];
    always_ff @(posedge clk) memory_data<=mem[address[10:0]];
    fsk_correlator dut(.clk(clk),.rst_n(rst_n),.start(start),.first_address(first_address),
        .length(length),.step0(step0),.step1(step1),.dc(dc),.gain(gain),
        .feature_enable(feature_enable),.address(address),.memory_data(memory_data),
        .done(done),.busy(busy),.power0(power0),.power1(power1),.raw_sum(raw_sum),
        .features(features),.feature_saturation(feature_saturation));
    integer fd, code, row, col, total;
    integer c_delta, c_step0, c_step1;
    integer c_dc, c_gain;
    integer sample_val;
    integer c_full0, c_full1;
    integer feat[0:9];
    integer feat_exp[0:9];
    integer feat_err;
    task automatic run_case;
        begin
            @(negedge clk); start=1; @(negedge clk); start=0;
            while(!done) @(negedge clk);
            if(power0[63:0]!=c_full0[31:0] || power1[63:0]!=c_full1[31:0])
                $fatal(1,"row %0d full-window power mismatch p0=%0d exp %0d p1=%0d exp %0d",
                    row,power0,c_full0,power1,c_full1);
            for(col=0;col<10;col=col+1) feat[col]=features[col*16 +: 16];
            feat_err=0;
            for(col=0;col<10;col=col+1)
                if(feat[col]!=feat_exp[col]) begin
                    feat_err=1;
                    $display("  feature[%0d]=%0d expected %0d",col,feat[col],feat_exp[col]);
                end
            if(feat_err) $fatal(1,"row %0d feature mismatch",row);
        end
    endtask
    initial begin
        #20 rst_n=1;
        repeat(4) @(negedge clk);
        fd=$fopen("ai_feature_golden.txt","r");
        if(!fd) $fatal(1,"missing ai_feature_golden.txt");
        code=$fscanf(fd,"%d\n",total);
        for(row=0;row<total;row=row+1) begin
            code=$fscanf(fd,"%d %d %d %d %d",c_delta,c_dc,c_gain,c_step0,c_step1);
            for(col=0;col<500;col=col+1) begin
                code=$fscanf(fd,"%d",sample_val);
                mem[col]=sample_val;
            end
            code=$fscanf(fd,"%d %d",c_full0,c_full1);
            for(col=0;col<10;col=col+1) code=$fscanf(fd,"%d",feat_exp[col]);
            dc=c_dc; gain=c_gain; step0=c_step0; step1=c_step1;
            feature_enable=1; first_address=0; length=13'd500;
            run_case;
        end
        $fclose(fd);
        // Verify feature_enable=0 produces identical full-window powers too.
        fd=$fopen("ai_feature_golden.txt","r");
        code=$fscanf(fd,"%d\n",total);
        for(row=0;row<total;row=row+1) begin
            code=$fscanf(fd,"%d %d %d %d %d",c_delta,c_dc,c_gain,c_step0,c_step1);
            for(col=0;col<500;col=col+1) begin
                code=$fscanf(fd,"%d",sample_val); mem[col]=sample_val;
            end
            code=$fscanf(fd,"%d %d",c_full0,c_full1);
            for(col=0;col<10;col=col+1) code=$fscanf(fd,"%d",feat_exp[col]);
            dc=c_dc; gain=c_gain; step0=c_step0; step1=c_step1;
            feature_enable=0; first_address=0; length=13'd500;
            @(negedge clk); start=1; @(negedge clk); start=0;
            while(!done) @(negedge clk);
            if(power0[63:0]!=c_full0[31:0] || power1[63:0]!=c_full1[31:0])
                $fatal(1,"row %0d (feature_enable=0) full-window power mismatch p0=%0d exp %0d p1=%0d exp %0d",
                    row,power0,c_full0,power1,c_full1);
        end
        $fclose(fd);
        $display("PASS tb_ai_features: 4 synthetic windows, 10-dim features and full powers match golden (both modes)");
        $finish;
    end
    initial begin #(64'd5000000); $fatal(1,"ai_features test timeout"); end
endmodule
