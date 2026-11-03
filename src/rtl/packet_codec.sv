module packet_rx #(parameter integer TIMEOUT_CLKS=10_000_000)(
    input logic clk,rst_n,
    input logic [7:0] byte_data,
    input logic byte_valid,byte_error,
    output logic packet_valid,
    output logic [7:0] cmd,length,error,
    output logic [15:0] seq,
    output logic [511:0] payload
);
    import control_pkg::*;
    logic [3:0] state;
    logic [6:0] index;
    logic [15:0] crc;
    logic [7:0] crc_high;
    integer timer;
    always_ff @(posedge clk) begin
        if(!rst_n) begin
            state<=0; index<=0; crc<=16'hffff; crc_high<=0; timer<=0;
            packet_valid<=0; cmd<=0; length<=0; error<=0; seq<=0; payload<=0;
        end else begin
            packet_valid<=0;
            if(byte_error || (state!=0 && timer==TIMEOUT_CLKS-1)) begin state<=0; timer<=0; end
            else if(byte_valid) begin
                timer<=0;
                case(state)
                    0: if(byte_data==8'h55) state<=1;
                    1: if(byte_data==8'haa) begin state<=2; crc<=16'hffff; payload<=0; end
                       else if(byte_data!=8'h55) state<=0;
                    2: begin cmd<=byte_data; crc<=crc_byte(crc,byte_data); state<=3; end
                    3: begin length<=byte_data; crc<=crc_byte(crc,byte_data); state<=4; end
                    4: begin seq[15:8]<=byte_data; crc<=crc_byte(crc,byte_data); state<=5; end
                    5: begin
                        seq[7:0]<=byte_data; crc<=crc_byte(crc,byte_data); index<=0;
                        if(length>64) begin error<=BAD_LENGTH; packet_valid<=1; state<=0; end
                        else state<=(length==0) ? 7 : 6;
                    end
                    6: begin
                        payload[511-index*8 -: 8]<=byte_data;
                        crc<=crc_byte(crc,byte_data);
                        if(index==length-1) state<=7; else index<=index+1'b1;
                    end
                    7: begin crc_high<=byte_data; state<=8; end
                    8: begin
                        error<=({crc_high,byte_data}==crc) ? OK : BAD_CRC;
                        packet_valid<=1; state<=0;
                    end
                    default: state<=0;
                endcase
            end else if(state!=0) timer<=timer+1;
        end
    end
endmodule

module packet_tx(
    input logic clk,rst_n,
    input logic packet_valid,
    output logic packet_ready,
    input logic [7:0] cmd,length,
    input logic [15:0] seq,
    input logic [511:0] payload,
    output logic [7:0] byte_data,
    output logic byte_valid,
    input logic byte_ready
);
    import control_pkg::*;
    logic busy;
    logic [7:0] saved_cmd,saved_len;
    logic [15:0] saved_seq,crc;
    logic [511:0] saved_payload;
    logic [6:0] index;
    assign packet_ready=!busy;
    assign byte_valid=busy;
    always_comb begin
        case(index)
            0:byte_data=8'h55;
            1:byte_data=8'haa;
            2:byte_data=saved_cmd;
            3:byte_data=saved_len;
            4:byte_data=saved_seq[15:8];
            5:byte_data=saved_seq[7:0];
            default: begin
                if(index<saved_len+6) byte_data=saved_payload[511-(index-6)*8 -:8];
                else if(index==saved_len+6) byte_data=crc[15:8];
                else byte_data=crc[7:0];
            end
        endcase
    end
    always_ff @(posedge clk) begin
        if(!rst_n) begin busy<=0; saved_cmd<=0; saved_len<=0; saved_seq<=0; saved_payload<=0; index<=0; crc<=16'hffff; end
        else begin
            if(packet_valid && packet_ready) begin
                busy<=1; saved_cmd<=cmd; saved_len<=length; saved_seq<=seq; saved_payload<=payload;
                index<=0; crc<=16'hffff;
            end else if(byte_valid && byte_ready) begin
                if(index>=2 && index<saved_len+6) crc<=crc_byte(crc,byte_data);
                if(index==saved_len+7) busy<=0;
                else index<=index+1'b1;
            end
        end
    end
endmodule
