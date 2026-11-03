// Identical sample-memory interface; compare correlator plus detector only.
module detector_benchmark #(
    parameter integer MODE=0
)(
    input logic clk,rst_n,start,
    input logic [15:0] first_address,
    input logic [23:0] step0,step1,
    input logic signed [15:0] dc,
    input logic signed [3:0] gain,
    input logic signed [15:0] memory_data,
    output wire [15:0] address,
    output wire done,
    output wire decision
);
    wire corr_done;
    wire [63:0] p0,p1;
    wire [159:0] features;
    fsk_correlator corr(
        .clk(clk),.rst_n(rst_n),.start(start),.first_address(first_address),
        .length(13'd500),.step0(step0),.step1(step1),.dc(dc),.gain(gain),
        .feature_enable(MODE!=0),.address(address),.memory_data(memory_data),
        .done(corr_done),.busy(),.power0(p0),.power1(p1),.raw_sum(),
        .features(features),.feature_saturation()
    );
    generate
        if(MODE==3) begin: ai
            ai_mlp core(.clk(clk),.rst_n(rst_n),.start(corr_done),.features(features),
                .done(done),.busy(),.decision(decision),.ai_available(),.model_version());
        end else begin: traditional
            logic [2:0] votes;
            logic [16:0] largest;
            logic [1:0] drop;
            logic [2:0] window_index;
            logic [17:0] sum0,sum1;
            logic decision_reg,done_reg,trim_busy;
            wire [15:0] window_p0=features[window_index*32 +: 16];
            wire [15:0] window_p1=features[window_index*32+16 +: 16];
            always_ff @(posedge clk) begin
                if(!rst_n) begin
                    done_reg<=0; decision_reg<=0; votes<=0; largest<=0; drop<=0;
                    window_index<=0; sum0<=0; sum1<=0; trim_busy<=0;
                end
                else begin
                    if(MODE!=2) done_reg<=corr_done;
                    else done_reg<=0;
                    if(corr_done) begin
                        if(MODE==0) decision_reg<=p1>p0;
                        else if(MODE==1) begin
                            votes<=(features[16 +: 16]>features[0 +: 16])+
                                   (features[48 +: 16]>features[32 +: 16])+
                                   (features[80 +: 16]>features[64 +: 16])+
                                   (features[112 +: 16]>features[96 +: 16]);
                            decision_reg<=(((features[16 +: 16]>features[0 +: 16])+ 
                                (features[48 +: 16]>features[32 +: 16])+ 
                                (features[80 +: 16]>features[64 +: 16])+ 
                                (features[112 +: 16]>features[96 +: 16]))==2) ? p1>p0 :
                                ((features[16 +: 16]>features[0 +: 16])+ 
                                (features[48 +: 16]>features[32 +: 16])+ 
                                (features[80 +: 16]>features[64 +: 16])+ 
                                (features[112 +: 16]>features[96 +: 16]))>2;
                        end else begin
                            votes<=0; largest<=0; drop<=0; window_index<=0;
                            sum0<=0; sum1<=0; trim_busy<=1;
                        end
                    end else if(MODE==2 && trim_busy) begin
                        if(window_index<4) begin
                            if(({1'b0,window_p0}+{1'b0,window_p1})>largest) begin
                                largest<={1'b0,window_p0}+{1'b0,window_p1}; drop<=window_index;
                            end
                            sum0<=sum0+window_p0; sum1<=sum1+window_p1;
                            window_index<=window_index+1'b1;
                        end else begin
                            decision_reg<=(sum1-features[drop*32+16 +: 16])>
                                          (sum0-features[drop*32 +: 16]);
                            done_reg<=1;
                            trim_busy<=0;
                            window_index<=0;
                        end
                    end
                end
            end
            assign done=done_reg;
            assign decision=decision_reg;
        end
    endgenerate
endmodule
