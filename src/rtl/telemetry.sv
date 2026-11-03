module telemetry #(parameter integer REPORT_CLKS=100_000_000)(
    input logic clk,rst_n,status_request,final_valid,session_reset,
    input logic [15:0] status_seq,
    output logic final_ready,
    input logic [31:0] final_config,
    input logic [1151:0] final_pages,
    input logic [31:0] config_id,
    input logic [1151:0] status_pages,report_pages,
    output logic valid,
    input logic ready,
    output logic [7:0] cmd,
    output logic [511:0] payload,
    output logic [15:0] seq
);
    logic status_pending,periodic_pending;
    logic [15:0] pending_seq;
    logic [1151:0] saved_pages;
    logic [31:0] saved_config,snapshot,next_snapshot;
    logic [1:0] page;
    integer timer;
    assign final_ready=!valid && !status_pending && !session_reset;
    always_comb begin
        payload=0;
        payload[511:424]={8'd2,{6'd0,page},8'd3,snapshot,saved_config};
        case(page)
            0:payload[423:40]=saved_pages[1151:768];
            1:payload[423:40]=saved_pages[767:384];
            2:payload[423:40]=saved_pages[383:0];
            default:payload[423:40]=0;
        endcase
    end
    always_ff @(posedge clk) begin
        if(!rst_n) begin
            status_pending<=0; periodic_pending<=0; saved_pages<=0; pending_seq<=0;
            saved_config<=0; snapshot<=0; next_snapshot<=0;
            page<=0; timer<=0; valid<=0; cmd<=0; seq<=0;
        end else begin
            if(timer==REPORT_CLKS-1) begin timer<=0; periodic_pending<=1; end else timer<=timer+1;
            if(valid && ready) begin
                if(page==2) begin valid<=0; page<=0; end else page<=page+1'b1;
            end
            if(!valid && !session_reset) begin
                if(status_pending) begin
                    saved_pages<=status_pages; saved_config<=config_id;
                    status_pending<=0; valid<=1; cmd<=8'h82; seq<=pending_seq; page<=0;
                    snapshot<=next_snapshot; next_snapshot<=next_snapshot+1'b1;
                end else if(final_valid) begin
                    saved_pages<=final_pages; saved_config<=final_config;
                    valid<=1; cmd<=8'h83; seq<=0; page<=0;
                    snapshot<=next_snapshot; next_snapshot<=next_snapshot+1'b1;
                end else if(periodic_pending) begin
                    saved_pages<=report_pages; saved_config<=config_id;
                    periodic_pending<=0; valid<=1; cmd<=8'h83; seq<=0; page<=0;
                    snapshot<=next_snapshot; next_snapshot<=next_snapshot+1'b1;
                end
            end
            if(status_request) begin status_pending<=1; pending_seq<=status_seq; end
            // An already accepted UART page finishes; unsent old STATUS pages are cancelled.
            if(session_reset) begin
                status_pending<=0;
                if(cmd==8'h82) begin valid<=0; page<=0; end
            end
        end
    end
endmodule
