`timescale 1ns/1ps

// DAC0832 double-buffered stand-alone write sequence for EGO1.
// At VCC=5 V: tW/tDS >= 900 ns, tDH >= 50 ns and tCS >= 1100 ns.
module dac0832_driver #(
    parameter integer CONTROL_SETUP_CYCLES = 120,
    parameter integer WRITE_CYCLES = 100,
    parameter integer HOLD_CYCLES = 10,
    parameter integer XFER_CYCLES = 100
) (
    input wire clk, input wire rst_n, input wire sample_valid,
    input wire [7:0] sample_data,
    output reg busy, output reg done, output reg [7:0] dac_data,
    output wire dac_ile, output reg dac_cs_n, output reg dac_wr1_n,
    output reg dac_wr2_n, output reg dac_xfer_n
);
    localparam integer MAX_CYCLES =
        (CONTROL_SETUP_CYCLES > WRITE_CYCLES) ?
        ((CONTROL_SETUP_CYCLES > HOLD_CYCLES) ?
         ((CONTROL_SETUP_CYCLES > XFER_CYCLES) ? CONTROL_SETUP_CYCLES : XFER_CYCLES) :
         ((HOLD_CYCLES > XFER_CYCLES) ? HOLD_CYCLES : XFER_CYCLES)) :
        ((WRITE_CYCLES > HOLD_CYCLES) ?
         ((WRITE_CYCLES > XFER_CYCLES) ? WRITE_CYCLES : XFER_CYCLES) :
         ((HOLD_CYCLES > XFER_CYCLES) ? HOLD_CYCLES : XFER_CYCLES));
    localparam integer COUNT_WIDTH = (MAX_CYCLES < 2) ? 1 : $clog2(MAX_CYCLES + 1);
    localparam [2:0] IDLE=3'd0, PREWRITE=3'd1, WRITE=3'd2,
                     HOLD=3'd3, XFER=3'd4;
    reg [2:0] state;
    reg [COUNT_WIDTH-1:0] count;

    // EGO1 schematic ties ILE(BYTE2) directly to +5 V.
    assign dac_ile = 1'b1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE; count <= 0; busy <= 1'b0; done <= 1'b0;
            dac_data <= 8'h00; dac_cs_n <= 1'b1; dac_wr1_n <= 1'b1;
            dac_wr2_n <= 1'b1; dac_xfer_n <= 1'b1;
        end else begin
            done <= 1'b0;
            case (state)
                IDLE: begin
                    busy <= 1'b0; dac_cs_n <= 1'b1; dac_wr1_n <= 1'b1;
                    dac_wr2_n <= 1'b1; dac_xfer_n <= 1'b1;
                    if (sample_valid) begin
                        dac_data <= sample_data; busy <= 1'b1;
                        dac_cs_n <= 1'b0; dac_xfer_n <= 1'b0;
                        count <= CONTROL_SETUP_CYCLES - 1; state <= PREWRITE;
                    end
                end
                PREWRITE: begin
                    busy <= 1'b1; dac_cs_n <= 1'b0; dac_wr1_n <= 1'b1;
                    dac_wr2_n <= 1'b1; dac_xfer_n <= 1'b0;
                    if (count == 0) begin
                        dac_wr1_n <= 1'b0; count <= WRITE_CYCLES - 1;
                        state <= WRITE;
                    end else count <= count - 1'b1;
                end
                WRITE: begin
                    busy <= 1'b1; dac_cs_n <= 1'b0; dac_wr1_n <= 1'b0;
                    dac_wr2_n <= 1'b1; dac_xfer_n <= 1'b0;
                    if (count == 0) begin
                        dac_cs_n <= 1'b1; dac_wr1_n <= 1'b1;
                        count <= HOLD_CYCLES - 1; state <= HOLD;
                    end else count <= count - 1'b1;
                end
                HOLD: begin
                    busy <= 1'b1; dac_cs_n <= 1'b1; dac_wr1_n <= 1'b1;
                    dac_wr2_n <= 1'b1; dac_xfer_n <= 1'b0;
                    if (count == 0) begin
                        dac_wr2_n <= 1'b0; count <= XFER_CYCLES - 1;
                        state <= XFER;
                    end else count <= count - 1'b1;
                end
                XFER: begin
                    busy <= 1'b1; dac_cs_n <= 1'b1; dac_wr1_n <= 1'b1;
                    dac_wr2_n <= 1'b0; dac_xfer_n <= 1'b0;
                    if (count == 0) begin
                        dac_wr2_n <= 1'b1; dac_xfer_n <= 1'b1;
                        busy <= 1'b0; done <= 1'b1; state <= IDLE;
                    end else count <= count - 1'b1;
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
