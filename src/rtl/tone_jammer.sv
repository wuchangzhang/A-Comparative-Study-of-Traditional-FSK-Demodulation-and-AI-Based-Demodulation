// Narrowband tone jammer. Unlike the Gaussian source, a single tone is a
// structured interferer: it defeats the assumption that makes the traditional
// full-window matched filter optimal, which is the regime where the AI branch
// is expected to differ. The tone is free-running at the DAC sample rate and
// is summed into the transmit path only while a frame is active, exactly like
// the Gaussian noise source.
module tone_jammer #(
    parameter [31:0] PHASE_SCALE = 32'd42950   // round(2^32 / 100000), 7.6 ppm error
)(
    input logic clk,rst_n,sample_ce,enable,
    input logic [11:0] frequency_hz,
    input logic [7:0] amplitude,
    output logic signed [15:0] tone
);
    logic [31:0] phase;
    wire [31:0] frequency_word = frequency_hz * PHASE_SCALE;
    wire [7:0] rom_address = phase[31:24];
    wire [11:0] rom_data;
    logic signed [15:0] centred;
    // A wide intermediate keeps the product in context: a 16-bit evaluation
    // would truncate (rom peak 2047 * amplitude 255 exceeds 16 signed bits).
    logic signed [31:0] jam_product;
    rom_sin u_rom(.address(rom_address),.clock(clk),.q(rom_data));
    assign centred = $signed({4'b0,rom_data}) - 16'sd2048;
    always_comb jam_product = centred * $signed({1'b0,amplitude});
    always_ff @(posedge clk) begin
        if(!rst_n) begin
            phase<=0; tone<=0;
        end else begin
            if(sample_ce) phase<=phase+frequency_word;
            tone<=enable ? ((jam_product+32'sd1024)>>>11) : 16'sd0;
        end
    end
endmodule
