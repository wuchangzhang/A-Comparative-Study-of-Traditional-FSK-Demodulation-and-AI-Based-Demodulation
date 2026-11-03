module knob_control #(parameter integer CLK_HZ=100_000_000, UPDATE_CLKS=CLK_HZ/50,
                      DEADZONE=16, AVERAGE_LOG2=4, FREQ_TOLERANCE=10, CODE_TOLERANCE=1)(
    input logic clk,rst_n,
    input logic [11:0] adc_value,
    input logic adc_valid,
    input logic [4:0] key_press,
    input logic rearm, fsk_active,
    input control_pkg::dds_t dds_requested,
    input control_pkg::fsk_t fsk_requested,
    output logic [1:0] mode,
    output logic taken,event_valid,
    output logic signed [31:0] setting,
    output logic [11:0] filtered
);
    logic [11+AVERAGE_LOG2:0] sum;
    logic [AVERAGE_LOG2-1:0] count;
    logic [11:0] average,previous,position;
    logic average_valid,have_previous,old_fsk;
    integer timer;
    logic [2:0] state;
    logic [19:0] product;
    logic [7:0] freq_index;
    logic signed [12:0] mapped,target,prev_mapped,tolerance;
    logic [1:0] next_mode;
    logic moved,crossed,near_target;
    always_comb begin
        next_mode=mode;
        if(key_press[1]) next_mode=0;
        else if(key_press[2]) next_mode=1;
        else if(key_press[3]) next_mode=2;
    end
    always_ff @(posedge clk) begin
        if(!rst_n) begin
            sum<=0; count<=0; average<=0; average_valid<=0; filtered<=0;
            previous<=0; position<=0; have_previous<=0; mode<=0; taken<=0; timer<=0;
            event_valid<=0; setting<=1000; old_fsk<=0; state<=0; product<=0; freq_index<=0;
            mapped<=0; target<=0; prev_mapped<=0; tolerance<=0; moved<=0; crossed<=0; near_target<=0;
        end else begin
            event_valid<=0; old_fsk<=fsk_active; mode<=next_mode;
            if(adc_valid) begin
                if(count==(1<<AVERAGE_LOG2)-1) begin
                    average<=({1'b0,sum}+adc_value)>>AVERAGE_LOG2; sum<=0; count<=0; average_valid<=1;
                end else begin sum<=sum+adc_value; count<=count+1'b1; end
            end
            if(timer==UPDATE_CLKS-1) begin
                timer<=0;
                if(average_valid && state==0) begin position<=average; state<=1; end
            end else timer<=timer+1;
            case(state)
                1: begin product<=position*20'd190+20'd2047; state<=2; end
                // Exact divide by 4095: q=n>>12, remainder=n[11:0]+q.
                2: begin freq_index<=product[19:12]+(({1'b0,product[11:0]}+product[19:12])>=4095); state<=3; end
                3: begin
                    case(mode)
                        0: begin mapped<=13'd100+freq_index*13'd10; target<=dds_requested.hz[12:0]; tolerance<=FREQ_TOLERANCE; end
                        1: begin mapped<=$signed({1'b0,position[11:4]})-13'sd128;
                            target<=fsk_active ? fsk_requested.bias : dds_requested.bias; tolerance<=CODE_TOLERANCE; end
                        2: begin mapped<={5'd0,position[11:4]};
                            target<=fsk_active ? fsk_requested.amplitude : dds_requested.amplitude; tolerance<=CODE_TOLERANCE; end
                    endcase
                    moved<=(position>=previous ? position-previous : previous-position)>=DEADZONE;
                    state<=4;
                end
                4: begin
                    crossed<=have_previous && moved && ((prev_mapped<target && mapped>=target) || (prev_mapped>target && mapped<=target));
                    near_target<=(mapped-target<=tolerance && target-mapped<=tolerance); state<=5;
                end
                5: begin
                    filtered<=position; state<=0;
                    if(!have_previous || moved) begin previous<=position; prev_mapped<=mapped; have_previous<=1; end
                    if(!taken && (near_target || crossed)) begin
                        taken<=1; previous<=position; prev_mapped<=mapped; have_previous<=1;
                    end else if(taken && moved) begin setting<=mapped; event_valid<=1; end
                end
                default: ;
            endcase
            if(rearm || next_mode!=mode || old_fsk!=fsk_active) begin
                taken<=0; event_valid<=0; have_previous<=0; state<=0;
            end
        end
    end
endmodule
