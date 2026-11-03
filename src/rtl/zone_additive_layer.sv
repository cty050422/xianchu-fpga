// Additive harmonic layer, driven by the expression of the voice that owns it.
//
// Target: Tang Mega 60K with NEO Dock; see docs/hardware.md.
//
// WHAT IT ADDS TO THE FROZEN BASELINE: the frozen instrument shapes every note with loudness and
// brightness. This layer adds joystick-selected harmonic richness using a real
// additive oscillator: one note is rebuilt from up to 32 harmonic partials. The second joystick X
// chooses the harmonic count; pressure retains ownership and gain, so count and loudness are separate.
//
// OWNERSHIP RULE (deliberate, and tested):
//   * The layer follows ONE note - one VOICE of the frozen instrument - at a time. It takes the
//     pitch from that voice's phase increment, which already includes the thumb bend, and the
//     pressure from that voice's own expression value.
//   * The owner is chosen by expression: the hardest-pressed sounding voice owns the layer. A
//     different voice only takes it over when it is pressed at least OWN_MARGIN harder, so two
//     notes of similar pressure cannot make the layer chatter between them.
//   * The margin test is done in 17 bits (see expression_gap): 'owner + OWN_MARGIN' evaluated in
//     16 bits wraps for owner > 0xF000 and would then let a barely touched voice steal the layer
//     from the hardest-pressed one.
//   * A TAKEOVER IS MUTED FIRST. Changing the owner changes pitch and mask instantly, so switching
//     while the layer is still loud produces a click. The takeover therefore mutes the layer to
//     gain = 0 first (output 'switching' is high meanwhile), changes the owner on the first sample
//     where the gain really is zero, and only then ramps the new note in. Releasing an owner while
//     another voice is still sounding uses that same mute-before-handover path.
//   * The layer can never sound without a voice: with no voice gated it ramps down to zero.
//
// WHY THE VOICE AND NOT A ZONE: the frozen voice allocator assigns a FREE voice to whichever zone
// starts a note, so voice i is not permanently zone i. Taking the pitch and the pressure from the
// allocated VOICE - both of which the frozen instrument publishes as ports - keeps the layer
// correct whatever the allocator decides, and it needs no change to the frozen RTL.
//
// NYQUIST: the additive bank drops every partial whose own increment k * base_inc leaves the guard
// band (see rtl/additive_bank_32.sv), so a high note is built from fewer than 32 partials instead
// of folding non-harmonic aliases back into the audible band. partials_active reports how many
// partials the last finished sample really used; it is held steady while a takeover is muting,
// because the pitch and the mask of the sounding note must not change during that window.
//
// NUMERICS: the partial mask comes from a shift (2..32 partials), the output gain is applied by an
// explicitly unrolled shift-and-add chain (no multiplier, no DSP block), and the gain ramps toward
// the pressure level with a fixed step per sample. Optional mask crossfading also bounds changes
// in harmonic weights when pressure crosses a partial-count boundary. These smoothers reduce
// control discontinuities; audible click freedom still requires measurement. The additive bank
// saturates its own sum and this module clamps its output as well.
//
// STATUS: RTL simulation in sim/tb_zone_additive_layer.sv. Synthesis, PnR and everything audible
// are reported separately; nothing here has been heard on hardware.
module zone_additive_layer #(
    parameter integer   PARTIALS     = 32,
    parameter integer   GAIN_STEP    = 4,        // gain units per sample over a 0..255 range
    parameter integer   MASK_FADE_STEP = 0,      // 0: legacy masks; 4: 64-sample crossfade
    parameter bit       SINE_INTERPOLATION = 1'b0,
    parameter logic [3:0] LEVEL_SHIFT = 4'd4,    // additive bank output scaling (divide by 16)
    parameter logic [15:0] OWN_MARGIN = 16'd4096, // how much harder a voice must be pressed
    parameter logic [31:0] NYQUIST_LIMIT = 32'h7000_0000, // additive bank guard band
    parameter logic USE_VOICE_ENVELOPES = 1'b0
) (
    input  logic               clk,
    input  logic               rst_n,
    input  logic               sample_ce,          // one pulse per audio sample (48 kHz)
    input  logic [3:0]         voice_gates,        // which voices of the frozen instrument sound
    input  logic [63:0]        voice_expression,   // 4 voices x 16 bits of pressure
    input  logic [63:0]        voice_envelopes,    // optional owner-bound ADSR; zero really silences
    input  logic [127:0]       voice_phase_incs,   // 4 voices x 32 bits, thumb bend included
    input  logic [5:0]         partial_target,     // independent joystick control, 2..32
    output logic signed [15:0] pcm_layer,          // the layer's own audio, to be mixed
    output logic [1:0]         owner_voice,        // the voice that owns the layer right now
    output logic               owner_valid,        // an owner exists and its voice is sounding
    output logic [31:0]        partial_mask,       // requested mask; fading tails may still contribute
    output logic [7:0]         gain,               // current layer gain (0..255), for the report
    output logic               switching,          // 1 = muting the layer to change owner cleanly
    output logic [5:0]         partials_active,    // partials used by the last finished sample
    output logic [255:0]       diag_bank_snapshot
);
    logic [1:0]  owner;
    logic [1:0]  best_voice;
    logic        best_valid;
    logic [15:0] best_expression;
    logic [15:0] owner_expression;
    logic [16:0] expression_gap;
    logic        takeover_wanted;
    logic        mute_state;             // 1 = muted on purpose, waiting for gain == 0
    logic [15:0] pressure_sel;
    logic [31:0] inc_sel;
    logic [5:0]  n_partials;
    logic [31:0] mask_comb;
    logic [7:0]  target_gain;
    logic [9:0]  pressure_gain_sum;
    logic [7:0] pressure_gain_base;
    logic [15:0] envelope_sel;
    logic [23:0] envelope_gain_product, envelope_gain_rounded;
    logic signed [15:0] bank_out;
    logic [5:0]  bank_partials_active;
    logic signed [23:0] bank_ext;
    logic signed [23:0] scaled;

    // ---- which voice owns the layer ------------------------------------------------
    always_comb begin
        best_voice      = 2'd0;
        best_valid      = 1'b0;
        best_expression = 16'd0;
        for (integer v = 0; v < 4; v = v + 1) begin
            if (voice_gates[v] && (!best_valid || (voice_expression[v * 16 +: 16] > best_expression))) begin
                best_voice      = v[1:0];
                best_expression = voice_expression[v * 16 +: 16];
                best_valid      = 1'b1;
            end
        end
    end

    always_comb owner_expression = voice_expression[owner * 16 +: 16];

    // 17-bit gap: 'best_expression > owner_expression + OWN_MARGIN' would be evaluated in 16 bits
    // and wrap as soon as the owner is pressed harder than 0xF000 (0xFF00 + 0x1000 -> 0x0F00), so a
    // barely touched voice could take the layer away from the hardest-pressed one. The > test on
    // the expressions themselves guards the unsigned wrap of the subtraction.
    always_comb expression_gap  = {1'b0, best_expression} - {1'b0, owner_expression};
    always_comb takeover_wanted = best_valid && (best_voice != owner) &&
                                  (best_expression > owner_expression) &&
                                  (expression_gap > {1'b0, OWN_MARGIN});

    assign switching = mute_state;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            owner       <= 2'd0;
            owner_valid <= 1'b0;
            mute_state  <= 1'b0;
        end else if (sample_ce) begin
            if (!mute_state) begin
                if (!voice_gates[owner]) begin
                    // The owner let go. Changing pitch and mask while the layer is still loud is a
                    // click (the layer's own gain is what makes the difference audible), so the
                    // hand-over takes the SAME muted route as a takeover: mute first, and only
                    // change the owner once the gain has really reached zero.
                    if (best_valid && (gain != 8'd0) && (GAIN_STEP[7:0] != 8'd0)) begin
                        mute_state  <= 1'b1;
                        owner_valid <= 1'b1;
                    end else if (best_valid) begin
                        owner       <= best_voice;   // already silent: the owner may change at once
                        owner_valid <= 1'b1;
                    end else begin
                        // Nothing else is sounding: do NOT hand the layer to a silent slot (its
                        // phase increment and expression are stale, so the layer would jump to a
                        // wrong pitch, or to 0 Hz and a DC offset, while still at full gain). Keep
                        // the current pitch and mask and let the gain ramp down to zero.
                        owner_valid <= 1'b0;
                    end
                end else if (takeover_wanted) begin
                    // A clearly harder press wants the layer: mute first, change the owner when the
                    // gain has really reached zero. Changing pitch and mask while the layer is loud
                    // is what makes a takeover click.
                    mute_state  <= 1'b1;
                    owner_valid <= 1'b1;
                end else begin
                    owner_valid <= 1'b1;
                end
            end else begin
                if ((gain == 8'd0) || (GAIN_STEP[7:0] == 8'd0)) begin
                    // The layer is silent NOW: this is the only moment at which the owner may
                    // change, so the new note starts from zero gain and ramps in. (GAIN_STEP = 0
                    // cannot ramp, so it switches at once rather than deadlocking.)
                    // Silent now: this is the only moment at which the owner may change, whether
                    // the reason was a takeover or the old owner letting go.
                    if (best_valid) begin
                        owner       <= best_voice;
                        owner_valid <= 1'b1;
                    end else begin
                        owner_valid <= 1'b0;
                    end
                    mute_state  <= 1'b0;
                end else begin
                    owner_valid <= 1'b1;
                end
            end
        end
    end

    always_comb begin
        pressure_sel = owner_expression;
        inc_sel      = voice_phase_incs[owner * 32 +: 32];
    end

    // Harmonic count is independent of pressure. Clamp malformed input to the
    // supported range; pressure only selects the owner and sets the layer gain.
    always_comb begin
        n_partials = partial_target;
        if (n_partials < 6'd2) n_partials = 6'd2;
        if (n_partials > PARTIALS[5:0]) n_partials = PARTIALS[5:0];
    end

    always_comb begin
        if (n_partials >= 6'd32) mask_comb = 32'hFFFF_FFFF;
        else                     mask_comb = (32'h0000_0001 << n_partials) - 32'h0000_0001;
    end

    assign partial_mask = mask_comb;

    // Match the base synth's approximate 0.25..1.0 pressure gain curve. Scaling the
    // fundamental and additive layer together keeps pressure as a loudness control;
    // joystick 2 X (partial_target) remains the independent brightness control.
    always_comb begin
        pressure_gain_sum = {2'b0, pressure_sel[15:8]} +
                            ({2'b0, pressure_sel[15:8]} << 1);
        pressure_gain_base = 8'd64 + pressure_gain_sum[9:2];
        envelope_sel = USE_VOICE_ENVELOPES ? voice_envelopes[owner*16 +: 16] : 16'hffff;
        // 8 x 16 unsigned fits 24 bits. Rounding preserves both exact zero and
        // the existing gain at envelope=65535, with no master-output boost.
        envelope_gain_product = {16'd0, pressure_gain_base} * {8'd0, envelope_sel};
        envelope_gain_rounded = envelope_gain_product + 24'd32768;
        target_gain = (mute_state || !owner_valid)
                    ? 8'd0
                    : (USE_VOICE_ENVELOPES ? envelope_gain_rounded[23:16] : pressure_gain_base);
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            gain <= 8'd0;
        end else if (sample_ce) begin
            if (gain < target_gain)
                gain <= ((target_gain - gain) > GAIN_STEP[7:0]) ? (gain + GAIN_STEP[7:0]) : target_gain;
            else if (gain > target_gain)
                gain <= ((gain - target_gain) > GAIN_STEP[7:0]) ? (gain - GAIN_STEP[7:0]) : target_gain;
        end
    end

    // The instance name must not be 'table': that is a Verilog keyword (UDP tables).
    additive_bank_32 #(.PARTIALS(PARTIALS), .NYQUIST_LIMIT(NYQUIST_LIMIT),
                       .MASK_FADE_STEP(MASK_FADE_STEP),
                       .SINE_INTERPOLATION(SINE_INTERPOLATION)) bank (
        .clk(clk), .rst_n(rst_n), .sample_ce(sample_ce),
        .base_inc(inc_sel), .partial_enable(mask_comb), .level_shift(LEVEL_SHIFT),
        .sample(bank_out), .partials_active(bank_partials_active), .busy(),
        .diag_snapshot(diag_bank_snapshot)
    );

    // The bank reports how many partials it just summed. It is exposed unchanged, except while a
    // takeover is muting: the note that is still sounding must report a steady count until the
    // owner - and with it the pitch and the mask - actually changes.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)                    partials_active <= 6'd0;
        else if (sample_ce && !switching) partials_active <= bank_partials_active;
    end

    always_comb bank_ext = {{8{bank_out[15]}}, bank_out};

    // pcm_layer = (bank_out * gain) >>> 8, written as an explicitly unrolled shift-and-add chain so
    // that this gain stage costs no multiplier or DSP block: gain bit b contributes
    // bank_out / 2^(8-b). Each term uses its OWN constant shift - halving an already truncated
    // running term would throw away the low bits eight times over and leave a few LSB behind.
    always_comb begin
        scaled = 24'sd0;
        if (gain[0]) scaled = scaled + (bank_ext >>> 8);
        if (gain[1]) scaled = scaled + (bank_ext >>> 7);
        if (gain[2]) scaled = scaled + (bank_ext >>> 6);
        if (gain[3]) scaled = scaled + (bank_ext >>> 5);
        if (gain[4]) scaled = scaled + (bank_ext >>> 4);
        if (gain[5]) scaled = scaled + (bank_ext >>> 3);
        if (gain[6]) scaled = scaled + (bank_ext >>> 2);
        if (gain[7]) scaled = scaled + (bank_ext >>> 1);
    end

    function automatic logic signed [15:0] clamp16(input logic signed [23:0] value);
        begin
            if (value > 24'sd32767)       clamp16 = 16'sd32767;
            else if (value < -24'sd32768) clamp16 = -16'sd32768;
            else                          clamp16 = value[15:0];
        end
    endfunction

    always_comb pcm_layer = clamp16(scaled);
    assign owner_voice = owner;
endmodule
