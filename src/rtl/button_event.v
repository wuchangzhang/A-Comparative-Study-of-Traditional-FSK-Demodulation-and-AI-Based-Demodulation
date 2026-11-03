`timescale 1ns/1ps

module button_event #(
    parameter integer DEBOUNCE_CLKS    = 2_000_000,
    parameter integer ENABLE_LONG_PRESS = 0,
    parameter integer LONG_PRESS_CLKS  = 100_000_000,
    parameter integer REPEAT_CLKS      = 10_000_000
)(
    input  wire clk,
    input  wire rst_n,
    input  wire button_in,
    output reg  button_state,
    output reg  press_pulse,
    output reg  release_pulse,
    output reg  repeat_pulse,
    output wire event_pulse
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

localparam integer DEBOUNCE_WIDTH = (DEBOUNCE_CLKS <= 1) ? 1 : clog2(DEBOUNCE_CLKS);
localparam integer LONG_WIDTH     = (LONG_PRESS_CLKS <= 1) ? 1 : clog2(LONG_PRESS_CLKS);
localparam integer REPEAT_WIDTH   = (REPEAT_CLKS <= 1) ? 1 : clog2(REPEAT_CLKS);

(* ASYNC_REG = "TRUE" *) reg sync_meta;
(* ASYNC_REG = "TRUE" *) reg sync_button;
reg [DEBOUNCE_WIDTH-1:0] debounce_count;
reg [LONG_WIDTH-1:0] hold_count;
reg [REPEAT_WIDTH-1:0] repeat_count;
reg long_active;

assign event_pulse = press_pulse |
                     ((ENABLE_LONG_PRESS != 0) ? repeat_pulse : 1'b0);

// synthesis translate_off
initial begin
    if ((DEBOUNCE_CLKS <= 0) || (LONG_PRESS_CLKS <= 0) || (REPEAT_CLKS <= 0)) begin
        $display("ERROR(button_event): timing parameters must be positive");
        $finish;
    end
end
// synthesis translate_on

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        sync_meta   <= 1'b0;
        sync_button <= 1'b0;
    end else begin
        sync_meta   <= button_in;
        sync_button <= sync_meta;
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        button_state  <= 1'b0;
        debounce_count <= {DEBOUNCE_WIDTH{1'b0}};
        press_pulse   <= 1'b0;
        release_pulse <= 1'b0;
    end else begin
        press_pulse   <= 1'b0;
        release_pulse <= 1'b0;

        if (sync_button == button_state) begin
            debounce_count <= {DEBOUNCE_WIDTH{1'b0}};
        end else if ((DEBOUNCE_CLKS <= 1) || (debounce_count == DEBOUNCE_CLKS - 1)) begin
            button_state  <= sync_button;
            debounce_count <= {DEBOUNCE_WIDTH{1'b0}};
            if (sync_button)
                press_pulse <= 1'b1;
            else
                release_pulse <= 1'b1;
        end else begin
            debounce_count <= debounce_count + 1'b1;
        end
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        hold_count   <= {LONG_WIDTH{1'b0}};
        repeat_count <= {REPEAT_WIDTH{1'b0}};
        long_active  <= 1'b0;
        repeat_pulse <= 1'b0;
    end else begin
        repeat_pulse <= 1'b0;

        if ((ENABLE_LONG_PRESS == 0) || !button_state) begin
            hold_count   <= {LONG_WIDTH{1'b0}};
            repeat_count <= {REPEAT_WIDTH{1'b0}};
            long_active  <= 1'b0;
        end else if (!long_active) begin
            if ((LONG_PRESS_CLKS <= 1) || (hold_count == LONG_PRESS_CLKS - 1)) begin
                hold_count   <= {LONG_WIDTH{1'b0}};
                repeat_count <= {REPEAT_WIDTH{1'b0}};
                long_active  <= 1'b1;
                repeat_pulse <= 1'b1;
            end else begin
                hold_count <= hold_count + 1'b1;
            end
        end else if ((REPEAT_CLKS <= 1) || (repeat_count == REPEAT_CLKS - 1)) begin
            repeat_count <= {REPEAT_WIDTH{1'b0}};
            repeat_pulse <= 1'b1;
        end else begin
            repeat_count <= repeat_count + 1'b1;
        end
    end
end

endmodule
