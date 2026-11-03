module voice_core #(
    parameter bit CURVED_DECAY_RELEASE = 1'b0,
    parameter bit CONTINUOUS_RETRIGGER = 1'b0,
    parameter integer CURVE_SHIFT = 9,
    parameter bit CURVE_ERROR_FEEDBACK = 1'b0,
    parameter bit SPECTRAL_GUARD = 1'b0
) (
    input  logic               clk,
    input  logic               rst_n,
    input  logic               sample_ce,
    input  logic               gate,
    input  logic               retrigger,
    input  logic [1:0]         waveform,
    input  logic [31:0]        phase_inc,
    input  logic [15:0]        modulation_index,
    input  logic [1:0]         pm_ratio_mode, // 0=legacy 2:1; 1=7:2; 2=1:1
    input  logic [15:0]        attack_step,
    input  logic [15:0]        decay_step,
    input  logic [15:0]        sustain_level,
    input  logic [15:0]        release_step,
    output logic signed [15:0] sample,
    output logic [15:0]        envelope_debug,
    output logic [2:0]         envelope_state_debug
);
    logic signed [15:0] oscillator_sample;
    logic signed [15:0] basic_sample;
    logic signed [15:0] phase_mod_sample;
    logic [8:0] phase_mod_mix;
    logic signed [16:0] blend_delta;
    logic signed [26:0] blend_product;
    logic signed [26:0] blended_sample;
    logic [15:0] envelope_level;
    logic signed [32:0] scaled_product;
    logic [1:0] basic_waveform;

    // Algorithm select 3 means PM, not a fourth DDS waveform. Keep the
    // triangle reference path alive so both crossfade endpoints remain valid.
    assign basic_waveform = (waveform == 2'd3) ? 2'd2 : waveform;

    dds_oscillator #(.HIGH_NOTE_SMOOTHING(SPECTRAL_GUARD)) oscillator (
        .clk, .rst_n, .sample_ce, .waveform(basic_waveform), .phase_inc,
        .sample(basic_sample), .phase_debug()
    );

    phase_mod_oscillator #(.SPECTRAL_GUARD(SPECTRAL_GUARD)) phase_modulator (
        .clk, .rst_n, .sample_ce,
        .carrier_phase_inc(phase_inc), .modulation_index, .pm_ratio_mode,
        .sample(phase_mod_sample)
    );

    adsr_envelope #(
        .CURVED_DECAY_RELEASE(CURVED_DECAY_RELEASE),.CURVE_SHIFT(CURVE_SHIFT),
        .CONTINUOUS_RETRIGGER(CONTINUOUS_RETRIGGER),
        .CURVE_ERROR_FEEDBACK(CURVE_ERROR_FEEDBACK)
    ) envelope (
        .clk, .rst_n, .sample_ce, .gate, .retrigger,
        .attack_step, .decay_step, .sustain_level, .release_step,
        .level(envelope_level), .state(envelope_state_debug)
    );

    // Crossfade over 32 sample enables (about 0.67 ms at 48 kHz) so the
    // board's algorithm-select key does not hard-switch unrelated phases.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            phase_mod_mix <= '0;
        else if (sample_ce) begin
            if (waveform == 2'd3) begin
                if (phase_mod_mix >= 9'd248)
                    phase_mod_mix <= 9'd256;
                else
                    phase_mod_mix <= phase_mod_mix + 9'd8;
            end else begin
                if (phase_mod_mix <= 9'd8)
                    phase_mod_mix <= '0;
                else
                    phase_mod_mix <= phase_mod_mix - 9'd8;
            end
        end
    end

    always_comb begin
        blend_delta = $signed({phase_mod_sample[15], phase_mod_sample}) -
                      $signed({basic_sample[15], basic_sample});
        blend_product = blend_delta * $signed({1'b0, phase_mod_mix});
        blended_sample = $signed({{11{basic_sample[15]}}, basic_sample}) +
                         (blend_product >>> 8);
        oscillator_sample = blended_sample[15:0];
        scaled_product = oscillator_sample * $signed({1'b0, envelope_level});
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            sample <= '0;
        else if (sample_ce)
            sample <= scaled_product[31:16];
    end

    assign envelope_debug = envelope_level;
endmodule
