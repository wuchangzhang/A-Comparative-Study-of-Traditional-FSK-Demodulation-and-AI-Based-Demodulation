// Single DOUTA, all eight words clocked out; export signed AIN1 only.
// Historical adc_rst_n port name: AD7606 RESET is ACTIVE HIGH.
module ad7606_spi_rx #(
    parameter integer CLK_HZ=100_000_000, SAMPLE_HZ=50_000,
    SCLK_HZ=10_000_000, BUSY_TIMEOUT_CLKS=5_000
)(
    input logic clk,rst_n,adc_busy,adc_dout,
    output logic adc_convst,adc_cs_n,adc_sclk,adc_rst_n,
    output logic signed [15:0] adc_sample_data,
    output logic adc_sample_valid,
    output logic [31:0] sample_index,
    output logic adc_error,adc_clip,
    // Diagnostic tap: current FSM state, live BUSY/DOUT levels, and the reason
    // of the most recent error (latch). Exposed over UART STATUS for on-board
    // debug without a scope. error_reason: 0 none, 1 IDLE saw BUSY high,
    // 2 WAIT_HIGH timeout (BUSY never high), 3 WAIT_LOW timeout (BUSY never low),
    // 4 FINISH overrun. reset_count saturates.
    output logic [3:0] adc_state_code,
    output logic adc_busy_level,adc_dout_level,
    output logic [3:0] adc_error_reason,
    output logic [31:0] adc_reset_count
);
    localparam integer PERIOD=CLK_HZ/SAMPLE_HZ, HALF=CLK_HZ/(2*SCLK_HZ);
    localparam integer PULSE=(CLK_HZ/10_000_000<3) ? 3 : CLK_HZ/10_000_000;
    typedef enum logic [3:0] {RESET,IDLE,CONV_LOW,WAIT_HIGH,WAIT_LOW,
                             READ_LOW,READ_HIGH,FINISH} state_t;
    state_t state;
    logic [3:0] error_reason;
    logic [31:0] reset_count;
    integer cadence,timer,timeout_count;
    logic [6:0] bit_count;
    logic [15:0] ain1;
    (* ASYNC_REG="TRUE" *) logic [1:0] busy_sync,dout_sync;
    always_ff @(posedge clk) begin
        if(!rst_n) begin busy_sync<=0; dout_sync<=0; end
        else begin busy_sync<={busy_sync[0],adc_busy}; dout_sync<={dout_sync[0],adc_dout}; end
    end
    always_ff @(posedge clk) begin
        if(!rst_n) begin
            state<=RESET; cadence<=0; timer<=0; timeout_count<=0;
            bit_count<=0; ain1<=0; adc_convst<=0; adc_cs_n<=1;
            adc_sclk<=1; adc_rst_n<=1; adc_sample_data<=0;
            adc_sample_valid<=0; sample_index<=0; adc_error<=0; adc_clip<=0;
            error_reason<=0; reset_count<=0;
        end else begin
            adc_sample_valid<=0; adc_error<=0; adc_clip<=0;
            if(cadence!=0) cadence<=cadence-1;
            case(state)
                RESET: begin
                    adc_rst_n<=1; adc_convst<=0; adc_cs_n<=1; adc_sclk<=1;
                    if(timer==PULSE-1) begin
                        adc_rst_n<=0; timer<=0; cadence<=PERIOD-1; state<=IDLE;
                    end else begin
                        if(timer==0 && reset_count!=32'hffffffff) reset_count<=reset_count+1'b1;
                        timer<=timer+1;
                    end
                end
                IDLE: if(cadence==0) begin
                    if(busy_sync[1]) begin
                        adc_error<=1; error_reason<=1; state<=RESET; timer<=0;
                    end else begin adc_convst<=0; timer<=PULSE-1; state<=CONV_LOW; end
                end
                CONV_LOW: if(timer==0) begin
                    adc_convst<=1; cadence<=PERIOD-PULSE-1;
                    timeout_count<=0; state<=WAIT_HIGH;
                end else timer<=timer-1;
                WAIT_HIGH: begin
                    if(busy_sync[1]) begin timeout_count<=0; state<=WAIT_LOW; end
                    else if(timeout_count==BUSY_TIMEOUT_CLKS-1) begin
                        adc_error<=1; error_reason<=2; timer<=0; state<=RESET;
                    end else timeout_count<=timeout_count+1;
                end
                WAIT_LOW: begin
                    if(!busy_sync[1]) begin
                        adc_cs_n<=0; timer<=HALF-1; bit_count<=0; ain1<=0; state<=READ_LOW;
                    end else if(timeout_count==BUSY_TIMEOUT_CLKS-1) begin
                        adc_error<=1; error_reason<=3; timer<=0; state<=RESET;
                    end else timeout_count<=timeout_count+1;
                end
                // CPOL=1. CS exposes MSB; each subsequent rising SCLK exposes
                // the next bit. Capture the synchronized PREVIOUS bit at the
                // end of its low half-cycle (100 ns settling at 10 MHz).
                READ_LOW: if(timer==0) begin
                    adc_sclk<=0; timer<=HALF-1; state<=READ_HIGH;
                end else timer<=timer-1;
                READ_HIGH: if(timer==0) begin
                    adc_sclk<=1;
                    if(bit_count<16) ain1<={ain1[14:0],dout_sync[1]};
                    timer<=HALF-1;
                    if(bit_count==127) state<=FINISH;
                    else begin bit_count<=bit_count+1'b1; state<=READ_LOW; end
                end else timer<=timer-1;
                FINISH: if(timer==0) begin
                    adc_cs_n<=1; adc_sample_data<=$signed(ain1);
                    adc_sample_valid<=1; sample_index<=sample_index+1'b1;
                    adc_clip<=($signed(ain1)>=16'sh7a00 || $signed(ain1)<=-16'sh7a00);
                    state<=IDLE;
                    if(cadence==0) begin
                        adc_error<=1; adc_sample_valid<=0; adc_clip<=0;
                        sample_index<=sample_index; error_reason<=4; timer<=0; state<=RESET;
                    end
                end else timer<=timer-1;
                default: begin state<=RESET; timer<=0; end
            endcase
        end
    end
    assign adc_state_code=state;
    assign adc_busy_level=busy_sync[1];
    assign adc_dout_level=dout_sync[1];
    assign adc_error_reason=error_reason;
    assign adc_reset_count=reset_count;
endmodule
