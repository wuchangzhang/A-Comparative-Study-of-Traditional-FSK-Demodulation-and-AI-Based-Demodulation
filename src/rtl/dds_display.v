`timescale 1ns/1ps
module dds_display #(
    parameter integer SCAN_DIV = 100_000
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [15:0] frequency_hz,
    input  wire [1:0] wave_sel,
    input  wire [1:0] step_sel,
    output reg  [7:0] seg_data_0,
    output reg  [7:0] seg_data_1,
    output reg  [7:0] seg_cs
);
    reg [16:0] scan_count;
    reg [2:0] digit;
    reg [3:0] value;
    reg [15:0] bcd_work, binary_work, bcd_ready;
    reg [7:0] output_code;
    reg [7:0] output_cs;
    reg [4:0] bcd_steps;
    reg [15:0] adjusted;
    integer n;
    always @* begin
        adjusted=bcd_work;
        for (n=0;n<4;n=n+1)
            if (bcd_work[n*4 +: 4]>=5) adjusted[n*4 +: 4]=bcd_work[n*4 +: 4]+4'd3;
    end

    function [7:0] seven_seg;
        input [3:0] n;
        begin
            case (n)
                4'd0: seven_seg = 8'b00111111;
                4'd1: seven_seg = 8'b00000110;
                4'd2: seven_seg = 8'b01011011;
                4'd3: seven_seg = 8'b01001111;
                4'd4: seven_seg = 8'b01100110;
                4'd5: seven_seg = 8'b01101101;
                4'd6: seven_seg = 8'b01111101;
                4'd7: seven_seg = 8'b00000111;
                4'd8: seven_seg = 8'b01111111;
                4'd9: seven_seg = 8'b01101111;
                4'hA: seven_seg = 8'b01110111;
                4'hB: seven_seg = 8'b01111100;
                4'hC: seven_seg = 8'b00111001;
                4'hD: seven_seg = 8'b01011110;
                4'hE: seven_seg = 8'b01111001;
                4'hF: seven_seg = 8'b01110001;
                default: seven_seg = 8'b00000000;
            endcase
        end
    endfunction

    always @* begin
        case (digit)
            3'd0: value = bcd_ready[3:0];
            3'd1: value = bcd_ready[7:4];
            3'd2: value = bcd_ready[11:8];
            3'd3: value = bcd_ready[15:12];
            3'd4: value = {2'b00, wave_sel};
            3'd5: value = {2'b00, step_sel};
            default: value = 4'hF;
        endcase
        // Both four-digit banks share the scan timing. Driving both segment
        // buses with the active code avoids depending on a board-specific
        // bank-to-digit interpretation; only the selected common pin lights.
        output_code = 8'h00;
        output_cs = 8'h00;
        output_cs[digit] = 1'b1;
        if (digit < 6) begin
            output_code = seven_seg(value);
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            scan_count <= 0; digit <= 0;
        end else if (scan_count == SCAN_DIV - 1) begin
            scan_count <= 0;
            digit <= (digit == 3'd7) ? 0 : digit + 1'b1;
        end else begin
            scan_count <= scan_count + 1'b1;
        end
    end

    always @(posedge clk) begin
        if(!rst_n) begin
            bcd_work<=0; binary_work<=0; bcd_ready<=0; bcd_steps<=0;
        end else if(bcd_steps==0) begin
            binary_work<=frequency_hz; bcd_work<=0; bcd_steps<=1;
        end else begin
            bcd_work<={adjusted[14:0],binary_work[15]};
            binary_work<={binary_work[14:0],1'b0};
            if(bcd_steps==16) begin
                bcd_ready<={adjusted[14:0],binary_work[15]}; bcd_steps<=0;
            end else bcd_steps<=bcd_steps+1'b1;
        end
    end
    always @(posedge clk) begin
        if(!rst_n) begin seg_data_0<=0; seg_data_1<=0; seg_cs<=0; end
        else begin seg_data_0<=output_code; seg_data_1<=output_code; seg_cs<=output_cs; end
    end
endmodule
