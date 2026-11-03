module fsk_frame_tx #(parameter integer SAMPLES_PER_BIT=1000, GAP_SAMPLES=20000)(
    input logic clk,rst_n,sample_ce,run_requested,frame_allow,
    output logic fsk_active,frame_active,frame_prepare,frame_start,frame_end,bit_boundary,
    output logic data_bit,
    output logic [15:0] frame_id,
    output logic [8:0] bit_index
);
    typedef enum logic [2:0] {OFF,GAP,PREPARE,ARM,TRANSMIT,DRAIN} state_t;
    state_t state;
    integer sample_count,gap_count;
    logic [14:0] prbs;
    logic [15:0] crc;
    logic next_bit;
    localparam [31:0] SYNC_WORD=32'h1acffc1d;
    assign fsk_active=(state!=OFF);
    assign frame_active=(state==TRANSMIT);
    assign frame_prepare=(state==PREPARE);
    always_comb begin
        if(bit_index<16) next_bit=0;
        else if(bit_index<32) next_bit=1;
        else if(bit_index<64) next_bit=~bit_index[0];
        else if(bit_index<96) next_bit=SYNC_WORD[95-bit_index];
        else if(bit_index<112) next_bit=frame_id[111-bit_index];
        else if(bit_index<368) next_bit=prbs[14];
        else next_bit=crc[383-bit_index];
        data_bit=next_bit;
    end
    always_ff @(posedge clk) begin
        if(!rst_n) begin
            state<=OFF; sample_count<=0; gap_count<=0; frame_id<=0;
            bit_index<=0; prbs<=1; crc<=16'hffff;
            frame_start<=0; frame_end<=0; bit_boundary<=0;
        end else begin
            frame_start<=0; frame_end<=0; bit_boundary<=0;
            case(state)
                OFF: if(run_requested) begin state<=GAP; gap_count<=0; end
                GAP: begin
                    if(!run_requested) state<=OFF;
                    else if(sample_ce) begin
                        if(gap_count==GAP_SAMPLES-2) begin
                            if(frame_allow) begin state<=PREPARE; gap_count<=0; end
                        end
                        else gap_count<=gap_count+1;
                    end
                end
                PREPARE: begin state<=ARM; prbs<=1; crc<=16'hffff; bit_index<=0; sample_count<=0; end
                ARM: if(!run_requested) state<=OFF;
                     else if(sample_ce) begin state<=TRANSMIT; frame_start<=1; bit_boundary<=1; end
                TRANSMIT: if(sample_ce) begin
                    if(sample_count==SAMPLES_PER_BIT-1) begin
                        sample_count<=0;
                        if(bit_index>=96 && bit_index<368)
                            crc<={crc[14:0],1'b0} ^ ((crc[15]^next_bit) ? 16'h1021 : 16'd0);
                        if(bit_index>=112 && bit_index<368) prbs<={prbs[13:0],prbs[14]^prbs[13]};
                        if(bit_index==383) state<=DRAIN;
                        else begin bit_index<=bit_index+1'b1; bit_boundary<=1; end
                    end else sample_count<=sample_count+1;
                end
                // Allow the last DAC transaction to finish before publishing frame_end.
                DRAIN: if(sample_ce) begin
                    frame_end<=1; frame_id<=frame_id+1'b1; gap_count<=1;
                    state<=GAP;
                end
                default: state<=OFF;
            endcase
        end
    end
endmodule
