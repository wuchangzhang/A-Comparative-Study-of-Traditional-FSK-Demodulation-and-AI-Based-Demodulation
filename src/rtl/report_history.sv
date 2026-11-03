// Closed groups drain tagged receiver snapshots before becoming immutable FIFO entries.
module report_history #(parameter integer DEPTH=4, RX_DRAIN_CLKS=100_000_000)(
    input logic clk,rst_n,close_event,
    input logic [31:0] config_id,
    input logic [1151:0] report_pages,
    input logic rx_update,rx_branch,rx_available,ai_available,
    input logic [31:0] rx_config,rx_run,rx_frame,rx_errors,rx_bits,rx_crc_failures,
                       rx_captured,rx_lost,rx_adc_errors,rx_adc_clips,rx_model,
    input logic signed [15:0] rx_offset,rx_agc,
    output logic report_space,final_valid,
    input logic final_ready,
    output logic [31:0] final_config,dropped,
    output logic [1151:0] final_pages
);
    localparam integer PTR_W=$clog2(DEPTH), TIMER_W=$clog2(RX_DRAIN_CLKS+1);
    logic [1151:0] pages[0:DEPTH-1];
    logic [31:0] configs[0:DEPTH-1];
    logic [TIMER_W-1:0] age[0:DEPTH-1];
    logic [DEPTH-1:0] occupied,sealed,expect_trad,expect_ai;
    logic [PTR_W-1:0] head,tail;
    logic [PTR_W:0] count;
    logic last_valid;
    logic [31:0] last_config,last_run;
    logic push,pop,unique_close;
    assign unique_close=close_event && (!last_valid || config_id!=last_config || report_pages[1087:1056]!=last_run);
    assign pop=final_valid && final_ready;
    assign push=unique_close && (count<DEPTH || pop);
    // Reserve one slot for the current group's eventual STOP/final frame.
    assign report_space=count<DEPTH-1;
    assign final_valid=(count!=0) && sealed[head];
    assign final_pages=pages[head];
    assign final_config=configs[head];
    function automatic logic complete_branch(input logic expected,input logic [255:0] stats,input logic [31:0] sent);
        complete_branch=!expected || (stats[224] && ({1'b0,stats[127:96]}+{1'b0,stats[95:64]}>={1'b0,sent}));
    endfunction
    always_ff @(posedge clk) begin
        if(!rst_n) begin
            head<=0; tail<=0; count<=0; occupied<=0; sealed<=0;
            expect_trad<=0; expect_ai<=0; last_valid<=0; last_config<=0; last_run<=0; dropped<=0;
            for(integer i=0;i<DEPTH;i=i+1) begin pages[i]<=0; configs[i]<=0; age[i]<=0; end
        end else begin
            case({push,pop})
                2'b10:count<=count+1'b1;
                2'b01:count<=count-1'b1;
                default: ;
            endcase
            for(integer i=0;i<DEPTH;i=i+1) begin
                if(occupied[i] && !sealed[i]) begin
                    if(age[i]<RX_DRAIN_CLKS) age[i]<=age[i]+1'b1;
                    if(rx_update && age[i]<RX_DRAIN_CLKS && rx_config==configs[i] && rx_run==pages[i][1087:1056]) begin
                        if(!rx_branch && (pages[i][767:736]==0 || rx_frame>=pages[i][575:544])) begin
                            pages[i][767:512]<={31'd0,rx_available,rx_errors,rx_bits,rx_crc_failures,rx_captured,rx_lost,rx_frame,rx_model};
                            pages[i][511:480]<={rx_offset,rx_agc};
                        end
                        if(rx_branch && (pages[i][383:352]==0 || rx_frame>=pages[i][191:160])) begin
                            pages[i][383:128]<={31'd0,ai_available,rx_errors,rx_bits,rx_crc_failures,rx_captured,rx_lost,rx_frame,rx_model};
                            pages[i][127:96]<={rx_offset,rx_agc};
                        end
                        pages[i][1023:960]<={rx_adc_errors,rx_adc_clips};
                    end else if((complete_branch(expect_trad[i],pages[i][767:512],pages[i][1151:1120]) &&
                                 complete_branch(expect_ai[i],pages[i][383:128],pages[i][1151:1120])) || age[i]>=RX_DRAIN_CLKS) begin
                        sealed[i]<=1;
                        pages[i][927:896]<=pages[i][927:896] |
                            (complete_branch(expect_trad[i],pages[i][767:512],pages[i][1151:1120]) ? 32'd0 : 32'h14) |
                            (complete_branch(expect_ai[i],pages[i][383:128],pages[i][1151:1120]) ? 32'd0 : 32'h24);
                    end
                end
            end
            if(pop) begin occupied[head]<=0; sealed[head]<=0; head<=(head==DEPTH-1) ? 0 : head+1'b1; end
            if(push) begin
                pages[tail]<=report_pages;
                pages[tail][927:896]<=(report_pages[927:896] & ~32'd1) | 32'd2;
                if(rx_update && rx_config==config_id && rx_run==report_pages[1087:1056]) begin
                    if(!rx_branch && (report_pages[767:736]==0 || rx_frame>=report_pages[575:544])) begin
                        pages[tail][767:512]<={31'd0,rx_available,rx_errors,rx_bits,rx_crc_failures,rx_captured,rx_lost,rx_frame,rx_model};
                        pages[tail][511:480]<={rx_offset,rx_agc};
                    end
                    if(rx_branch && (report_pages[383:352]==0 || rx_frame>=report_pages[191:160])) begin
                        pages[tail][383:128]<={31'd0,ai_available,rx_errors,rx_bits,rx_crc_failures,rx_captured,rx_lost,rx_frame,rx_model};
                        pages[tail][127:96]<={rx_offset,rx_agc};
                    end
                    pages[tail][1023:960]<={rx_adc_errors,rx_adc_clips};
                end
                configs[tail]<=config_id; age[tail]<=0; occupied[tail]<=1; sealed[tail]<=0;
                expect_trad[tail]<=rx_available && report_pages[1151:1120]!=0;
                expect_ai[tail]<=ai_available && report_pages[1151:1120]!=0;
                tail<=(tail==DEPTH-1) ? 0 : tail+1'b1;
                last_valid<=1; last_config<=config_id; last_run<=report_pages[1087:1056];
            end
            if(unique_close && !push && dropped!=32'hffffffff) dropped<=dropped+1'b1;
        end
    end
endmodule
