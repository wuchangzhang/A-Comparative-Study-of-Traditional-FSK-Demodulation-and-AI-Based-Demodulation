// Sequential dual-frequency quadrature MAC with optional AI features.
// The traditional 500-point powers and arithmetic are unchanged.
//
// Feature layout (10 x int16), shared with ai/reference.py:
//   [  0.. 15] sub-window 0, branch 0     (125-point power >> SUB_SHIFT)
//   [ 16.. 31] sub-window 0, branch 1
//   ...                                    four windows, branch 0 then 1
//   [112..127] sub-window 3, branch 1
//   [128..143] full coherent power, branch 0 (500-point power >> FULL_SHIFT)
//   [144..159] full coherent power, branch 1
// The full powers are the traditional detector's own decision statistic, so the
// net can reproduce sign(p1-p0) exactly and spend the sub-windows on rejecting
// interference the coherent window integrates in. Measured over the jammer
// matrix this cuts AI bit errors from 243 to 50 against 58 for the traditional
// branch alone (build/probe_dim.py).
module fsk_correlator #(
    parameter integer SUB_FEATURE_SHIFT=14,
    parameter integer FULL_FEATURE_SHIFT=18
)(
    input logic clk,rst_n,start,
    input logic [15:0] first_address,
    input logic [12:0] length,
    input logic [23:0] step0,step1,
    input logic signed [15:0] dc,
    input logic signed [3:0] gain,
    input logic feature_enable,
    output logic [15:0] address,
    input logic signed [15:0] memory_data,
    output logic done,busy,
    output logic [63:0] power0,power1,
    output logic signed [31:0] raw_sum,
    output logic [159:0] features,
    output logic feature_saturation
);
    logic signed [7:0] sine[0:255];
    initial $readmemh("rx_sine.mem",sine);
    typedef enum logic [3:0] {IDLE,FETCH,READ_DATA,CENTER,GAIN_SHIFT,SATURATE,
                             MULT,ACC,SUB_SQUARE,SUB_SUM,SQUARE,SUM,DONE} state_t;
    state_t state;
    logic [12:0] remaining;
    logic [23:0] phase0,phase1;
    logic signed [11:0] x;
    logic signed [19:0] m0c,m0s,m1c,m1s;
    logic signed [31:0] c0,s0,c1,s1,sc0,ss0,sc1,ss1;
    logic signed [23:0] q0c,q0s,q1c,q1s;
    logic [47:0] sq0c,sq0s,sq1c,sq1s;
    logic signed [15:0] input_sample;
    logic signed [19:0] centered,scaled;
    logic feature_mode;
    logic [1:0] feature_window;
    wire feature_boundary=feature_mode && (remaining==13'd376 || remaining==13'd251 ||
                                           remaining==13'd126 || remaining==13'd1);
    function automatic [15:0] feature_scale(input [63:0] value,input integer shift);
        logic [63:0] shifted;
        begin
            shifted=value>>shift;
            feature_scale=(shifted>64'd32767) ? 16'h7fff : shifted[15:0];
        end
    endfunction
    assign busy=(state!=IDLE);
    always_ff @(posedge clk) begin
        if(!rst_n) begin
            state<=IDLE; address<=0; remaining<=0; phase0<=0; phase1<=0;
            x<=0; m0c<=0; m0s<=0; m1c<=0; m1s<=0;
            c0<=0; s0<=0; c1<=0; s1<=0; sc0<=0; ss0<=0; sc1<=0; ss1<=0; done<=0;
            power0<=0; power1<=0; raw_sum<=0; features<=0; feature_saturation<=0;
            q0c<=0; q0s<=0; q1c<=0; q1s<=0;
            sq0c<=0; sq0s<=0; sq1c<=0; sq1s<=0;
            input_sample<=0; centered<=0; scaled<=0; feature_mode<=0; feature_window<=0;
        end else begin
            done<=0;
            case(state)
                IDLE: if(start) begin
                    address<=first_address; remaining<=length;
                    phase0<=0; phase1<=0; c0<=0; s0<=0; c1<=0; s1<=0;
                    sc0<=0; ss0<=0; sc1<=0; ss1<=0; feature_window<=0;
                    features<=0; feature_saturation<=0; feature_mode<=feature_enable;
                    raw_sum<=0; state<=FETCH;
                end
                FETCH: state<=READ_DATA;
                READ_DATA: begin input_sample<=memory_data; state<=CENTER; end
                CENTER: begin
                    centered<=$signed({{4{input_sample[15]}},input_sample})-$signed(dc);
                    raw_sum<=raw_sum+input_sample; state<=GAIN_SHIFT;
                end
                GAIN_SHIFT: begin
                    if(gain>=0) scaled<=centered<<<gain;
                    else scaled<=centered>>>(-gain);
                    state<=SATURATE;
                end
                SATURATE: begin
                    if(scaled>32767) x<=12'sd2047;
                    else if(scaled< -32768) x<=-12'sd2048;
                    else x<=scaled>>>4;
                    state<=MULT;
                end
                MULT: begin
                    m0c<=x*sine[(phase0[23:16]+8'd64)&8'hff]; m0s<=x*sine[phase0[23:16]];
                    m1c<=x*sine[(phase1[23:16]+8'd64)&8'hff]; m1s<=x*sine[phase1[23:16]];
                    state<=ACC;
                end
                ACC: begin
                    c0<=c0+m0c; s0<=s0+m0s; c1<=c1+m1c; s1<=s1+m1s;
                    phase0<=phase0+step0; phase1<=phase1+step1;
                    if(feature_boundary) begin
                        q0c<=(sc0+m0c)>>>8; q0s<=(ss0+m0s)>>>8;
                        q1c<=(sc1+m1c)>>>8; q1s<=(ss1+m1s)>>>8;
                        sc0<=0; ss0<=0; sc1<=0; ss1<=0;
                        if(remaining==1) begin
                            // Preserve the independent full-window traditional sums.
                            q0c<=(sc0+m0c)>>>8; q0s<=(ss0+m0s)>>>8;
                            q1c<=(sc1+m1c)>>>8; q1s<=(ss1+m1s)>>>8;
                        end
                        state<=SUB_SQUARE;
                    end else begin
                        if(feature_mode) begin
                            sc0<=sc0+m0c; ss0<=ss0+m0s; sc1<=sc1+m1c; ss1<=ss1+m1s;
                        end
                        if(remaining==1) begin
                            q0c<=(c0+m0c)>>>8; q0s<=(s0+m0s)>>>8;
                            q1c<=(c1+m1c)>>>8; q1s<=(s1+m1s)>>>8; state<=SQUARE;
                        end else begin
                            remaining<=remaining-1'b1; address<=address+1'b1; state<=FETCH;
                        end
                    end
                end
                SUB_SQUARE: begin
                    sq0c<=q0c*q0c; sq0s<=q0s*q0s;
                    sq1c<=q1c*q1c; sq1s<=q1s*q1s; state<=SUB_SUM;
                end
                SUB_SUM: begin
                    features[feature_window*32 +: 16]<=feature_scale({16'd0,sq0c}+{16'd0,sq0s},SUB_FEATURE_SHIFT);
                    features[feature_window*32+16 +: 16]<=feature_scale({16'd0,sq1c}+{16'd0,sq1s},SUB_FEATURE_SHIFT);
                    if(({16'd0,sq0c}+{16'd0,sq0s})>64'd131068 ||
                       ({16'd0,sq1c}+{16'd0,sq1s})>64'd131068) feature_saturation<=1;
                    if(feature_window==3) begin
                        // Reload full-window sums for the traditional result.
                        q0c<=(c0)>>>8; q0s<=(s0)>>>8; q1c<=(c1)>>>8; q1s<=(s1)>>>8;
                        state<=SQUARE;
                    end else begin
                        feature_window<=feature_window+1'b1;
                        remaining<=remaining-1'b1; address<=address+1'b1; state<=FETCH;
                    end
                end
                SQUARE: begin
                    sq0c<=q0c*q0c; sq0s<=q0s*q0s;
                    sq1c<=q1c*q1c; sq1s<=q1s*q1s; state<=SUM;
                end
                SUM: begin
                    power0<={16'd0,sq0c}+{16'd0,sq0s};
                    power1<={16'd0,sq1c}+{16'd0,sq1s};
                    if(feature_mode) begin
                        features[128 +: 16]<=feature_scale({16'd0,sq0c}+{16'd0,sq0s},FULL_FEATURE_SHIFT);
                        features[144 +: 16]<=feature_scale({16'd0,sq1c}+{16'd0,sq1s},FULL_FEATURE_SHIFT);
                    end
                    state<=DONE;
                end
                DONE: begin done<=1; state<=IDLE; end
                default: state<=IDLE;
            endcase
        end
    end
endmodule
