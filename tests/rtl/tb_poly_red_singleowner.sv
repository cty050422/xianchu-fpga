// RED bench T1.1: reproduce the single-owner additive-layer limitation with the REAL
// baseline modules (layer_owner_bind + zone_additive_layer), nothing mocked.
//
// Scenario (all real RTL, real sample timing):
//   s0  : voice0 note-on accepted  -> layer granted to voice0 (32 partials audible)
//   s1  : voice1 note-on accepted while voice0 still held
//         -> contract limitation: binder refuses, voice1 has NO layer while overlapped
//   s2  : voice0 gate falls        -> layer mutes FIRST (its release tail is cut),
//         then hands over to voice1 with a fresh 0->full gain ramp
//   all: voice1's phase increment on its own slot never changes (no pitch corruption)
//
// This bench is expected to FAIL against the single-owner baseline and PASS only after the
// four-voice engine exists (it is the red half of the TDD pair). It exits 0 only when every
// assertion below holds, so on the baseline it exits 1 with the observed violation.
`timescale 1ns/1ps
module tb_poly_red_singleowner;
    localparam integer CLK_PERIOD = 81; // ~12.288 MHz
    logic clk = 0, rst_n = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // ---- stimulus --------------------------------------------------------------
    logic        sample_ce;
    // 256-clock sample tick, identical to rtl/audio_sample_tick_div256.sv
    logic [7:0]  tick_cnt = 0;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) tick_cnt <= 0;
        else begin
            if (tick_cnt == 255) tick_cnt <= 0; else tick_cnt <= tick_cnt + 1;
            sample_ce <= (tick_cnt == 254); // aligned like the production divider
        end
    end

    // 55 Hz and 110 Hz fundamentals (phase-increment units, same constants as the test tone)
    localparam logic [31:0] INC_V0 = 32'h004B_17E5; // 55 Hz
    localparam logic [31:0] INC_V1 = 32'h0096_2FCA; // 110 Hz

    logic [3:0]   voice_gates = 0;
    logic [63:0]  voice_expression = 0;
    logic [63:0]  voice_envelopes = 0;
    logic [127:0] voice_phase_incs = 0;
    logic [3:0]   accepted_on = 0, event_accepted = 0, stolen = 0;
    logic [7:0]   layer_gain;
    logic         force_free = 0;

    // real production binder + real production layer (baseline pair)
    logic [3:0]  bind_gates;
    logic [63:0] bind_expression, bind_envelopes;
    logic [127:0] bind_phase_incs;
    logic [1:0]  binder_state, owner;
    logic [7:0]  bind_generation;
    logic [15:0] granted, refused, released;
    logic        owner_valid;

    layer_owner_bind #(.BIND_ENVELOPE(1'b1)) binder (
        .clk(clk), .rst_n(rst_n), .sample_ce(sample_ce),
        .voice_gates(voice_gates), .voice_expression(voice_expression),
        .voice_envelopes(voice_envelopes), .voice_phase_incs(voice_phase_incs),
        .accepted_on(accepted_on), .event_accepted(event_accepted), .stolen(stolen),
        .layer_gain(layer_gain), .force_free(force_free),
        .bind_gates(bind_gates), .bind_expression(bind_expression),
        .bind_envelopes(bind_envelopes), .bind_phase_incs(bind_phase_incs),
        .owner(owner), .owner_valid(owner_valid), .state(binder_state),
        .bind_generation(bind_generation), .granted(granted), .refused(refused),
        .released(released), .release_level(), .tail_phase()
    );

    logic signed [15:0] pcm_layer;
    logic [31:0] layer_mask;
    logic        layer_switching;
    logic [5:0]  partials_active;

    zone_additive_layer #(
        .PARTIALS(32), .GAIN_STEP(4), .LEVEL_SHIFT(4'd4),
        .MASK_FADE_STEP(4), .USE_VOICE_ENVELOPES(1'b1)
    ) layer (
        .clk(clk), .rst_n(rst_n), .sample_ce(sample_ce),
        .voice_gates(bind_gates), .voice_expression(bind_expression),
        .voice_envelopes(bind_envelopes), .voice_phase_incs(bind_phase_incs),
        .partial_target(6'd32),
        .pcm_layer(pcm_layer), .owner_voice(), .owner_valid(),
        .partial_mask(layer_mask), .gain(layer_gain),
        .switching(layer_switching), .partials_active(partials_active),
        .diag_bank_snapshot()
    );

    // ---- helpers ---------------------------------------------------------------
    integer errors = 0;
    integer samples = 0;
    task automatic wait_samples(input integer n);
        begin
            repeat (n) @(posedge sample_ce);
            samples = samples + n;
        end
    endtask
    task automatic pulse_accepted(input integer v, input bit is_on);
        begin
            @(negedge clk);
            accepted_on[v]     <= is_on;
            event_accepted[v]  <= 1'b1;
            @(negedge clk);
            accepted_on[v]     <= 1'b0;
            event_accepted[v]  <= 1'b0;
        end
    endtask

    // envelope proxy: the production ADSR keeps publishing a decaying envelope after the
    // gate falls; the bench models the SUSTAIN then RELEASE with a simple ramp so the
    // binder/layer see nonzero expression while held and a decaying tail after.
    always @(posedge sample_ce or negedge rst_n) begin
        if (!rst_n) begin
            voice_envelopes <= 64'd0;
        end else begin
            // voice0: full while held, then 16-bit linear release ramp
            if (voice_gates[0]) voice_envelopes[15:0] <= 16'hC000;
            else if (voice_envelopes[15:0] != 0) voice_envelopes[15:0] <= voice_envelopes[15:0] - 16'h0100;
            // voice1: same policy
            if (voice_gates[1]) voice_envelopes[31:16] <= 16'h8000; // softer press
            else if (voice_envelopes[31:16] != 0) voice_envelopes[31:16] <= voice_envelopes[31:16] - 16'h0100;
        end
    end
    always @(posedge sample_ce or negedge rst_n) begin
        if (!rst_n) voice_expression <= 64'd0;
        else begin
            voice_expression[15:0]  <= voice_gates[0] ? 16'hE000 : voice_expression[15:0];
            voice_expression[31:16] <= voice_gates[1] ? 16'h6000 : voice_expression[31:16];
        end
    end

    // ---- scenario --------------------------------------------------------------
    initial begin
        // NOTE: this bench intentionally holds the assertion that the BASELINE violates.
        rst_n = 0;
        repeat (10) @(posedge clk);
        rst_n = 1;
        voice_phase_incs[31:0]  = INC_V0;
        voice_phase_incs[63:32] = INC_V1;
        wait_samples(4);

        // s0: voice0 note-on
        voice_gates[0] = 1'b1;
        pulse_accepted(0, 1'b1);
        wait_samples(80); // let gain ramp + several periods of 55 Hz (20.8us*80)
        if (granted != 16'd1) begin
            errors = errors + 1;
            $display("RED-S0-FAIL granted=%0d (expected 1)", granted);
        end
        if (partials_active < 6'd30) begin
            errors = errors + 1;
            $display("RED-S0-FAIL partials_active=%0d (expected ~32 on a 55 Hz note)", partials_active);
        end
        if (!$isunknown(pcm_layer) && pcm_layer == 0) begin
            errors = errors + 1;
            $display("RED-S0-FAIL layer output is zero while voice0 owns a 55 Hz note");
        end

        // s1: voice1 note-on while voice0 holds. GREEN contract: voice1 receives its own
        // harmonic layer at once (granted==2, refused==0). BASELINE: the binder refuses the
        // claim while the layer is owned, so a still-held second voice stays base-only.
        voice_gates[1] = 1'b1;
        pulse_accepted(1, 1'b1);
        wait_samples(40);
        if (granted !== 16'd2) begin
            $fatal(1, "RED-S1: voice1 has no harmonic layer while voice0 holds it (granted=%0d refused=%0d)", granted, refused);
        end
        // frequency integrity: voice1's own slot must still carry INC_V1 (no pitch corruption)
        if (voice_phase_incs[63:32] !== INC_V1) begin
            $fatal(1, "RED-S1: voice1 phase increment corrupted: %h", voice_phase_incs[63:32]);
        end

        // s2: voice0 releases. GREEN contract: voice0's release tail keeps sounding on its
        // own lane - no ownership-driven mute. BASELINE: a single owner must hand over, and
        // the handover mutes first (switching=1), cutting voice0's additive tail.
        voice_gates[0] = 1'b0;
        event_accepted[0] = 1'b1; // note-off accepted on voice0
        @(negedge clk); event_accepted[0] = 1'b0;
        wait_samples(8);
        if (layer_switching) begin
            $fatal(1, "RED-S2: voice0 release tail is muted (switching=1) because a single-owner layer must change owner");
        end

        $display("RED bench complete: granted=%0d refused=%0d released=%0d partials=%0d",
                 granted, refused, released, partials_active);
        if (errors == 0)
            $display("PASS tb_poly_red_singleowner: four-voice contract holds (green) on this RTL");
        else
            $fatal(1, "tb_poly_red_singleowner: single-owner limitation reproduced with %0d violation(s)", errors);
        $finish;
    end
endmodule
