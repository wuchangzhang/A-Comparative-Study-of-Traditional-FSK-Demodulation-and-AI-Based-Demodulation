`timescale 1ns/1ps
module tb_frame;
    logic frame_allow=1;
    logic clk=0,rst_n=0,sample_ce=0,run_requested=0;
    always #5 clk=~clk;
    wire fsk_active,frame_active,frame_prepare,frame_start,frame_end,bit_boundary,data_bit;
    wire [15:0] frame_id;
    wire [8:0] bit_index;
    reg [7:0] golden[0:143];
    integer divider=0,frames=0,samples=0,gap=0,previous_frame=-1;
    fsk_frame_tx #(.SAMPLES_PER_BIT(3),.GAP_SAMPLES(12)) dut(.*);
    always @(negedge clk) begin
        divider=(divider+1)%10; sample_ce=(divider==0);
    end
    always @(posedge clk) if(rst_n && sample_ce && fsk_active) begin
        if(frame_active) begin
            if(data_bit !== golden[frame_id*48+bit_index/8][7-bit_index%8])
                $fatal(1,"Frame mismatch frame=%d bit=%d",frame_id,bit_index);
            if(samples==0 && gap!=12) $fatal(1,"Gap was %d samples",gap);
            samples=samples+1; gap=0;
        end else gap=gap+1;
    end
    always @(negedge clk) if(frame_end) begin
        if(samples!=384*3) $fatal(1,"Frame duration %d",samples);
        frames=frames+1; samples=0;
    end
    initial begin
        $readmemh("frames.mem",golden);
        repeat(4) @(negedge clk); rst_n=1; run_requested=1;
        wait(frame_id==2 && bit_index==200); @(negedge clk); run_requested=0;
        wait(!fsk_active);
        if(frames!=3) $fatal(1,"Exit truncated frame");
        $display("PASS tb_frame: 3 independent golden frames, gap, boundary-safe exit"); $finish;
    end
    initial begin #2000000; $fatal(1,"Timeout"); end
endmodule
