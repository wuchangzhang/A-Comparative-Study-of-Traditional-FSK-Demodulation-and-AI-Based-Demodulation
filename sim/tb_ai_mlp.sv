`timescale 1ns/1ps
module tb_ai_mlp;
    logic clk=0,rst_n=0,start=0,done,busy,decision,ai_available;
    logic [159:0] features=0;
    logic [31:0] model_version;
    always #5 clk=~clk;
    ai_mlp dut(.clk(clk),.rst_n(rst_n),.start(start),.features(features),
        .done(done),.busy(busy),.decision(decision),.ai_available(ai_available),
        .model_version(model_version));
    integer fd, code, row, col, total;
    logic signed [15:0] feat[0:9];
    logic signed [15:0] act1[0:15];
    logic signed [15:0] act2[0:7];
    logic signed [31:0] logit0,logit1;
    integer golden_decision;
    task automatic run_vector;
        begin
            @(negedge clk); start=1; @(negedge clk); start=0;
            while(!done) @(negedge clk);
            if(decision!=golden_decision[0])
                $fatal(1,"row %0d decision %0d expected %0d",row,decision,golden_decision);
        end
    endtask
    initial begin
        #20 rst_n=1;
        repeat(4) @(negedge clk);
        if(ai_available!==1) $fatal(1,"ai_available not asserted");
        if(model_version!==32'h00070001) $fatal(1,"model version %h",model_version);
        fd=$fopen("ai_golden.txt","r");
        if(!fd) $fatal(1,"missing ai_golden.txt");
        code=$fscanf(fd,"%d\n",total);
        if(total!=64) $fatal(1,"expected 64 rows got %0d",total);
        for(row=0;row<total;row=row+1) begin
            for(col=0;col<10;col=col+1) code=$fscanf(fd,"%d",feat[col]);
            for(col=0;col<16;col=col+1) code=$fscanf(fd,"%d",act1[col]);
            for(col=0;col<8;col=col+1) code=$fscanf(fd,"%d",act2[col]);
            code=$fscanf(fd,"%d",logit0);
            code=$fscanf(fd,"%d",logit1);
            code=$fscanf(fd,"%d",golden_decision);
            for(col=0;col<10;col=col+1) features[col*16 +: 16]=feat[col];
            run_vector;
        end
        $fclose(fd);
        // Second pass: reload file and run again to confirm no residue.
        fd=$fopen("ai_golden.txt","r");
        code=$fscanf(fd,"%d\n",total);
        for(row=0;row<total;row=row+1) begin
            for(col=0;col<10;col=col+1) code=$fscanf(fd,"%d",feat[col]);
            for(col=0;col<16;col=col+1) code=$fscanf(fd,"%d",act1[col]);
            for(col=0;col<8;col=col+1) code=$fscanf(fd,"%d",act2[col]);
            code=$fscanf(fd,"%d",logit0);
            code=$fscanf(fd,"%d",logit1);
            code=$fscanf(fd,"%d",golden_decision);
            for(col=0;col<10;col=col+1) features[col*16 +: 16]=feat[col];
            run_vector;
        end
        $fclose(fd);
        $display("PASS tb_ai_mlp: 64 golden vectors x2, availability, model version");
        $finish;
    end
    initial begin #(64'd2000000); $fatal(1,"ai_mlp test timeout"); end
endmodule
