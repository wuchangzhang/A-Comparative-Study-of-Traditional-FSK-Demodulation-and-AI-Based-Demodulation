module uart_bytes #(parameter integer CLK_HZ=100_000_000, BAUD=115200)(
    input logic clk,rst_n,rx,
    output logic tx,
    output logic [7:0] rx_data,
    output logic rx_valid,rx_error,
    input logic [7:0] tx_data,
    input logic tx_valid,
    output logic tx_ready
);
    localparam integer DIV=(CLK_HZ+BAUD/2)/BAUD;
    (* ASYNC_REG="TRUE" *) logic rx_meta,rx_sync;
    logic [9:0] tx_shift;
    logic [7:0] rx_shift;
    integer tx_timer,rx_timer;
    logic [3:0] tx_bits,rx_bits;
    logic [1:0] rx_state;
    assign tx=tx_bits==0 ? 1'b1 : tx_shift[0];
    assign tx_ready=(tx_bits==0);
    always_ff @(posedge clk) begin
        if(!rst_n) begin
            rx_meta<=1; rx_sync<=1; rx_state<=0; rx_timer<=0; rx_bits<=0;
            rx_shift<=0; rx_data<=0; rx_valid<=0; rx_error<=0;
            tx_shift<=10'h3ff; tx_timer<=0; tx_bits<=0;
        end else begin
            rx_meta<=rx; rx_sync<=rx_meta; rx_valid<=0; rx_error<=0;
            if(tx_ready) begin
                if(tx_valid) begin tx_shift<={1'b1,tx_data,1'b0}; tx_timer<=DIV-1; tx_bits<=10; end
            end else if(tx_timer==0) begin
                tx_shift<={1'b1,tx_shift[9:1]}; tx_timer<=DIV-1; tx_bits<=tx_bits-1'b1;
            end else tx_timer<=tx_timer-1;
            case(rx_state)
                0: if(!rx_sync) begin rx_timer<=DIV/2-1; rx_state<=1; end
                1: if(rx_timer!=0) rx_timer<=rx_timer-1;
                   else if(rx_sync) rx_state<=0;
                   else begin rx_timer<=DIV-1; rx_bits<=0; rx_state<=2; end
                2: if(rx_timer!=0) rx_timer<=rx_timer-1;
                   else begin
                       rx_shift[rx_bits]<=rx_sync; rx_timer<=DIV-1;
                       if(rx_bits==7) rx_state<=3; else rx_bits<=rx_bits+1'b1;
                   end
                3: if(rx_timer!=0) rx_timer<=rx_timer-1;
                   else begin
                       rx_state<=0;
                       if(rx_sync) begin rx_data<=rx_shift; rx_valid<=1; end
                       else rx_error<=1;
                   end
            endcase
        end
    end
endmodule
