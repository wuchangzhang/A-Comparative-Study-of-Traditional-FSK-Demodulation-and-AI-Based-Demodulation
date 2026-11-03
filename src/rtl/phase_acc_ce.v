`timescale 1ns/1ps

module phase_acc_ce #(parameter SYNC_RESET=0)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        sample_ce,
    input  wire [31:0] freq_word,
    output reg  [31:0] phase,
    output wire [7:0]  rom_addr
);

generate
if (SYNC_RESET) begin: synchronous_reset
    always @(posedge clk) begin
        if (!rst_n) phase <= 32'd0;
        else if (sample_ce) phase <= phase + freq_word;
    end
end else begin: baseline_reset
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) phase <= 32'd0;
        else if (sample_ce) phase <= phase + freq_word;
    end
end
endgenerate

assign rom_addr = phase[31:24];

endmodule
