module xadc_knob(
    input wire clk,rst_n,vauxp1,vauxn1,
    output reg [11:0] value,
    output reg valid
);
    wire [15:0] result;
    wire eoc,drdy;
    // SEQ=0010: continuous channel sequence, unipolar VAUX1, ADCCLK=25 MHz.
    XADC #(.INIT_40(16'h0000),.INIT_41(16'h2000),.INIT_42(16'h0400),
           .INIT_48(16'h0000),.INIT_49(16'h0002)) u_xadc(
        .DCLK(clk),.RESET(!rst_n),.DADDR(7'h11),.DEN(eoc),.DWE(1'b0),.DI(16'd0),
        .DO(result),.DRDY(drdy),.EOC(eoc),.EOS(),.BUSY(),.CHANNEL(),.ALM(),.OT(),
        .CONVST(1'b0),.CONVSTCLK(1'b0),.VP(1'b0),.VN(1'b0),
        .VAUXP({14'd0,vauxp1,1'b0}),.VAUXN({14'd0,vauxn1,1'b0}),
        .JTAGBUSY(),.JTAGLOCKED(),.JTAGMODIFIED(),.MUXADDR());
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin value<=0; valid<=0; end
        else begin valid<=drdy; if(drdy) value<=result[15:4]; end
    end
endmodule
