`timescale 1ns/1ps

// Scale a bipolar waveform around the unsigned DAC midpoint (0x80).
// The gain is 0..255, where 255 is full scale and 0 is a flat midpoint.
module amplitude_scale(
    input  wire [7:0] sample_in,
    input  wire [7:0] amplitude,
    output reg  [7:0] sample_out
);

reg signed [8:0]  centered;
reg signed [8:0]  amplitude_ext;
reg signed [17:0] product;
reg signed [10:0] scaled;
reg signed [10:0] result;

always @(*) begin
    centered = $signed({1'b0, sample_in}) - 9'sd128;
    amplitude_ext = $signed({1'b0, amplitude});
    product = centered * amplitude_ext;

    // Use an exact full-scale bypass; otherwise divide by 256 using a shift.
    if (amplitude == 8'hff)
        scaled = centered;
    else
        scaled = product >>> 8;

    result = 11'sd128 + scaled;
    if (result < 0)
        sample_out = 8'h00;
    else if (result > 11'sd255)
        sample_out = 8'hff;
    else
        sample_out = result[7:0];
end

endmodule
