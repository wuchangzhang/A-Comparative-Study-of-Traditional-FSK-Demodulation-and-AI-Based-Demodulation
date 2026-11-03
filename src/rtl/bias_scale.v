`timescale 1ns/1ps
module bias_scale(
    input wire [7:0] sample_in, input wire signed [8:0] bias_offset,
    output reg [7:0] sample_out
);
integer signed value;
always @(*) begin
    value = $signed({1'b0, sample_in}) + bias_offset;
    if (value < 0) sample_out = 8'h00;
    else if (value > 255) sample_out = 8'hff;
    else sample_out = value[7:0];
end
endmodule
