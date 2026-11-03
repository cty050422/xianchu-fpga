// Four-voice polyphonic core with per-voice expression and per-voice preset (M2 + M3).
//
// Difference from rtl/poly_synth_core_four_voice.sv (the old shared-parameter core):
//   * ownership comes from rtl/voice_allocator_regions.sv, so each voice belongs to one
//     (region, generation) pair and a released voice keeps the expression it was released
//     with for its whole tail;
//   * every voice has its OWN waveform select, phase increment, envelope steps, PM index
//     and gain, so one region's pressure cannot change another region's timbre;
//   * pressure shapes gain of the owning voice only. The voice_sample* debug outputs carry the POST-gain samples since S10 (panel levels). Timbre brightness is controlled
//     independently by the additive-layer partial count.
//     independent dimensions: one gesture drives both outputs;
//   * two presets are implemented as parameter sets (pluck / wind). They are synthesis
//     coefficients - no recorded audio is involved.
//
// PRESETS (initial engineering values, to be re-tuned once the electrodes are measured):
//   preset 0 "pluck": fast attack, short decay, low sustain, soft DDS triangle, light PM
//   preset 1 "wind" : short but softer attack, sustained level, PM-heavy carrier
//   Envelope steps are per-sample increments of a 16-bit level at 48 kHz.
//
// Gain mapping: gain_q15 = GAIN_FLOOR + expression*(32768-GAIN_FLOOR)/65536, so a resting
// electrode still produces sound at GAIN_FLOOR and full pressure doubles it. Both the gain
// and the PM index are 16x16 products (DSP), which is why this core needs a few more DSP
// blocks than the old one.
module poly_synth_regions #(
    parameter bit EXPRESSIVE_ADSR = 1'b0,
    parameter bit ADSR_ERROR_FEEDBACK = 1'b0,
    parameter bit BALANCED_PRESETS = 1'b0,
    // Default-off preserves the published/reference coefficients exactly.
    parameter bit MUSICAL_PRESETS = 1'b0,
    parameter logic [15:0] GAIN_FLOOR = 16'd8192,  // 0.25 in Q1.15 at zero pressure
    parameter logic [15:0] GAIN_CEIL  = 16'd32767  // 1.0 in Q1.15 at full pressure
) (
    input  logic               clk,
    input  logic               rst_n,
    input  logic               sample_ce,
    // Note events (already arbitrated and queued upstream, one per clock)
    input  logic               event_valid,
    input  logic               event_on,
    input  logic [1:0]         event_region,
    input  logic [6:0]         event_note,
    input  logic [31:0]        event_phase_inc,
    input  logic [1:0]         event_preset,
    input  logic [7:0]         event_generation,
    // T1 live retune stream (see voice_allocator_regions): group/octave remaps of
    // already-held voices. Passes straight to the allocator; the rewritten slot
    // increment reaches the base cores and the additive layer through the same
    // phase_incs -> bend -> voice_phase_incs chain as a note-on latched increment.
    input  logic               retune_valid,
    input  logic [1:0]         retune_region,
    input  logic [6:0]         retune_old_note,
    input  logic [6:0]         retune_new_note,
    input  logic [31:0]        retune_phase_inc,
    input  logic [7:0]         retune_generation,
    // Live expression of each region (16 bits per region)
    input  logic [63:0]        region_pressure,
    // Global pitch bend ratio in Q1.15 (32768 = no bend), from rtl/pitch_bend.sv. It is
    // applied to the phase increment LATCHED at note-on, so bending cannot accumulate a
    // drift and returning the stick to the centre restores the original pitch exactly.
    input  logic [15:0]        bend_ratio_q15,
    // Mix output
    output logic signed [15:0] pcm_sample,
    output logic               clipped,
    // Per-voice observability: the digital A/B evidence uses these taps.
    output logic signed [15:0] voice_sample0,
    output logic signed [15:0] voice_sample1,
    output logic signed [15:0] voice_sample2,
    output logic signed [15:0] voice_sample3,
    output logic [63:0]        voice_expression,   // expression each voice actually used
    output logic [63:0]        voice_envelopes,    // ADSR of each allocated voice; audio path unchanged
    output logic [11:0]        voice_envelope_states,
    output logic [127:0]       voice_phase_incs,   // phase increment each voice actually used
    output logic [63:0]        voice_gain,         // gain each voice actually used
    output logic [7:0]         voice_presets,
    output logic [3:0]         voice_gates,
    output logic [3:0]         active_voices,
    output logic [3:0]         allocated_voices,
    output logic [3:0]         event_accepted,
    output logic [3:0]         stolen,
    output logic [31:0]        voice_notes,
    output logic [7:0]         owner_regions,
    output logic [31:0]        owner_generations,
    output logic [1:0]         selected_voice,
    output logic               event_overflow   // an event was refused (should stay 0)
);
    logic [3:0]   gates, retriggers;
    logic [127:0] phase_incs;
    logic [127:0] bent_phase_incs;
    logic [63:0]  bend_product;
    logic [7:0]   presets;
    logic [63:0]  expressions;
    logic [31:0]  owner_notes;
    assign voice_notes=owner_notes;
    logic [15:0]  envelope0, envelope1, envelope2, envelope3;
    logic [15:0]  modulation_index0, modulation_index1, modulation_index2, modulation_index3;
    logic [15:0]  gain0, gain1, gain2, gain3;
    logic [15:0] gain_target0, gain_target1, gain_target2, gain_target3;
    logic [15:0]  gain_span;
    logic [31:0]  gain_product0, gain_product1, gain_product2, gain_product3;
    logic signed [15:0] raw0, raw1, raw2, raw3;
    logic signed [15:0] scaled0, scaled1, scaled2, scaled3;
    logic [1:0]   waveform0, waveform1, waveform2, waveform3;
    logic [15:0]  attack0, decay0, sustain0, release0;
    logic [15:0]  attack1, decay1, sustain1, release1;
    logic [15:0]  attack2, decay2, sustain2, release2;
    logic [15:0]  attack3, decay3, sustain3, release3;

    // ---- preset 0: pluck ----------------------------------------------------
    localparam logic [1:0]  PLUCK_WAVE    = 2'd2;          // triangle DDS (+ light PM)
    localparam logic [15:0] PLUCK_ATTACK  = 16'd512;       // 128 samples  ~2.7 ms
    localparam logic [15:0] PLUCK_DECAY   = 16'd8;         // to sustain   ~149 ms
    localparam logic [15:0] PLUCK_SUSTAIN = 16'd8192;      // 0.125
    localparam logic [15:0] PLUCK_RELEASE = 16'd4;         // from sustain ~43 ms
    localparam logic [15:0] PLUCK_PM_FIXED = 16'h0400;     // fixed light PM colour

    // ---- preset 1: wind -----------------------------------------------------
    localparam logic [1:0]  WIND_WAVE     = 2'd3;          // two-operator PM
    localparam logic [15:0] WIND_ATTACK   = 16'd256;       // 256 samples  ~5.3 ms
    localparam logic [15:0] WIND_DECAY    = 16'd16;        // to sustain   ~21 ms
    localparam logic [15:0] WIND_SUSTAIN  = 16'd49152;     // 0.75
    localparam logic [15:0] WIND_RELEASE  = 16'd8;         // from sustain ~128 ms
    // Separate sustained wind colour from the triangle pluck at equal pressure.
    // Keep envelope, gain, voice ownership and expression mappings unchanged.
    localparam logic [15:0] WIND_PM_FIXED = 16'h8000;      // fixed stronger 2:1 PM colour

    // EXPERIMENT ONLY. Presets 0/1 retain the exact original coefficients.
    // 2: bell-like, sine PM with 7:2 modulator ratio, one-shot amplitude decay.
    // 3: synth bass-like, controlled 1:1 sine PM + short decay / moderate sustain.
    // No octave shift, gain boost, owner or expression changes are made.
    function automatic logic [1:0] preset_wave(input logic [1:0] preset);
        case(preset)
            0: preset_wave = PLUCK_WAVE;
            1: preset_wave = WIND_WAVE;
            2: preset_wave = 2'd3;
            3: preset_wave = 2'd3;
        endcase
    endfunction
    function automatic logic [15:0] preset_attack(input logic [1:0] preset);
        case(preset)
            0: preset_attack = PLUCK_ATTACK;
            1: preset_attack = WIND_ATTACK;
            2: preset_attack = 16'd2048;
            3: preset_attack = 16'd2048;
        endcase
    endfunction
    function automatic logic [15:0] preset_decay(input logic [1:0] preset);
        case(preset)
            0: preset_decay = PLUCK_DECAY;
            1: preset_decay = WIND_DECAY;
            2: preset_decay = 16'd4;
            3: preset_decay = 16'd64;
        endcase
    endfunction
    function automatic logic [15:0] preset_sustain(input logic [1:0] preset);
        if (MUSICAL_PRESETS) begin
            // Pluck decays below wind; bell remains a playable held voice.
            case (preset)
                2'd0: preset_sustain = 16'd24576;
                2'd1: preset_sustain = 16'd36864;
                2'd2: preset_sustain = 16'd24576;
                default: preset_sustain = 16'd32768;
            endcase
        end else if (BALANCED_PRESETS) begin
            // Main instrument: keep every held note audible. Sine PM has a
            // higher RMS than triangle PM, so its sustain level is lower.
            case (preset)
                2'd0, 2'd1: preset_sustain = 16'd32768;
                default:    preset_sustain = 16'd28672;
            endcase
        end else begin
            case (preset)
                2'd0: preset_sustain = PLUCK_SUSTAIN;
                2'd1: preset_sustain = WIND_SUSTAIN;
                2'd2: preset_sustain = 16'd0;
                default: preset_sustain = 16'd24576;
            endcase
        end
    endfunction
    function automatic logic [15:0] preset_release(input logic [1:0] preset);
        case(preset)
            0: preset_release = PLUCK_RELEASE;
            1: preset_release = WIND_RELEASE;
            2: preset_release = MUSICAL_PRESETS ? 16'd1 : 16'd4;
            3: preset_release = MUSICAL_PRESETS ? 16'd16 : 16'd64;
        endcase
    endfunction
    function automatic logic [15:0] preset_pm_fixed(input logic [1:0] preset);
        case(preset)
            0: preset_pm_fixed = PLUCK_PM_FIXED;
            1: preset_pm_fixed = WIND_PM_FIXED;
            2: preset_pm_fixed = 16'h5000;
            3: preset_pm_fixed = 16'h2800;
        endcase
    endfunction

    // Conservative nominal steady-state RMS trims: no preset is boosted.
    // They align digital levels, not perceptual loudness.
    function automatic logic [8:0] preset_trim_q8(input logic [1:0] preset);
        case (preset)
            2'd0: preset_trim_q8 = 9'd256;
            2'd1: preset_trim_q8 = 9'd128;
            2'd2: preset_trim_q8 = 9'd208;
            default: preset_trim_q8 = 9'd168;
        endcase
    endfunction

    // Continuous two-segment pressure curve: slopes 3/4 then 5/4.
    // All arithmetic here is shifts/adds; endpoints are 0..65534.
    function automatic logic [15:0] musical_pressure(input logic [15:0] pressure);
        logic [17:0] wide;
        logic [15:0] upper;
        begin
            if (!pressure[15]) begin
                wide = {2'd0,pressure} + ({2'd0,pressure} << 1);
                musical_pressure = wide[17:2];
            end else begin
                upper = pressure - 16'd32768;
                wide = {2'd0,upper} + ({2'd0,upper} << 2);
                musical_pressure = 16'd24576 + wide[17:2];
            end
        end
    endfunction

    function automatic logic [15:0] musical_gain(input logic [15:0] pressure,
                                                 input logic [1:0] preset);
        logic [15:0] floor_value, span, mapped, untrimmed;
        logic [31:0] product;
        logic [24:0] trimmed;
        begin
            floor_value = (GAIN_FLOOR > 16'd4096) ? 16'd4096 : GAIN_FLOOR;
            span = GAIN_CEIL - floor_value;
            mapped = musical_pressure(pressure);
            product = {16'd0,mapped} * {16'd0,span};
            untrimmed = floor_value + product[31:16];
            trimmed = untrimmed * preset_trim_q8(preset) + 25'd128;
            musical_gain = trimmed[23:8];
        end
    endfunction

    function automatic logic [15:0] slew_gain(input logic [15:0] current,
                                              input logic [15:0] target);
        if (target > current)
            slew_gain = ((target-current) > 16'd256) ? current+16'd256 : target;
        else
            slew_gain = ((current-target) > 16'd256) ? current-16'd256 : target;
    endfunction

    // ---- ownership ----------------------------------------------------------
    voice_allocator_regions allocator (
        .clk(clk), .rst_n(rst_n), .sample_ce(sample_ce),
        .event_valid(event_valid), .event_on(event_on), .event_region(event_region),
        .event_note(event_note), .event_phase_inc(event_phase_inc),
        .event_preset(event_preset), .event_generation(event_generation),
        .retune_valid(retune_valid), .retune_region(retune_region),
        .retune_old_note(retune_old_note), .retune_new_note(retune_new_note),
        .retune_phase_inc(retune_phase_inc), .retune_generation(retune_generation),
        .envelope0(envelope0), .envelope1(envelope1),
        .envelope2(envelope2), .envelope3(envelope3),
        .region_pressure(region_pressure),
        .gates(gates), .retriggers(retriggers), .phase_incs(phase_incs),
        .presets(presets), .expressions(expressions), .allocated(allocated_voices),
        .owner_regions(owner_regions), .owner_generations(owner_generations),
        .owner_notes(owner_notes), .event_accepted(event_accepted), .stolen(stolen),
        .selected_voice(selected_voice)
    );
    assign event_overflow = 1'b0;   // the allocator always accepts or steals; kept as a port
                                    // so a future queue can report overflow here.

    // ---- global pitch bend: scale the latched base increment -----------------
    // 32-bit products on purpose: an unsized 32x16 product is only 32 bits wide and the
    // lower bits would be lost differently than in the shift below.
    always_comb begin
        // The scaled increment is the top 32 bits of (base * ratio) >> 15. Writing the
        // intermediate slice explicitly keeps the width intentional; a shift expression
        // assigned to a 32-bit slice makes the tool warn about a 33-bit truncation.
        bend_product = {32'd0, phase_incs[31:0]} * {16'd0, bend_ratio_q15};
        bent_phase_incs[31:0] = bend_product[46:15];
        bend_product = {32'd0, phase_incs[63:32]} * {16'd0, bend_ratio_q15};
        bent_phase_incs[63:32] = bend_product[46:15];
        bend_product = {32'd0, phase_incs[95:64]} * {16'd0, bend_ratio_q15};
        bent_phase_incs[95:64] = bend_product[46:15];
        bend_product = {32'd0, phase_incs[127:96]} * {16'd0, bend_ratio_q15};
        bent_phase_incs[127:96] = bend_product[46:15];
    end

    // ---- per-voice parameters -----------------------------------------------
    always_comb begin
        waveform0 = preset_wave(presets[1:0]);
        waveform1 = preset_wave(presets[3:2]);
        waveform2 = preset_wave(presets[5:4]);
        waveform3 = preset_wave(presets[7:6]);
        attack0 = preset_attack(presets[1:0]);   decay0 = preset_decay(presets[1:0]);
        sustain0 = preset_sustain(presets[1:0]); release0 = preset_release(presets[1:0]);
        attack1 = preset_attack(presets[3:2]);   decay1 = preset_decay(presets[3:2]);
        sustain1 = preset_sustain(presets[3:2]); release1 = preset_release(presets[3:2]);
        attack2 = preset_attack(presets[5:4]);   decay2 = preset_decay(presets[5:4]);
        sustain2 = preset_sustain(presets[5:4]); release2 = preset_release(presets[5:4]);
        attack3 = preset_attack(presets[7:6]);   decay3 = preset_decay(presets[7:6]);
        sustain3 = preset_sustain(presets[7:6]); release3 = preset_release(presets[7:6]);
        // Pressure controls amplitude only. Each preset has a fixed PM index, so pressing
        // harder cannot silently change timbre brightness as well as loudness.
        gain_span = GAIN_CEIL - GAIN_FLOOR;
        modulation_index0 = preset_pm_fixed(presets[1:0]);
        modulation_index1 = preset_pm_fixed(presets[3:2]);
        modulation_index2 = preset_pm_fixed(presets[5:4]);
        modulation_index3 = preset_pm_fixed(presets[7:6]);
        gain_product0 = {16'd0, expressions[15:0]}  * {16'd0, gain_span};
        gain_product1 = {16'd0, expressions[31:16]} * {16'd0, gain_span};
        gain_product2 = {16'd0, expressions[47:32]} * {16'd0, gain_span};
        gain_product3 = {16'd0, expressions[63:48]} * {16'd0, gain_span};
        gain_target0 = MUSICAL_PRESETS ? musical_gain(expressions[15:0],presets[1:0]) : GAIN_FLOOR + gain_product0[31:16];
        gain_target1 = MUSICAL_PRESETS ? musical_gain(expressions[31:16],presets[3:2]) : GAIN_FLOOR + gain_product1[31:16];
        gain_target2 = MUSICAL_PRESETS ? musical_gain(expressions[47:32],presets[5:4]) : GAIN_FLOOR + gain_product2[31:16];
        gain_target3 = MUSICAL_PRESETS ? musical_gain(expressions[63:48],presets[7:6]) : GAIN_FLOOR + gain_product3[31:16];
    end

    generate if (MUSICAL_PRESETS) begin : musical_gain_smoothing
        // Idle envelopes initialize directly: first onset is not delayed by
        // a gain ramp. A nonzero retrigger retains the ongoing smooth gain.
        always_ff @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                gain0 <= 0; gain1 <= 0; gain2 <= 0; gain3 <= 0;
            end else if (sample_ce) begin
                gain0 <= (envelope0 == 0) ? gain_target0 : slew_gain(gain0,gain_target0);
                gain1 <= (envelope1 == 0) ? gain_target1 : slew_gain(gain1,gain_target1);
                gain2 <= (envelope2 == 0) ? gain_target2 : slew_gain(gain2,gain_target2);
                gain3 <= (envelope3 == 0) ? gain_target3 : slew_gain(gain3,gain_target3);
            end
        end
    end else begin : legacy_gain_mapping
        always_comb begin
            gain0 = gain_target0; gain1 = gain_target1;
            gain2 = gain_target2; gain3 = gain_target3;
        end
    end endgenerate

    // ---- four independent voices --------------------------------------------
    voice_core #(.CURVED_DECAY_RELEASE(EXPRESSIVE_ADSR),
                 .SPECTRAL_GUARD(MUSICAL_PRESETS),
                 .CONTINUOUS_RETRIGGER(EXPRESSIVE_ADSR),
                 .CURVE_SHIFT(MUSICAL_PRESETS ? 12 : 9),
                 .CURVE_ERROR_FEEDBACK(ADSR_ERROR_FEEDBACK)) voice0 (
        .clk(clk), .rst_n(rst_n), .sample_ce(sample_ce),
        .gate(gates[0]), .retrigger(retriggers[0]), .waveform(waveform0),
        .phase_inc(bent_phase_incs[31:0]), .modulation_index(modulation_index0),
        .pm_ratio_mode((presets[1:0] == 2'd2) ? 2'd1 : ((presets[1:0] == 2'd3) ? 2'd2 : 2'd0)),
        .attack_step(attack0), .decay_step(decay0), .sustain_level(sustain0),
        .release_step(release0), .sample(raw0), .envelope_debug(envelope0),
        .envelope_state_debug(voice_envelope_states[2:0])
    );
    voice_core #(.CURVED_DECAY_RELEASE(EXPRESSIVE_ADSR),
                 .SPECTRAL_GUARD(MUSICAL_PRESETS),
                 .CONTINUOUS_RETRIGGER(EXPRESSIVE_ADSR),
                 .CURVE_SHIFT(MUSICAL_PRESETS ? 12 : 9),
                 .CURVE_ERROR_FEEDBACK(ADSR_ERROR_FEEDBACK)) voice1 (
        .clk(clk), .rst_n(rst_n), .sample_ce(sample_ce),
        .gate(gates[1]), .retrigger(retriggers[1]), .waveform(waveform1),
        .phase_inc(bent_phase_incs[63:32]), .modulation_index(modulation_index1),
        .pm_ratio_mode((presets[3:2] == 2'd2) ? 2'd1 : ((presets[3:2] == 2'd3) ? 2'd2 : 2'd0)),
        .attack_step(attack1), .decay_step(decay1), .sustain_level(sustain1),
        .release_step(release1), .sample(raw1), .envelope_debug(envelope1),
        .envelope_state_debug(voice_envelope_states[5:3])
    );
    voice_core #(.CURVED_DECAY_RELEASE(EXPRESSIVE_ADSR),
                 .SPECTRAL_GUARD(MUSICAL_PRESETS),
                 .CONTINUOUS_RETRIGGER(EXPRESSIVE_ADSR),
                 .CURVE_SHIFT(MUSICAL_PRESETS ? 12 : 9),
                 .CURVE_ERROR_FEEDBACK(ADSR_ERROR_FEEDBACK)) voice2 (
        .clk(clk), .rst_n(rst_n), .sample_ce(sample_ce),
        .gate(gates[2]), .retrigger(retriggers[2]), .waveform(waveform2),
        .phase_inc(bent_phase_incs[95:64]), .modulation_index(modulation_index2),
        .pm_ratio_mode((presets[5:4] == 2'd2) ? 2'd1 : ((presets[5:4] == 2'd3) ? 2'd2 : 2'd0)),
        .attack_step(attack2), .decay_step(decay2), .sustain_level(sustain2),
        .release_step(release2), .sample(raw2), .envelope_debug(envelope2),
        .envelope_state_debug(voice_envelope_states[8:6])
    );
    voice_core #(.CURVED_DECAY_RELEASE(EXPRESSIVE_ADSR),
                 .SPECTRAL_GUARD(MUSICAL_PRESETS),
                 .CONTINUOUS_RETRIGGER(EXPRESSIVE_ADSR),
                 .CURVE_SHIFT(MUSICAL_PRESETS ? 12 : 9),
                 .CURVE_ERROR_FEEDBACK(ADSR_ERROR_FEEDBACK)) voice3 (
        .clk(clk), .rst_n(rst_n), .sample_ce(sample_ce),
        .gate(gates[3]), .retrigger(retriggers[3]), .waveform(waveform3),
        .phase_inc(bent_phase_incs[127:96]), .modulation_index(modulation_index3),
        .pm_ratio_mode((presets[7:6] == 2'd2) ? 2'd1 : ((presets[7:6] == 2'd3) ? 2'd2 : 2'd0)),
        .attack_step(attack3), .decay_step(decay3), .sustain_level(sustain3),
        .release_step(release3), .sample(raw3), .envelope_debug(envelope3),
        .envelope_state_debug(voice_envelope_states[11:9])
    );

    // ---- per-voice gain (pressure shapes volume only) ------------------------
    function automatic logic signed [15:0] apply_gain(input logic signed [15:0] sample,
                                                     input logic [15:0] gain);
        logic signed [31:0] product;
        logic signed [31:0] shifted;
        begin
            product = sample * $signed({1'b0, gain});
            shifted = product >>> 15;
            if (shifted > 32'sd32767) apply_gain = 16'sd32767;
            else if (shifted < -32'sd32768) apply_gain = -16'sd32768;
            else apply_gain = shifted[15:0];
        end
    endfunction

    always_comb begin
        scaled0 = apply_gain(raw0, gain0);
        scaled1 = apply_gain(raw1, gain1);
        scaled2 = apply_gain(raw2, gain2);
        scaled3 = apply_gain(raw3, gain3);
    end

    mixer4_saturating mixer (
        .voice0(scaled0), .voice1(scaled1), .voice2(scaled2), .voice3(scaled3),
        .mixed(pcm_sample), .clipped(clipped)
    );

    // S10: the panel needs the level AFTER the pressure gain. These outputs are
    // now apply_gain(scaled) samples; the pre-gain raw path stays internal.
    assign voice_sample0 = scaled0;
    assign voice_sample1 = scaled1;
    assign voice_sample2 = scaled2;
    assign voice_sample3 = scaled3;
    assign voice_expression = expressions;
    assign voice_envelopes = {envelope3, envelope2, envelope1, envelope0};
    assign voice_phase_incs = bent_phase_incs;
    assign voice_gain = {gain3, gain2, gain1, gain0};
    assign voice_presets = presets;
    assign voice_gates = gates;

    always_comb begin
        active_voices[0] = |envelope0;
        active_voices[1] = |envelope1;
        active_voices[2] = |envelope2;
        active_voices[3] = |envelope3;
    end
endmodule
