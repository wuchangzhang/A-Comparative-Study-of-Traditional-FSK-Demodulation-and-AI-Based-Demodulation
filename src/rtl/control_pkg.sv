package control_pkg;
    localparam [7:0] OK=0, BAD_CRC=1, BAD_LENGTH=2, OUT_OF_RANGE=3,
        UNSUPPORTED_PROFILE=4, BUSY=5, SEQ_CONFLICT=6, UNKNOWN_CMD=7;
    typedef struct packed {
        logic [31:0] hz;
        logic [7:0] wave;
        logic [7:0] amplitude;
        logic signed [15:0] bias;
    } dds_t;
    typedef struct packed {
        logic [7:0] amplitude;
        logic signed [15:0] bias;
        logic signed [15:0] offset_hz;
        logic [7:0] software_noise;
        logic [15:0] noise_scale;
        logic [7:0] physical_noise;
    } fsk_t;
    localparam [63:0] DDS_DEFAULT = {32'd1000,8'd0,8'd255,16'd0};
    localparam [71:0] FSK_DEFAULT = {8'd128,16'd0,16'd0,8'd1,16'd0,8'd0};
    function automatic [15:0] crc_byte(input [15:0] crc, input [7:0] data);
        reg [15:0] c;
        integer i;
        begin
            c = crc ^ {data,8'd0};
            for (i=0;i<8;i=i+1) c = c[15] ? (c<<1)^16'h1021 : c<<1;
            crc_byte=c;
        end
    endfunction
    function automatic [31:0] fcw(input [31:0] hz);
        reg [63:0] numerator;
        begin
            numerator = {hz,32'd0} + 64'd50000;
            fcw = numerator / 100000;
        end
    endfunction
    function automatic bit legal_shape(input [7:0] amp, input signed [15:0] bias);
        reg signed [9:0] min_bias,max_bias;
        begin
            min_bias = (amp==255) ? 0 : -10'sd128 + $signed({1'b0,(({1'b0,amp}+9'd1)>>1)});
            max_bias = (amp==255) ? 0 : 10'sd127-$signed({3'b0,amp[7:1]})+
                       $signed({9'd0,(amp!=0 && (!amp[0] || amp>128))});
            legal_shape = (bias>=min_bias && bias<=max_bias);
        end
    endfunction
endpackage
