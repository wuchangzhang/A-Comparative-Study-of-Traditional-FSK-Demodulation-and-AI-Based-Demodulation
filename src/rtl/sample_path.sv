module sample_path(
    input logic clk,rst_n,sample_ce,fsk_active,frame_active,fsk_bit,
    input control_pkg::dds_t dds_cfg,
    input control_pkg::fsk_t fsk_cfg,
    input logic jam_enable, jam_burst,
    input logic [7:0] jam_amplitude,
    input logic [11:0] jam_hz,
    output logic [7:0] sample_data,
    output logic sample_valid,clipped,
    output logic [31:0] phase_debug
);
    import control_pkg::*;
    logic [31:0] word_reg;
    logic [31:0] fcw_rom [0:2100];
    logic [11:0] desired_hz;
    logic [7:0] addr;
    logic [11:0] sine_data,square_data,triangle_data,sawtooth_data;
    logic [1:0] wave_latched;
    logic [7:0] amp_latched;
    logic signed [15:0] bias_latched;
    logic idle_latched,noise_latched,jam_latched;
    logic [15:0] noise_scale_latched;
    logic [7:0] jam_amp_latched;
    logic [11:0] jam_hz_latched;
    logic signed [15:0] jam_code;
    tone_jammer u_jammer(.clk(clk),.rst_n(rst_n),.sample_ce(sample_ce),.enable(jam_latched),
        .frequency_hz(jam_hz_latched),.amplitude(jam_amp_latched),.tone(jam_code));
    logic [3:0] valid_pipe;
    logic [31:0] rng;
    logic [9:0] burst_count;
    logic [1:0] burst_slot;
    logic burst_fire;
    wire [1:0] selected_slot=(burst_count==0) ? rng[3:2] : burst_slot;
    wire selected_fire=(burst_count==0) ? rng[1] : burst_fire;
    wire burst_gate=selected_fire && (
        (selected_slot==0 && burst_count<250) ||
        (selected_slot==1 && burst_count>=250 && burst_count<500) ||
        (selected_slot==2 && burst_count>=500 && burst_count<750) ||
        (selected_slot==3 && burst_count>=750));
    logic signed [15:0] gaussian [0:255];
    logic signed [15:0] gaussian_latched;
    logic signed [35:0] noise_product;
    integer signed centered,scaled,scaled_reg,noise_reg,base_reg,total_reg;
    logic [7:0] raw_code;
    initial $readmemh("gaussian_q8.mem",gaussian);
    initial $readmemh("fcw_100ksps.mem",fcw_rom);
    always_comb desired_hz=fsk_active ? (fsk_bit ? 12'd2000 : 12'd1000)+$signed(fsk_cfg.offset_hz) : dds_cfg.hz[11:0];
    // xorshift32 is independent of payload PRBS; one draw per DAC sample.
    function automatic [31:0] random_next(input [31:0] x);
        reg [31:0] t;
        begin t=x^(x<<13); t=t^(t>>17); random_next=t^(t<<5); end
    endfunction
    phase_acc_ce #(.SYNC_RESET(1)) u_phase(.clk(clk),.rst_n(rst_n),.sample_ce(sample_ce),
        .freq_word(word_reg),.phase(phase_debug),.rom_addr(addr));
    rom_sin u_sine(.clock(clk),.address(addr),.q(sine_data));
    rom_square u_square(.clock(clk),.address(addr),.q(square_data));
    rom_triangle u_triangle(.clock(clk),.address(addr),.q(triangle_data));
    rom_sawtooth u_sawtooth(.clock(clk),.address(addr),.q(sawtooth_data));
    always_comb begin
        case(wave_latched)
            1:raw_code=square_data[11:4];
            2:raw_code=triangle_data[11:4];
            3:raw_code=sawtooth_data[11:4];
            default:raw_code=sine_data[11:4];
        endcase
        centered=$signed({1'b0,raw_code})-128;
        scaled=(amp_latched==255) ? centered : (centered*$signed({1'b0,amp_latched}))>>>8;
        noise_product=gaussian_latched*$signed({1'b0,noise_scale_latched});
    end
    always_ff @(posedge clk) begin
        // Read-only BRAM needs no reset; valid is held low until the pipeline refills.
        word_reg<=fcw_rom[desired_hz];
        if(!rst_n) begin
            wave_latched<=0; amp_latched<=255;
            bias_latched<=0; idle_latched<=0; noise_latched<=0; noise_scale_latched<=0;
            jam_latched<=0; jam_amp_latched<=0; jam_hz_latched<=12'd1500;
            rng<=32'h73ac91e5; gaussian_latched<=0; valid_pipe<=0; sample_valid<=0;
            burst_count<=0; burst_slot<=0; burst_fire<=0;
            scaled_reg<=0; noise_reg<=0; base_reg<=128; total_reg<=128;
            sample_data<=128; clipped<=0;
        end else begin
            // The controller leaves time for this registered lookup before sample_ce.
            valid_pipe<={valid_pipe[2:0],sample_ce}; sample_valid<=valid_pipe[3];
            clipped<=0;
            if(valid_pipe[1]) begin
                scaled_reg<=idle_latched ? 0 : scaled;
                // Signed correction preserves symmetric ties without duplicating the multiplier.
                noise_reg<=noise_latched ? ((noise_product +
                    (gaussian_latched[15] ? 36'sd32767 : 36'sd32768))>>>16) : 0;
                base_reg<=128+bias_latched;
            end
            if(valid_pipe[2]) total_reg<=base_reg+scaled_reg+noise_reg+jam_code;
            if(valid_pipe[3]) begin
                clipped<=(total_reg<0 || total_reg>255);
                sample_data<=(total_reg<0) ? 0 : ((total_reg>255) ? 255 : total_reg[7:0]);
            end
            if(sample_ce) begin
                wave_latched<=fsk_active ? 0 : dds_cfg.wave[1:0];
                amp_latched<=fsk_active ? fsk_cfg.amplitude : dds_cfg.amplitude;
                bias_latched<=fsk_active ? fsk_cfg.bias : dds_cfg.bias;
                idle_latched<=fsk_active && !frame_active;
                noise_latched<=frame_active && fsk_cfg.physical_noise[0] && fsk_cfg.software_noise[0];
                noise_scale_latched<=fsk_cfg.noise_scale;
                jam_latched<=frame_active && jam_enable && (!jam_burst || burst_gate);
                if(!frame_active) burst_count<=0;
                else begin
                    burst_count<=(burst_count==999) ? 10'd0 : burst_count+1'b1;
                    if(burst_count==0) begin burst_slot<=rng[3:2]; burst_fire<=rng[1]; end
                end
                jam_amp_latched<=jam_amplitude;
                jam_hz_latched<=jam_hz;
                rng<=random_next(rng); gaussian_latched<=gaussian[rng[31:24]];
            end
        end
    end
endmodule
