module command_engine(
    input logic clk,rst_n,request_valid,
    input logic [7:0] request_cmd,request_len,request_error,
    input logic [15:0] request_seq,
    input logic [511:0] request_payload,
    output logic execute,
    output logic [7:0] execution_cmd,execution_len,
    output logic [511:0] execution_payload,
    input logic [7:0] execute_error,
    input logic [31:0] config_id,
    output logic status_request,response_valid,session_reset,
    output logic [15:0] status_seq,
    input logic response_ready,
    output logic [7:0] response_cmd,response_len,
    output logic [15:0] response_seq,
    output logic [511:0] response_payload,
    output logic [31:0] overflow_count
);
    import control_pkg::*;
    logic [7:0] cache_valid;
    logic [2:0] write_index,scan_index;
    logic [15:0] cache_seq[0:7];
    logic [7:0] cache_cmd[0:7],cache_len[0:7],cache_reply_cmd[0:7],cache_reply_len[0:7];
    logic [511:0] cache_payload[0:7];
    logic [47:0] cache_reply[0:7];
    logic [15:0] saved_seq;
    logic [7:0] saved_error;
    logic [2:0] state;
    logic found,identical,seq_match;
    logic [15:0] chunk_match;
    logic [7:0] cached_cmd,cached_len,reply_cmd,reply_len,err;
    logic [47:0] cached_reply;
    logic [511:0] reply_payload;
    logic space;
    assign space=!response_valid || response_ready;
    assign execute=state==3 && space && saved_error==0 && !found && execution_cmd!=6;
    always_comb begin
        err=saved_error;
        if(err==0) begin
            if(found && !identical && execution_cmd!=6) err=SEQ_CONFLICT;
            else if(execution_cmd==6 && execution_len!=0) err=BAD_LENGTH;
            else if(execute) err=execute_error;
        end
        reply_payload=0; reply_cmd=8'h80; reply_len=6;
        reply_payload[511:464]={execution_cmd,{7'd0,(execution_cmd!=5)},config_id};
        if(err!=0) begin reply_cmd=8'h81; reply_len=2; reply_payload[511:496]={execution_cmd,err}; end
        else if(execution_cmd==6) begin reply_cmd=8'h84; reply_len=5; reply_payload[511:472]={8'd2,32'h00030003}; end
        else if(found && identical) begin reply_cmd=cached_cmd; reply_len=cached_len; reply_payload[511:464]=cached_reply; end
    end
    always_ff @(posedge clk) begin
        if(!rst_n) begin
            cache_valid<=0; write_index<=0; scan_index<=0; state<=0; found<=0; identical<=0;
            saved_seq<=0; saved_error<=0; execution_cmd<=0; execution_len<=0; execution_payload<=0;
            status_request<=0; status_seq<=0; session_reset<=0; response_valid<=0; response_cmd<=0; response_len<=0;
            response_seq<=0; response_payload<=0; overflow_count<=0;
            chunk_match<=0; seq_match<=0; cached_cmd<=0; cached_len<=0; cached_reply<=0;
        end else begin
            status_request<=0; session_reset<=0;
            if(response_valid && response_ready) response_valid<=0;
            if(request_valid) begin
                if(state==0) begin
                    execution_cmd<=request_cmd; execution_len<=request_len; execution_payload<=request_payload;
                    saved_seq<=request_seq; saved_error<=request_error; scan_index<=0; found<=0; identical<=0; state<=1;
                end else if(overflow_count!=32'hffffffff) overflow_count<=overflow_count+1'b1;
            end
            case(state)
                1: begin
                    seq_match<=cache_valid[scan_index] && cache_seq[scan_index]==saved_seq;
                    for(integer i=0;i<16;i=i+1)
                        chunk_match[i]<=(cache_payload[scan_index][i*32 +:32]==execution_payload[i*32 +:32]);
                    state<=2;
                end
                2: begin
                    if(seq_match) begin
                        found<=1; identical<=(&chunk_match) && cache_cmd[scan_index]==execution_cmd && cache_len[scan_index]==execution_len;
                        cached_cmd<=cache_reply_cmd[scan_index]; cached_len<=cache_reply_len[scan_index]; cached_reply<=cache_reply[scan_index];
                        state<=3;
                    end else if(scan_index==7) state<=3;
                    else begin scan_index<=scan_index+1'b1; state<=1; end
                end
                3: if(space) begin
                    response_valid<=1; response_cmd<=reply_cmd; response_len<=reply_len;
                    response_seq<=saved_seq; response_payload<=reply_payload; state<=0;
                    if(execution_cmd==5 && err==0) begin status_request<=1; status_seq<=saved_seq; end
                    if(execution_cmd==6 && err==0) begin cache_valid<=0; write_index<=0; session_reset<=1; end
                    else if(saved_error==0 && !found) begin
                        cache_valid[write_index]<=1; cache_seq[write_index]<=saved_seq;
                        cache_cmd[write_index]<=execution_cmd; cache_len[write_index]<=execution_len;
                        cache_payload[write_index]<=execution_payload; cache_reply_cmd[write_index]<=reply_cmd;
                        cache_reply_len[write_index]<=reply_len; cache_reply[write_index]<=reply_payload[511:464];
                        write_index<=write_index+1'b1;
                    end
                end
                default: ;
            endcase
        end
    end
endmodule
