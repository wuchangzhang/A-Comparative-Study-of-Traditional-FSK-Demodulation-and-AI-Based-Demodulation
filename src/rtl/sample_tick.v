`timescale 1ns/1ps

module sample_tick #(
    parameter integer CLK_HZ    = 100_000_000,
    parameter integer SAMPLE_HZ = 100_000
)(
    input  wire clk,
    input  wire rst_n,
    output reg  sample_ce
);

function integer clog2;
    input integer value;
    integer temp;
    begin
        temp = value - 1;
        for (clog2 = 0; temp > 0; clog2 = clog2 + 1)
            temp = temp >> 1;
    end
endfunction

localparam integer DIVISOR = CLK_HZ / SAMPLE_HZ;
localparam integer COUNTER_WIDTH = (DIVISOR <= 1) ? 1 : clog2(DIVISOR);

reg [COUNTER_WIDTH-1:0] counter;

// synthesis translate_off
initial begin
    if ((CLK_HZ <= 0) || (SAMPLE_HZ <= 0) || (CLK_HZ % SAMPLE_HZ != 0)) begin
        $display("ERROR(sample_tick): CLK_HZ must be exactly divisible by SAMPLE_HZ");
        $finish;
    end
end
// synthesis translate_on

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        counter   <= {COUNTER_WIDTH{1'b0}};
        sample_ce <= 1'b0;
    end else if (counter == DIVISOR - 1) begin
        counter   <= {COUNTER_WIDTH{1'b0}};
        sample_ce <= 1'b1;
    end else begin
        counter   <= counter + 1'b1;
        sample_ce <= 1'b0;
    end
end

endmodule
