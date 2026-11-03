// Four-voice 32-partial additive engine: every sounding voice keeps its own harmonic layer.
//
// Target: Tang Mega 60K with NEO Dock; see docs/hardware.md.
//
// REPLACES the single-owner pair (layer_owner_bind + zone_additive_layer) as the additive
// path of the instrument. The old contract gave ONE voice at a time the 32-partial layer:
// a second held note was refused until the owner released, and the handover muted the
// release tail. This engine gives every voice slot its own context, so all four voices can
// carry 32 partials at once and a release tail keeps its own preset to the last sample.
//
// STRUCTURE: two lanes, two voices per lane, three clocks per partial plus
// commit. Both sine interpolation endpoints are packed into one synchronous
// ROM read per lane. Every sample evaluates every harmonic's weighted sine.
// Work is bounded within 224 of the 256 available audio-domain clocks.
//
// PER-VOICE CONTEXT (state bound to the allocated SLOT, not to an FSR):
//   * One independent fundamental phase per voice; harmonic k uses k*phase modulo
//     2^32. This is exact for the original zero-initialized harmonic phase law,
//     including changing base frequency. All 32 sine/weight terms are still computed.
//   * preset latch (2 bit) captured on the voice's accepted NOTE-ON: a preset change
//     affects the next trigger; the held note and its release tail keep their weights.
//   * mask crossfade state (from/to/alpha) per voice, so a J2X brightness change
//     crossfades in every sounding voice independently; fading tail partials keep
//     contributing while alpha moves.
//   * gain ramp (8 bit, GAIN_STEP per sample) toward pressure x envelope x energy
//     compensation. The envelope is the frozen instrument's OWN ADSR output, which keeps
//     decaying after the gate falls, so the release tail is governed by the same envelope
//     as the base voice - there is no second envelope and release is never bypassed. When
//     the allocator steals the slot the new note's envelope restarts the context exactly
//     like the base voice; the layer cannot outlive its voice.
//   * generation counter (8 bit, wraps) incremented on every accepted note-on; commit
//     identity for the observer is (voice, lane, sample counter, generation, valid).
//
// NUMERICS: Q0.8 weights are the PartialGains donor tables (255 = 255/256, never exactly
// 1.0; symmetric truncation keeps an exact zero and never flips a negative partial). The
// per-voice output applies the gain with the donor's explicit shift-and-add chain (no DSP).
// Sums accumulate in 24 bits and saturate; with the shipped weight tables (sum <= 5.2) the
// accumulator cannot overflow. The energy compensation only attenuates and is smoothed
// +-1/256 per sample, so masking cannot click.
//
// BUDGET: a sample_ce arriving while a lane is mid-sample pulses lane_overrun (it cannot
// happen at 48 kHz with the 196-clock schedule; the bench asserts it never fires).
//
// STATUS: RTL simulation tests/rtl/tb_poly_additive_engine.sv against the independent
// integer reference tests/analysis/models/poly_reference.py. Synthesis/PnR reported separately;
// nothing here has been heard on hardware.
module poly_additive_engine #(
    parameter integer PARTIALS         = 32,
    parameter integer GAIN_STEP        = 4,     // gain units per sample over 0..255
    parameter integer MASK_FADE_STEP   = 4,     // 0: delayed hard masks; 4: 64-sample crossfade
    parameter logic [3:0]  LEVEL_SHIFT = 4'd4, // additive bank output scaling
    parameter logic [31:0] NYQUIST_LIMIT = 32'h7000_0000,
    parameter bit          ENERGY_COMPENSATION = 1'b1,
    parameter bit          MUSICAL_PRESSURE    = 1'b1,
    parameter integer      LANES               = 2,  // 2 lanes x 2 voices = 4 voices
    parameter integer      VOICES              = 4,
    parameter bit SINE_INTERPOLATION = 1'b1
) (
    input  logic               clk,
    input  logic               rst_n,
    input  logic               sample_ce,
    // frozen instrument per-voice live interface
    input  logic [3:0]         voice_gates,       // per-voice gate (falls at note-off)
    input  logic [63:0]        voice_expression,  // 4 x 16 pressure
    input  logic [63:0]        voice_envelopes,   // 4 x 16 frozen ADSR (runs in release)
    input  logic [127:0]       voice_phase_incs,  // 4 x 32, bend/vibrato included
    input  logic [7:0]         voice_presets,     // 4 x 2 current preset
    // frozen allocator events (stolen/event_accepted only feed diagnostics: the contexts
    // follow the live slot, whose envelope the base voice shares)
    input  logic [3:0]         accepted_on,       // accepted NOTE-ON pulse per voice
    input  logic [3:0]         event_accepted,
    input  logic [3:0]         stolen,
    input  logic               force_free,        // panic / calibration / fault
    input  logic [5:0]         partial_target,    // J2X brightness, clamped upstream
    // per-voice layer output and status
    output logic [63:0]        lane_pcm,          // voice i signed 16 at [16i +: 16]
    output logic [23:0]        voice_partials,    // voice i partials_active at [6i +: 6]
    output logic [31:0]        voice_gains,       // voice i gain at [8i +: 8]
    output logic [31:0]        voice_generation,  // voice i generation at [8i +: 8]
    output logic [3:0]         voice_note_active, // gate or envelope still sounding
    output logic [15:0]        grant_count,
    output logic               budget_violation,  // any lane was busy at the next sample_ce
    output logic [255:0]       diag_lane0,
    output logic [255:0]       diag_lane1
);
    // ---- per-preset Q0.8 weight tables (PartialGains donor, verbatim values) -----------
    //   0 pluck: 1/k^0.75 scaled 0.80 - 1 wind: odd 1/k^0.8, even ~-20 dB - 2 bell:
    //   1/k^0.45 every 4th -10.5 dB scaled 0.55 - 3 bass: 1/k^1.4, lifted 2nd harmonic
    function automatic logic [255:0] preset_partial_weights(input logic [1:0] preset);
        case (preset)
            2'd0: preset_partial_weights = 256'h0F1010101111121213131415161717181A1B1C1E202224272B30353D485A7ACD;
            2'd1: preset_partial_weights = 256'h0310031103120313041504160418051B051D06210626072C09360B470F6A1AFF;
            2'd2: preset_partial_weights = 256'h091E1E1F092020210A2223240B2526270C2A2B2C0E303234113B3F441756678D;
            default: preset_partial_weights = 256'h020202020203030303030304040404050506060708090A0C0E11151B25378DFF;
        endcase
    endfunction

    // Per-preset prefix-energy compensation (donor table): coefficient(n) =
    // min(256, 256*sqrt(E(2)/E(n))) of the squared Q0.8 weights; attenuates only.
    function automatic logic [8:0] gain_energy_coefficient(
        input logic [1:0] preset, input logic [5:0] n);
        case (preset)
            2'd0: begin
                case (n)
                    6'd3: gain_energy_coefficient = 9'd240;
                    6'd4: gain_energy_coefficient = 9'd231;
                    6'd5: gain_energy_coefficient = 9'd225;
                    6'd6: gain_energy_coefficient = 9'd220;
                    6'd7: gain_energy_coefficient = 9'd217;
                    6'd8: gain_energy_coefficient = 9'd215;
                    6'd9: gain_energy_coefficient = 9'd213;
                    6'd10: gain_energy_coefficient = 9'd211;
                    6'd11: gain_energy_coefficient = 9'd210;
                    6'd12: gain_energy_coefficient = 9'd208;
                    6'd13: gain_energy_coefficient = 9'd207;
                    6'd14: gain_energy_coefficient = 9'd206;
                    6'd15: gain_energy_coefficient = 9'd206;
                    6'd16: gain_energy_coefficient = 9'd205;
                    6'd17: gain_energy_coefficient = 9'd204;
                    6'd18: gain_energy_coefficient = 9'd203;
                    6'd19: gain_energy_coefficient = 9'd203;
                    6'd20: gain_energy_coefficient = 9'd202;
                    6'd21: gain_energy_coefficient = 9'd202;
                    6'd22: gain_energy_coefficient = 9'd201;
                    6'd23: gain_energy_coefficient = 9'd201;
                    6'd24: gain_energy_coefficient = 9'd201;
                    6'd25: gain_energy_coefficient = 9'd200;
                    6'd26: gain_energy_coefficient = 9'd200;
                    6'd27: gain_energy_coefficient = 9'd200;
                    6'd28: gain_energy_coefficient = 9'd199;
                    6'd29: gain_energy_coefficient = 9'd199;
                    6'd30: gain_energy_coefficient = 9'd199;
                    6'd31: gain_energy_coefficient = 9'd199;
                    6'd32: gain_energy_coefficient = 9'd198;
                    default: gain_energy_coefficient = 9'd256;
                endcase
            end
            2'd1: begin
                case (n)
                    6'd3: gain_energy_coefficient = 9'd237;
                    6'd4: gain_energy_coefficient = 9'd236;
                    6'd5: gain_energy_coefficient = 9'd229;
                    6'd6: gain_energy_coefficient = 9'd229;
                    6'd7: gain_energy_coefficient = 9'd225;
                    6'd8: gain_energy_coefficient = 9'd225;
                    6'd9: gain_energy_coefficient = 9'd222;
                    6'd10: gain_energy_coefficient = 9'd222;
                    6'd11: gain_energy_coefficient = 9'd220;
                    6'd12: gain_energy_coefficient = 9'd220;
                    6'd13: gain_energy_coefficient = 9'd219;
                    6'd14: gain_energy_coefficient = 9'd219;
                    6'd15: gain_energy_coefficient = 9'd218;
                    6'd16: gain_energy_coefficient = 9'd218;
                    6'd17: gain_energy_coefficient = 9'd217;
                    6'd18: gain_energy_coefficient = 9'd217;
                    6'd19: gain_energy_coefficient = 9'd216;
                    6'd20: gain_energy_coefficient = 9'd216;
                    6'd21: gain_energy_coefficient = 9'd216;
                    6'd22: gain_energy_coefficient = 9'd216;
                    6'd23: gain_energy_coefficient = 9'd215;
                    6'd24: gain_energy_coefficient = 9'd215;
                    6'd25: gain_energy_coefficient = 9'd215;
                    6'd26: gain_energy_coefficient = 9'd215;
                    6'd27: gain_energy_coefficient = 9'd214;
                    6'd28: gain_energy_coefficient = 9'd214;
                    6'd29: gain_energy_coefficient = 9'd214;
                    6'd30: gain_energy_coefficient = 9'd214;
                    6'd31: gain_energy_coefficient = 9'd214;
                    6'd32: gain_energy_coefficient = 9'd214;
                    default: gain_energy_coefficient = 9'd256;
                endcase
            end
            2'd2: begin
                case (n)
                    6'd3: gain_energy_coefficient = 9'd230;
                    6'd4: gain_energy_coefficient = 9'd228;
                    6'd5: gain_energy_coefficient = 9'd215;
                    6'd6: gain_energy_coefficient = 9'd206;
                    6'd7: gain_energy_coefficient = 9'd199;
                    6'd8: gain_energy_coefficient = 9'd198;
                    6'd9: gain_energy_coefficient = 9'd193;
                    6'd10: gain_energy_coefficient = 9'd189;
                    6'd11: gain_energy_coefficient = 9'd185;
                    6'd12: gain_energy_coefficient = 9'd185;
                    6'd13: gain_energy_coefficient = 9'd182;
                    6'd14: gain_energy_coefficient = 9'd179;
                    6'd15: gain_energy_coefficient = 9'd177;
                    6'd16: gain_energy_coefficient = 9'd176;
                    6'd17: gain_energy_coefficient = 9'd174;
                    6'd18: gain_energy_coefficient = 9'd173;
                    6'd19: gain_energy_coefficient = 9'd171;
                    6'd20: gain_energy_coefficient = 9'd171;
                    6'd21: gain_energy_coefficient = 9'd169;
                    6'd22: gain_energy_coefficient = 9'd168;
                    6'd23: gain_energy_coefficient = 9'd166;
                    6'd24: gain_energy_coefficient = 9'd166;
                    6'd25: gain_energy_coefficient = 9'd165;
                    6'd26: gain_energy_coefficient = 9'd164;
                    6'd27: gain_energy_coefficient = 9'd163;
                    6'd28: gain_energy_coefficient = 9'd163;
                    6'd29: gain_energy_coefficient = 9'd162;
                    6'd30: gain_energy_coefficient = 9'd161;
                    6'd31: gain_energy_coefficient = 9'd160;
                    6'd32: gain_energy_coefficient = 9'd160;
                    default: gain_energy_coefficient = 9'd256;
                endcase
            end
            default: begin
                case (n)
                    6'd3: gain_energy_coefficient = 9'd252;
                    6'd4: gain_energy_coefficient = 9'd250;
                    6'd5: gain_energy_coefficient = 9'd249;
                    6'd6: gain_energy_coefficient = 9'd248;
                    6'd7: gain_energy_coefficient = 9'd248;
                    6'd8: gain_energy_coefficient = 9'd247;
                    6'd9: gain_energy_coefficient = 9'd247;
                    6'd10: gain_energy_coefficient = 9'd247;
                    6'd11: gain_energy_coefficient = 9'd247;
                    6'd12: gain_energy_coefficient = 9'd247;
                    6'd13: gain_energy_coefficient = 9'd247;
                    6'd14: gain_energy_coefficient = 9'd247;
                    6'd15: gain_energy_coefficient = 9'd247;
                    6'd16: gain_energy_coefficient = 9'd247;
                    6'd17: gain_energy_coefficient = 9'd247;
                    6'd18: gain_energy_coefficient = 9'd247;
                    6'd19: gain_energy_coefficient = 9'd247;
                    6'd20: gain_energy_coefficient = 9'd247;
                    6'd21: gain_energy_coefficient = 9'd246;
                    6'd22: gain_energy_coefficient = 9'd246;
                    6'd23: gain_energy_coefficient = 9'd246;
                    6'd24: gain_energy_coefficient = 9'd246;
                    6'd25: gain_energy_coefficient = 9'd246;
                    6'd26: gain_energy_coefficient = 9'd246;
                    6'd27: gain_energy_coefficient = 9'd246;
                    6'd28: gain_energy_coefficient = 9'd246;
                    6'd29: gain_energy_coefficient = 9'd246;
                    6'd30: gain_energy_coefficient = 9'd246;
                    6'd31: gain_energy_coefficient = 9'd246;
                    6'd32: gain_energy_coefficient = 9'd246;
                    default: gain_energy_coefficient = 9'd256;
                endcase
            end
        endcase
    endfunction

    // Same normalized pressure curve as poly_synth_regions (donor musical_layer_gain).
    function automatic logic [7:0] musical_layer_gain(input logic [15:0] pressure);
        logic [17:0] wide;
        logic [15:0] upper, mapped, q15_gain;
        logic [31:0] product;
        begin
            upper = pressure - 16'd32768;
            if (!pressure[15]) begin
                wide   = {2'd0, pressure} + ({2'd0, pressure} << 1);
                mapped = wide[17:2];
            end else begin
                wide   = {2'd0, upper} + ({2'd0, upper} << 2);
                mapped = 16'd24576 + wide[17:2];
            end
            product = {16'd0, mapped} * 32'd28671;
            q15_gain = 16'd4096 + product[31:16];
            musical_layer_gain = q15_gain[14:7];
        end
    endfunction

    // Legacy pressure curve of the old layer, kept for parameter parity.
    function automatic logic [7:0] legacy_layer_gain(input logic [15:0] pressure);
        logic [9:0] sum3;
        begin
            sum3 = {2'd0, pressure[15:8]} + {1'b0, pressure[15:8], 1'b0};
            legacy_layer_gain = 8'd64 + sum3[9:2];
        end
    endfunction

    // Q0.8 weight apply with symmetric truncation (donor apply_gain).
    function automatic logic signed [23:0] apply_gain(
        input logic signed [23:0] value, input logic [7:0] weight);
        logic signed [31:0] product;
        begin
            product = value * $signed({1'b0, weight});
            apply_gain = (product < 0) ? -((-product) >>> 8) : (product >>> 8);
        end
    endfunction

    function automatic logic signed [15:0] saturate16(input logic signed [23:0] value);
        begin
            if (value > 24'sd32767)        saturate16 = 16'sd32767;
            else if (value < -24'sd32768)  saturate16 = -16'sd32768;
            else                           saturate16 = value[15:0];
        end
    endfunction

    // Donor gain stage: each set gain bit contributes one own-constant shift term.
    function automatic logic signed [23:0] gain_scale(
        input logic signed [15:0] bank, input logic [7:0] gain);
        logic signed [23:0] ext, scaled;
        begin
            ext = {{8{bank[15]}}, bank};
            scaled = 24'sd0;
            if (gain[0]) scaled = scaled + (ext >>> 8);
            if (gain[1]) scaled = scaled + (ext >>> 7);
            if (gain[2]) scaled = scaled + (ext >>> 6);
            if (gain[3]) scaled = scaled + (ext >>> 5);
            if (gain[4]) scaled = scaled + (ext >>> 4);
            if (gain[5]) scaled = scaled + (ext >>> 3);
            if (gain[6]) scaled = scaled + (ext >>> 2);
            if (gain[7]) scaled = scaled + (ext >>> 1);
            gain_scale = scaled;
        end
    endfunction

    function automatic logic signed [15:0] clamp16(input logic signed [23:0] value);
        begin
            if (value > 24'sd32767)       clamp16 = 16'sd32767;
            else if (value < -24'sd32768) clamp16 = -16'sd32768;
            else                          clamp16 = value[15:0];
        end
    endfunction

    // ---- per-voice context state ---------------------------------------------------
    logic [1:0]         preset_latch [0:VOICES-1];
    logic [31:0]        fade_from [0:VOICES-1];
    logic [31:0]        fade_to   [0:VOICES-1];
    logic [8:0]         fade_alpha[0:VOICES-1];   // Q0.8, 256 = settled
    logic [8:0]         energy_q8 [0:VOICES-1];
    logic [7:0]         gain_r    [0:VOICES-1];
    logic [5:0]         partials_r[0:VOICES-1];
    logic [7:0]         generation[0:VOICES-1];
    logic signed [15:0] pcm_r     [0:VOICES-1];

    // per-voice gain target chain (live inputs; ramps sample per sample)
    logic [31:0] live_mask   [0:VOICES-1];
    logic [5:0]  n_partials_clamped;
    logic [7:0]  pg_v        [0:VOICES-1];
    logic [23:0] env_product [0:VOICES-1];
    logic [7:0]  env_pg      [0:VOICES-1];
    logic [16:0] energy_product [0:VOICES-1];
    logic [17:0] energy_rounded [0:VOICES-1];
    logic [7:0]  target_gain [0:VOICES-1];
    logic [31:0] frame_inc[0:VOICES-1], frame_from[0:VOICES-1], frame_to[0:VOICES-1];
    logic [8:0] frame_alpha[0:VOICES-1], next_alpha[0:VOICES-1];
    logic [31:0] next_from[0:VOICES-1], next_to[0:VOICES-1];
    logic [7:0] frame_gain[0:VOICES-1], next_gain[0:VOICES-1], frame_gen[0:VOICES-1];
    logic [1:0] frame_preset[0:VOICES-1];

    always_comb begin
        n_partials_clamped = partial_target;
        if (n_partials_clamped < 6'd2)          n_partials_clamped = 6'd2;
        if (n_partials_clamped > PARTIALS[5:0]) n_partials_clamped = PARTIALS[5:0];
        for (integer v = 0; v < VOICES; v = v + 1) begin
            live_mask[v] = (n_partials_clamped >= 6'd32)
                         ? 32'hFFFF_FFFF
                         : ((32'h0000_0001 << n_partials_clamped) - 32'h0000_0001);
            pg_v[v] = MUSICAL_PRESSURE
                    ? musical_layer_gain(voice_expression[v*16 +: 16])
                    : legacy_layer_gain(voice_expression[v*16 +: 16]);
            // 8 x 16 unsigned fits 24 bits; rounding preserves exact zero and the
            // envelope=65535 gain, exactly like the donor layer.
            env_product[v] = {16'd0, pg_v[v]} * {8'd0, voice_envelopes[v*16 +: 16]};
            env_pg[v]      = (env_product[v] + 24'd32768) >> 16;
            energy_product[v] = {8'd0, env_pg[v]} * energy_q8[v];
            energy_rounded[v] = {1'b0, energy_product[v]} + 18'd128;
            target_gain[v] = force_free ? 8'd0
                           : (ENERGY_COMPENSATION ? energy_rounded[v][15:8] : env_pg[v]);
            next_gain[v]=gain_r[v];
            if(voice_envelopes[v*16 +:16]==0)next_gain[v]=0;
            else if(gain_r[v]<target_gain[v])next_gain[v]=((target_gain[v]-gain_r[v])>GAIN_STEP[7:0])?gain_r[v]+GAIN_STEP[7:0]:target_gain[v];
            else if(gain_r[v]>target_gain[v])next_gain[v]=((gain_r[v]-target_gain[v])>GAIN_STEP[7:0])?gain_r[v]-GAIN_STEP[7:0]:target_gain[v];
            next_from[v]=fade_from[v];next_to[v]=fade_to[v];next_alpha[v]=fade_alpha[v];
            if(MASK_FADE_STEP==0)begin next_from[v]=live_mask[v];next_to[v]=live_mask[v];next_alpha[v]=256;end
            else if(fade_alpha[v]==256)begin
              next_from[v]=fade_to[v];
              if(live_mask[v]!=fade_to[v])begin next_to[v]=live_mask[v];next_alpha[v]=0;end
            end else if(256-fade_alpha[v]<=MASK_FADE_STEP)next_alpha[v]=256;
            else next_alpha[v]=fade_alpha[v]+MASK_FADE_STEP[8:0];
        end
    end

    // ---- context bookkeeping (events, preset latch, fade, energy, gain ramps) -------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (integer v = 0; v < VOICES; v = v + 1) begin
                preset_latch[v] <= 2'd0;
                fade_from[v]    <= 32'd0;
                fade_to[v]      <= 32'd0;
                fade_alpha[v]   <= 9'd256;
                energy_q8[v]    <= 9'd256;
                gain_r[v]       <= 8'd0;
                generation[v]   <= 8'd0;
                frame_inc[v]<=0;frame_from[v]<=0;frame_to[v]<=0;frame_alpha[v]<=256;
                frame_gain[v]<=0;frame_gen[v]<=0;frame_preset[v]<=0;
            end
            grant_count      <= 16'd0;
        end else begin
            for (integer v = 0; v < VOICES; v = v + 1) begin
                if (accepted_on[v]) begin
                    preset_latch[v] <= voice_presets[v*2 +: 2];
                    generation[v]   <= generation[v] + 8'd1;
                end
                if (sample_ce) begin
                    // mask crossfade state advances once per sample, per voice
                    if (MASK_FADE_STEP == 0) begin
                        fade_from[v]  <= live_mask[v];
                        fade_to[v]    <= live_mask[v];
                        fade_alpha[v] <= 9'd256;
                    end else if (fade_alpha[v] == 9'd256) begin
                        fade_from[v] <= fade_to[v];
                        if (live_mask[v] != fade_to[v]) begin
                            fade_to[v]    <= live_mask[v];
                            fade_alpha[v] <= 9'd0;
                        end
                    end else if ((9'd256 - fade_alpha[v]) <= MASK_FADE_STEP[8:0]) begin
                        fade_alpha[v] <= 9'd256;
                    end else begin
                        fade_alpha[v] <= fade_alpha[v] + MASK_FADE_STEP[8:0];
                    end
                    // energy compensation follows the LAST finished sample's partial count
                    if (energy_q8[v] < gain_energy_coefficient(preset_latch[v], partials_r[v]))
                        energy_q8[v] <= energy_q8[v] + 9'd1;
                    else if (energy_q8[v] > gain_energy_coefficient(preset_latch[v], partials_r[v]))
                        energy_q8[v] <= energy_q8[v] - 9'd1;
                    // per-voice gain ramp toward this sample's target
                    gain_r[v]<=next_gain[v];
                    frame_inc[v]<=voice_phase_incs[v*32 +:32];
                    frame_from[v]<=next_from[v];frame_to[v]<=next_to[v];frame_alpha[v]<=next_alpha[v];
                    frame_gain[v]<=next_gain[v];
                    frame_gen[v]<=generation[v]+(accepted_on[v]?8'd1:8'd0);
                    frame_preset[v]<=accepted_on[v]?voice_presets[v*2 +:2]:preset_latch[v];
                end
            end
            if(|accepted_on) grant_count<=grant_count+{15'd0,accepted_on[0]}+{15'd0,accepted_on[1]}+{15'd0,accepted_on[2]}+{15'd0,accepted_on[3]};
        end
    end

    always_comb begin
        for (integer v = 0; v < VOICES; v = v + 1) begin
            voice_note_active[v] = voice_gates[v] || (|voice_envelopes[v*16 +: 16]);
            lane_pcm[16*v +: 16] = pcm_r[v];
            voice_partials[6*v +: 6] = partials_r[v];
            voice_gains[8*v +: 8]    = gain_r[v];
            voice_generation[8*v +: 8] = generation[v];
        end
    end

    // ---- compute lanes --------------------------------------------------------------
    logic        lane_overrun [0:LANES-1];
    logic [255:0] lane_diag   [0:LANES-1];
    logic [15:0]  sample_counter;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) sample_counter <= 16'd0;
        else if (sample_ce) sample_counter <= sample_counter + 16'd1;
    end

    generate
        for (genvar l = 0; l < LANES; l = l + 1) begin : g_lane
            localparam integer V_A = l * 2;      // first voice of this lane
            localparam integer V_B = l * 2 + 1;  // second voice of this lane

            logic               slot_active;
            logic               slot_sel;         // 0 = V_A, 1 = V_B
            logic [5:0]         step;
            logic [15:0] frame_tag;
            logic [1:0]         run_state;        // 0 phase/rom, 1 gain-mul, 2 accumulate, 3 commit
            logic [31:0]        inc_latch;
            logic [31:0]        inc_running;
            logic [255:0]       weight_latch;
            logic               guard_closed;
            logic [5:0]         used_count;
            logic signed [23:0] acc;
            logic signed [23:0] acc_from, acc_to;
            logic signed [24:0] blend_delta;
            logic signed [34:0] blend_product;
            logic signed [23:0] scaled_partial;
            // Exact state compression: with zero-initialized harmonic phases,
            // phi[k] == k*phi[1] modulo 2^32 even when base_inc changes per frame.
            // Keep an independent fundamental phase for EACH voice; calculate all
            // 32 sine/weight terms separately. No oscillator/partial is skipped.
            logic [31:0]        phase_a, phase_b;
            logic [31:0]        phase_basis, phase_work;
            logic [9:0]         rom_index;
            logic signed [15:0] rom_value;
            logic [31:0] rom_pair;
            logic rom_negative;
            logic signed [15:0] rom_first, rom_next;
            logic signed [16:0] rom_delta;
            logic signed [25:0] interp_product;
            logic signed [26:0] interp_value;
            logic signed [23:0] rom_ext;
            logic [7:0]         weight_sel;
            logic               use_step;
            logic [31:0]        cur_phase;
            logic [31:0]        cur_from, cur_to;
            logic [8:0]         cur_alpha;
            logic [1:0]         cur_voice;
            logic signed [15:0] bank_sample;
            logic signed [23:0] bank_ext, scaled_out;

            always_comb begin
                cur_voice  = slot_sel ? V_B[1:0] : V_A[1:0];
                cur_phase  = phase_work;
                cur_from   = slot_sel ? frame_from[V_B] : frame_from[V_A];
                cur_to     = slot_sel ? frame_to[V_B]   : frame_to[V_A];
                cur_alpha  = slot_sel ? frame_alpha[V_B] : frame_alpha[V_A];
                rom_index  = cur_phase[31:22];
                rom_first=rom_negative?-$signed(rom_pair[15:0]):$signed(rom_pair[15:0]);
                rom_next=rom_negative?-$signed(rom_pair[31:16]):$signed(rom_pair[31:16]);
                rom_delta=$signed({rom_next[15],rom_next})-$signed({rom_first[15],rom_first});
                interp_product=rom_delta*$signed({1'b0,cur_phase[21:14]});
                interp_value=$signed({{11{rom_first[15]}},rom_first})+(interp_product>>>8);
                rom_value=SINE_INTERPOLATION?interp_value[15:0]:rom_first;
                rom_ext    = {{8{rom_value[15]}}, rom_value};
                weight_sel = weight_latch[step*8 +: 8];
                use_step   = ((MASK_FADE_STEP == 0)
                                ? cur_to[step]
                                : (((cur_alpha != 9'd256) && cur_from[step]) ||
                                   ((cur_alpha != 9'd0)   && cur_to[step])))
                             && !guard_closed && (inc_running < NYQUIST_LIMIT);
            end

            // Half-wave symmetry packs both interpolation endpoints into one
            // 512x32 ROM (one 18K block), with the sign registered beside it.
            sine_pair_rom lane_sine_rom(.clk(clk),.index(cur_phase[30:22]),.pair(rom_pair));
            always_ff@(posedge clk)rom_negative<=cur_phase[31];

            always_comb begin
                blend_delta=$signed({acc_to[23],acc_to})-$signed({acc_from[23],acc_from});
                blend_product=blend_delta*$signed({1'b0,cur_alpha});
                acc=acc_from+(blend_product>>>8);
                bank_sample = saturate16(acc >>> LEVEL_SHIFT);
                bank_ext    = {{8{bank_sample[15]}}, bank_sample};
                scaled_out  = gain_scale(bank_sample, slot_sel ? frame_gain[V_B] : frame_gain[V_A]);
            end

            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    frame_tag<=0;
                    slot_active    <= 1'b0;
                    slot_sel       <= 1'b0;
                    step           <= 6'd0;
                    run_state      <= 2'd0;
                    inc_latch      <= 32'd0;
                    inc_running    <= 32'd0;
                    weight_latch   <= 256'd0;
                    guard_closed   <= 1'b0;
                    used_count     <= 6'd0;
                    acc_from       <= 0;acc_to<=0;
                    scaled_partial <= 24'sd0;
                    lane_overrun[l]<= 1'b0;
                    pcm_r[V_A]      <= 16'sd0;
                    pcm_r[V_B]      <= 16'sd0;
                    partials_r[V_A] <= 6'd0;
                    partials_r[V_B] <= 6'd0;
                    phase_a <= 0; phase_b <= 0;
                    phase_basis <= 0; phase_work <= 0;
                end else begin
                    lane_overrun[l] <= 1'b0;
                    if(sample_ce)frame_tag<=sample_counter;
                    if (!slot_active) begin
                        // Both lanes start on the same sample_ce; each has its own
                        // paired-endpoint sine ROM. No unsupported ROM sharing claim.
                        if (sample_ce) begin
                            slot_active <= 1'b1;
                            slot_sel    <= 1'b0;
                            step        <= 6'd0;
                            run_state   <= 2'd0;
                            inc_latch   <= voice_phase_incs[V_A*32 +: 32];
                            inc_running <= voice_phase_incs[V_A*32 +: 32];
                            guard_closed<= (voice_phase_incs[V_A*32 +: 32] >= NYQUIST_LIMIT);
                            used_count  <= 6'd0;
                            acc_from<=0;acc_to<=0;
                            weight_latch<= preset_partial_weights(preset_latch[V_A]);
                            phase_basis <= phase_a;
                            phase_work  <= phase_a;
                            phase_a     <= phase_a + voice_phase_incs[V_A*32 +: 32];
                        end
                    end else begin
                        if (sample_ce && (run_state != 2'd3 || slot_sel == 1'b0))
                            lane_overrun[l] <= 1'b1;
                        case (run_state)
                            2'd0: begin // phase advance (registered) + ROM read (registered)
                                run_state <= 2'd1;
                            end
                            2'd1: begin // ROM value settled: shared Q0.8 weight multiply
                                scaled_partial <= apply_gain(rom_ext, weight_sel);
                                run_state      <= 2'd2;
                            end
                            2'd2: begin // accumulate and step
                                if(!guard_closed && inc_running<NYQUIST_LIMIT)begin
                                  if(cur_from[step])acc_from<=acc_from+scaled_partial;
                                  if(cur_to[step])acc_to<=acc_to+scaled_partial;
                                end
                                guard_closed <= guard_closed || (inc_running >= NYQUIST_LIMIT);
                                if (use_step) used_count <= used_count + 6'd1;
                                if (step == PARTIALS[5:0] - 6'd1) begin
                                    run_state <= 2'd3;
                                end else begin
                                    step        <= step + 6'd1;
                                    inc_running <= inc_running + inc_latch;
                                    phase_work  <= phase_work + phase_basis;
                                    run_state   <= 2'd0;
                                end
                            end
                            default: begin // 2'd3: commit this voice; switch or finish
                                if (slot_sel == 1'b0) begin
                                    pcm_r[V_A]      <= clamp16(scaled_out);
                                    partials_r[V_A] <= used_count;
                                    // switch to the lane's second voice
                                    slot_sel    <= 1'b1;
                                    step        <= 6'd0;
                                    run_state   <= 2'd0;
                                    inc_latch   <= frame_inc[V_B];
                                    inc_running <= frame_inc[V_B];
                                    guard_closed<= (frame_inc[V_B] >= NYQUIST_LIMIT);
                                    used_count  <= 6'd0;
                                    acc_from<=0;acc_to<=0;
                                    weight_latch<= preset_partial_weights(frame_preset[V_B]);
                                    phase_basis <= phase_b;
                                    phase_work  <= phase_b;
                                    phase_b     <= phase_b + frame_inc[V_B];
                                end else begin
                                    pcm_r[V_B]      <= clamp16(scaled_out);
                                    partials_r[V_B] <= used_count;
                                    slot_active     <= 1'b0;
                                    run_state       <= 2'd0;
                                end
                            end
                        endcase
                    end
                end
            end

            // GAO model 0x52: one explicitly selected lane per sample frame.
            always_comb begin
                lane_diag[l]=0;
                lane_diag[l][2:0]={1'b0,run_state};lane_diag[l][3]=slot_active;
                lane_diag[l][4]=slot_sel;lane_diag[l][5]=guard_closed;
                lane_diag[l][6]=sample_ce;lane_diag[l][7]=lane_overrun[l];
                lane_diag[l][13:8]=step;lane_diag[l][19:14]=used_count;
                lane_diag[l][43:20]=scaled_partial;lane_diag[l][67:44]=acc;
                lane_diag[l][99:68]=inc_running;lane_diag[l][131:100]=inc_latch;
                lane_diag[l][147:132]=frame_tag;
                lane_diag[l][155:148]=slot_sel?frame_gen[V_B]:frame_gen[V_A];
                lane_diag[l][173:156]=cur_phase[31:14];
                lane_diag[l][189:174]=rom_value;lane_diag[l][197:190]=weight_sel;
                lane_diag[l][205:198]=slot_sel?frame_gain[V_B]:frame_gain[V_A];
                lane_diag[l][214:206]=cur_alpha;lane_diag[l][238:215]=scaled_out;
                lane_diag[l][240:239]=cur_voice;lane_diag[l][241]=l[0];
                lane_diag[l][243:242]=slot_sel?frame_preset[V_B]:frame_preset[V_A];
                lane_diag[l][244]=cur_from[step];lane_diag[l][245]=cur_to[step];
                lane_diag[l][246]=use_step;lane_diag[l][247]=slot_active && run_state==3;
                lane_diag[l][255:248]=8'h52;
            end
        end
    endgenerate

    always_comb begin
        budget_violation = lane_overrun[0] || lane_overrun[1];
        diag_lane0 = lane_diag[0];
        diag_lane1 = lane_diag[1];
    end
endmodule
