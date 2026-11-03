// 10-16-8-2 int8/int16/int32 sequential MLP. 330 words, one MAC per cycle.
//
// ROM map (word indices):
//   0..159   layer 1 weights, 16 outputs x 10 inputs, row-major
//   160..175 layer 1 biases
//   176..303 layer 2 weights, 8 outputs x 16 inputs
//   304..311 layer 2 biases
//   312..327 layer 3 weights, 2 outputs x 8 inputs
//   328..329 layer 3 biases
//
// Input layout is defined in rtl/fsk_correlator.sv: eight 125-point sub-window
// powers followed by the two coherent 500-point powers.
module ai_mlp #(
    parameter [31:0] MODEL_VERSION=32'h00070001,
    parameter integer SHIFT1=4,
    parameter integer SHIFT2=5
)(
    input logic clk,rst_n,start,
    input logic [159:0] features,
    output logic done,busy,decision,
    output logic ai_available,
    output logic [31:0] model_version
);
    logic signed [31:0] model_rom[0:329];
    initial $readmemh("ai_mlp.mem",model_rom);
    // MAC is split across two cycles: the first cycle computes the product from
    // the ROM lookup, the second adds it into the accumulator. This cuts the
    // critical path (ROM -> multiplier -> adder) in half without changing any
    // arithmetic result. There are a million system clocks per bit, so the extra
    // latency is irrelevant.
    typedef enum logic [2:0] {IDLE,MAC,MAC_WAIT,ACT,DONE} state_t;
    state_t state;
    logic [1:0] layer;
    logic [4:0] input_index,output_index;
    logic signed [31:0] accumulator,logit0;
    logic [159:0] input_features;
    logic signed [15:0] activations[0:15];
    logic signed [15:0] activations2[0:7];
    logic [8:0] weight_address;
    logic [8:0] bias_address;
    logic [4:0] last_input,last_output;
    logic signed [15:0] mac_input;
    logic signed [47:0] mac_product_reg;
    wire signed [31:0] mac_weight=model_rom[weight_address];
    wire signed [47:0] mac_product=mac_input*mac_weight;
    wire signed [48:0] mac_sum={{17{accumulator[31]}},accumulator}+mac_product_reg;
    function automatic signed [15:0] activate(input signed [48:0] value,input integer shift);
        logic signed [48:0] shifted;
        begin
            shifted=value>>>shift;
            if(shifted<0) activate=0;
            else if(shifted>32767) activate=16'sh7fff;
            else activate=shifted[15:0];
        end
    endfunction
    always_comb begin
        last_input=(layer==0) ? 5'd9 : ((layer==1) ? 5'd15 : 5'd7);
        last_output=(layer==0) ? 5'd15 : ((layer==1) ? 5'd7 : 5'd1);
        weight_address=0;
        bias_address=0;
        case(layer)
            0: begin weight_address=output_index*10+input_index; bias_address=160+output_index; end
            1: begin weight_address=176+output_index*16+input_index; bias_address=304+output_index; end
            default: begin weight_address=312+output_index*8+input_index; bias_address=328+output_index; end
        endcase
        mac_input=(layer==0) ? input_features[input_index*16 +: 16] :
                  (layer==1) ? activations[input_index] : activations2[input_index];
    end
    assign busy=(state!=IDLE);
    assign ai_available=1'b1;
    assign model_version=MODEL_VERSION;
    always_ff @(posedge clk) begin
        if(!rst_n) begin
            state<=IDLE; layer<=0; input_index<=0; output_index<=0;
            accumulator<=0; logit0<=0; input_features<=0; done<=0; decision<=0;
            mac_product_reg<=0;
        end else begin
            done<=0;
            case(state)
                IDLE: if(start) begin
                    input_features<=features; layer<=0; input_index<=0; output_index<=0;
                    accumulator<=model_rom[160]; mac_product_reg<=0; state<=MAC;
                end
                MAC: begin
                    // Latch the product computed this cycle; accumulate next cycle.
                    mac_product_reg<=mac_product;
                    state<=MAC_WAIT;
                end
                MAC_WAIT: begin
                    accumulator<=mac_sum[31:0];
                    if(input_index==last_input) begin
                        state<=ACT;
                    end else begin
                        input_index<=input_index+1'b1;
                        state<=MAC;
                    end
                end
                ACT: begin
                    if(layer==0) activations[output_index]<=activate(accumulator,SHIFT1);
                    else if(layer==1) activations2[output_index]<=activate(accumulator,SHIFT2);
                    else if(output_index==0) logit0<=accumulator;
                    else decision<=accumulator>logit0;
                    input_index<=0;
                    if(output_index==last_output) begin
                        output_index<=0;
                        if(layer==2) state<=DONE;
                        else begin
                            layer<=layer+1'b1;
                            accumulator<=(layer==0) ? model_rom[304] : model_rom[328];
                            state<=MAC;
                        end
                    end else begin
                        output_index<=output_index+1'b1;
                        case(layer)
                            0: accumulator<=model_rom[160+output_index+1'b1];
                            1: accumulator<=model_rom[304+output_index+1'b1];
                            default: accumulator<=model_rom[328+output_index+1'b1];
                        endcase
                        state<=MAC;
                    end
                end
                DONE: begin done<=1; state<=IDLE; end
                default: state<=IDLE;
            endcase
        end
    end
endmodule
