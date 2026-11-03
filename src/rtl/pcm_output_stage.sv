// PCM output: bounded Q1.15 gain -> symmetric saturation -> Q6 gain -> startup fade.
// GAIN_Q15=32768 is unity. The atten_gain input is Q6 GAIN (64=unity, 0=silence).
// Configuration field 18 instead carries an attenuation amount (0=unity, 64=silence);
// instrument_extension_core performs the conversion once at the interface boundary.
// Explicit wide intermediate values and slices prevent unintended wrap/truncation.
// A digital limit does not certify the analog amplifier or speaker output level.
module pcm_output_stage #(
    parameter integer GAIN_Q15     = 32768,  // 32768 = 0 dB (reference), 16384 = -6.02 dB
    parameter integer LIMIT_LSB    = 32767,  // symmetric digital ceiling, 1..32767
    parameter integer FADE_SAMPLES = 512     // ramp length in 48 kHz samples (512 = 10.67 ms)
) (
    input  logic               clk,
    input  logic               rst_n,
    input  logic               sample_ce,
    input  logic signed [17:0] pcm_in,        // wide signed mix / effect output
    // user attenuation: 0 = unity, 64 = silence, applied AFTER saturation
    input  logic               atten_valid,
    input  logic [6:0]         atten_gain,
    // calibration busy / latched fault: silence now, ramp back when released
    input  logic               mute_request,
    output logic signed [15:0] pcm_out,
    output logic               limited,       // this sample hit the ceiling
    output logic               muted,         // fade level is exactly zero
    output logic               fade_active,   // ramp in progress
    output logic [15:0]        limit_count    // samples clamped since reset (saturating)
);

    // ---- parameter checks (simulation only; synthesis ignores the initial block) --------------
    initial begin
        if (GAIN_Q15 < 0 || GAIN_Q15 > 32768) $error("GAIN_Q15 must be 0..32768");
        if (LIMIT_LSB < 1 || LIMIT_LSB > 32767) $error("LIMIT_LSB must be 1..32767");
        if (FADE_SAMPLES < 0) $error("FADE_SAMPLES must be >= 0");
    end

    // Constant quotient/remainder gives floor(256*k/N), reaching unity on exactly CE number N.
    // There is no variable divider or extra DSP. N=0 means unity on the first CE after reset/mute.
    localparam integer N = (FADE_SAMPLES <= 0) ? 1 : FADE_SAMPLES;
    localparam integer CW = (N < 2) ? 1 : $clog2(N + 1);
    localparam integer BASE = 256 / N;
    localparam integer REM = 256 % N;
    localparam logic [9:0] BASE_V = BASE[9:0];
    localparam logic [CW:0] REM_V = REM[CW:0];
    localparam logic [CW:0] N_V = N[CW:0];
    localparam integer LAST_I = N - 1;
    localparam logic [CW-1:0] LAST = LAST_I[CW-1:0];

    /* ---- 1. bounded gain ------------------------------------------------------------------- */
    // |pcm_in| <= 32768 and GAIN_Q15 <= 32768, so |product| <= 2^30 and the shifted result fits in
    // 17 signed bits; 18 bits are carried for the sign-extension of -32768.
    logic signed [34:0] gain_product;   // 18-bit signed x 17-bit unsigned
    logic signed [34:0] gain_scaled;    // same width as the expression, never implicit
    logic signed [17:0] gained;

    wire signed [16:0] gain_q15 = GAIN_Q15[16:0];

    always_comb gain_product = pcm_in * $signed({1'b0, gain_q15});
    // Truncate toward zero so the transfer stays odd-symmetric: -x maps to exactly -(x).
    always_comb gain_scaled = (gain_product < 0) ? -((-gain_product) >>> 15)
                                                 :  (gain_product >>> 15);
    always_comb gained = gain_scaled[17:0];

    /* ---- 2. symmetric saturation (never wrap) ---------------------------------------------- */
    logic signed [17:0] saturated;
    wire  signed [17:0] limit_pos = LIMIT_LSB;
    wire  signed [17:0] limit_neg = -LIMIT_LSB;

    always_comb begin
        limited = 1'b0;
        if (gained > limit_pos) begin
            saturated = limit_pos;
            limited   = 1'b1;
        end else if (gained < limit_neg) begin
            saturated = limit_neg;
            limited   = 1'b1;
        end else begin
            saturated = gained;
        end
    end

    /* ---- 3. attenuate-only user control ---------------------------------------------------- */
    // |saturated| <= 32767 and atten_gain <= 64, so |product| <= 2^21 and the shifted result fits in
    // 16 signed bits; 18 bits are carried for symmetry with the gain stage.
    // atten_gain here is a Q6 GAIN: 64 = unity, 0 = silence. The user-facing field
    // (`user_attenuation`, 0 = unity .. 64 = silence) is the complement of this and is converted
    // once, in the configuration layer (rtl/instrument_extension_core.sv), exactly as
    // candidates/productized_instrument/rtl/config_apply.sv does it.
    logic signed [24:0] atten_product;
    logic signed [24:0] atten_scaled;
    logic signed [17:0] attenuated;

    always_comb atten_product = saturated * $signed({1'b0, atten_gain});
    always_comb atten_scaled = (atten_product < 0) ? -((-atten_product) >>> 6)
                                                   :  (atten_product >>> 6);
    always_comb attenuated = !atten_valid ? saturated : atten_scaled[17:0];

    /* ---- 4. startup / unmute fade ---------------------------------------------------------- */
    logic [8:0]  fade_q8;
    logic [9:0]  fade_sum;
    logic [CW-1:0] fade_samples, fade_remainder;
    wire [CW:0] remainder_sum = {1'b0, fade_remainder} + REM_V;
    wire carry = (remainder_sum >= N_V);
    wire [CW:0] remainder_next = carry ? (remainder_sum - N_V) : remainder_sum;
    logic signed [26:0] fade_product;   // 18-bit signed x 9-bit unsigned
    logic signed [26:0] fade_scaled;
    logic signed [17:0] faded;

    always_comb fade_sum = {1'b0, fade_q8} + BASE_V + {9'd0, carry};

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fade_q8     <= 9'd0;
            fade_samples <= '0;
            fade_remainder <= '0;
            limit_count <= 16'd0;
        end else begin
            if (mute_request) begin
                fade_q8 <= 9'd0;
                fade_samples <= '0;
                fade_remainder <= '0;
            end else if (sample_ce) begin
                if (fade_q8 < 9'd256) begin
                    fade_q8 <= (fade_samples == LAST) ? 9'd256 : fade_sum[8:0];
                    fade_samples <= fade_samples + 1'b1;
                    fade_remainder <= remainder_next[CW-1:0];
                end
            end
            if (sample_ce && limited && limit_count != 16'hFFFF)
                limit_count <= limit_count + 16'd1;
        end
    end

    always_comb fade_product = attenuated * $signed({1'b0, fade_q8});
    always_comb fade_scaled = (fade_product < 0) ? -((-fade_product) >>> 8)
                                                 :  (fade_product >>> 8);
    always_comb faded = fade_scaled[17:0];

    assign muted       = (fade_q8 == 9'd0);
    assign fade_active = (fade_q8 != 9'd256);
    assign pcm_out     = faded[15:0];

endmodule
