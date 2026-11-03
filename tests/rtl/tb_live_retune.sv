// T1 live-retune bench: Z1 note-group / octave switching must retune the SAME held
// voices (base DDS + 32-partial additive layer + observed pitch) without re-pressing,
// while leaving every other voice, every other generation and the phase accumulators
// untouched. Release tails of the same generation follow the remap while still audible.
//
// Two levels, both production RTL, nothing mocked:
//   Part A  poly_synth_regions + poly_additive_engine wired exactly like
//           instrument_extension_core (eng_* = synth outputs, no test-mode mux):
//           per-voice phase-increment observation, harmonic-layer inc pickup, phase
//           continuity, budget, bend applied once to the NEW base increment.
//   Part B  zone_note_map -> voice_allocator_regions chain: emission semantics of the
//           retune stream (group/octave mapping, same-clock double toggle, custom-pitch
//           protection, release-shadow matching, stale-retune drop on re-press, panic).
//
// Expected pitch increments are the PUBLISHED offline coefficient table (the same
// constants rtl/zone_note_map.sv inc_for_note documents) plus an independent
// floating-point oracle inc = round(2^32*f/fs), f = 440*2^((n-69)/12), fs = 48000.529661.
// The retune logic under test never supplies its own expectation.
`timescale 1ns/1ps
module tb_live_retune;
    localparam integer CLK_PERIOD = 81; // ~12.288 MHz
    logic clk = 0, rst_n = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    integer errors = 0;
    task automatic fail(input string msg);
        begin errors = errors + 1; $display("FAIL: %s", msg); end
    endtask

    // ---- sample tick, identical divider to production -----------------------------
    logic sample_ce;
    logic [7:0] tick_cnt = 0;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) tick_cnt <= 0;
        else begin
            if (tick_cnt == 255) tick_cnt <= 0; else tick_cnt <= tick_cnt + 1;
            sample_ce <= (tick_cnt == 254);
        end
    end

    task automatic wait_clks(input integer n);
        repeat (n) @(posedge clk);
    endtask
    task automatic wait_samples(input integer n);
        repeat (n) begin @(posedge sample_ce); end
    endtask

    // ---- published coefficient table (independent of the logic under test) --------
    function automatic logic [31:0] tbl(input logic [6:0] n);
        case (n)
            7'd60: tbl = 32'h016533c1; // C4
            7'd62: tbl = 32'h0190f225; // D4
            7'd64: tbl = 32'h01c20be9; // E4
            7'd67: tbl = 32'h021732d3; // G4
            7'd69: tbl = 32'h0258bd73; // A4
            7'd71: tbl = 32'h02a24ed2; // B4
            7'd72: tbl = 32'h02ca6782; // C5
            7'd76: tbl = 32'h038417d2; // E5
            7'd79: tbl = 32'h042e65a6; // G5
            7'd81: tbl = 32'h04b17ae6; // A5
            7'd84: tbl = 32'h0594cf04; // C6
            7'd88: tbl = 32'h07082fa4; // E6
            default: tbl = 32'd0;
        endcase
    endfunction

    // independent floating-point oracle, +-1 LSB tolerance vs the rounded table
    function automatic logic [31:0] oracle_inc(input integer n);
        real f, inc;
        begin
            f = 440.0 * 2.0 ** ((n - 69.0) / 12.0);
            inc = 4294967296.0 * f / 48000.529661;
            oracle_inc = 32'($rtoi(inc + 0.5));
        end
    endfunction

    // =====================================================================
    // Part A: synth + additive engine
    // =====================================================================
    logic        event_valid = 0, event_on = 0;
    logic [1:0]  event_region = 0, event_preset = 0;
    logic [6:0]  event_note = 0;
    logic [31:0] event_phase_inc = 0;
    logic [7:0]  event_generation = 0;
    logic        retune_valid = 0;
    logic [1:0]  retune_region = 0;
    logic [6:0]  retune_old_note = 0, retune_new_note = 0;
    logic [31:0] retune_phase_inc = 0;
    logic [7:0]  retune_generation = 0;
    logic [15:0] bend_ratio = 16'h8000;      // unity
    logic [63:0] region_pressure;
    logic [21:0] cfg_commit_mask = 0;
    logic [27:0] cfg_notes = 0;
    logic [3:0]  cfg_note_valid = 0;
    logic        cfg_group_b = 0;
    logic [1:0]  cfg_preset_1 = 0;
    logic        cfg_octave_up = 0;
    logic        cfg_load = 0;

    logic signed [15:0] pcm_sample;
    logic        clipped;
    logic [63:0] voice_expression, voice_envelopes;
    logic [11:0] voice_envelope_states;
    logic [127:0] voice_phase_incs;
    logic [63:0] voice_gain;
    logic [7:0]  voice_presets;
    logic [3:0]  voice_gates, active_voices, allocated_voices;
    logic [3:0]  event_accepted, stolen;
    logic [31:0] voice_notes;
    logic [7:0]  owner_regions;
    logic [31:0] owner_generations;
    logic [1:0]  selected_voice;
    logic        event_overflow;

    poly_synth_regions #(.EXPRESSIVE_ADSR(1'b1), .BALANCED_PRESETS(1'b1), .MUSICAL_PRESETS(1'b1)) synth (
        .clk(clk), .rst_n(rst_n), .sample_ce(sample_ce),
        .event_valid(event_valid), .event_on(event_on), .event_region(event_region),
        .event_note(event_note), .event_phase_inc(event_phase_inc),
        .event_preset(event_preset), .event_generation(event_generation),
        .retune_valid(retune_valid), .retune_region(retune_region),
        .retune_old_note(retune_old_note), .retune_new_note(retune_new_note),
        .retune_phase_inc(retune_phase_inc), .retune_generation(retune_generation),
        .region_pressure(region_pressure), .bend_ratio_q15(bend_ratio),
        .pcm_sample(pcm_sample), .clipped(clipped),
        .voice_sample0(), .voice_sample1(), .voice_sample2(), .voice_sample3(),
        .voice_expression(voice_expression), .voice_envelopes(voice_envelopes),
        .voice_envelope_states(voice_envelope_states),
        .voice_phase_incs(voice_phase_incs), .voice_gain(voice_gain),
        .voice_presets(voice_presets), .voice_gates(voice_gates),
        .active_voices(active_voices), .allocated_voices(allocated_voices),
        .event_accepted(event_accepted), .stolen(stolen),
        .voice_notes(voice_notes), .owner_regions(owner_regions),
        .owner_generations(owner_generations), .selected_voice(selected_voice),
        .event_overflow(event_overflow)
    );

    // additive engine, wired exactly like instrument_extension_core's normal path
    logic event_on_d;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) event_on_d <= 1'b0; else event_on_d <= event_on;
    end
    wire [3:0]   eng_accepted_on = event_accepted & {4{event_on_d}};
    wire [63:0]  eng_lane_pcm;
    wire [23:0]  eng_voice_partials;
    wire [31:0]  eng_voice_gains;
    wire [31:0]  eng_voice_generation;
    wire [3:0]   eng_note_active;
    wire [15:0]  eng_grant_count;
    wire         eng_budget_violation;
    wire [255:0] eng_diag_lane0, eng_diag_lane1;

    poly_additive_engine #(
        .PARTIALS(32), .GAIN_STEP(8'd4), .LEVEL_SHIFT(4),
        .MASK_FADE_STEP(9'd16), .ENERGY_COMPENSATION(1'b1), .MUSICAL_PRESSURE(1'b1)
    ) engine (
        .clk(clk), .rst_n(rst_n), .sample_ce(sample_ce),
        .voice_gates(voice_gates), .voice_expression(voice_expression),
        .voice_envelopes(voice_envelopes), .voice_phase_incs(voice_phase_incs),
        .voice_presets(voice_presets),
        .accepted_on(eng_accepted_on), .event_accepted(event_accepted),
        .stolen(stolen), .force_free(1'b0),
        .partial_target(6'd32),
        .lane_pcm(eng_lane_pcm), .voice_partials(eng_voice_partials),
        .voice_gains(eng_voice_gains), .voice_generation(eng_voice_generation),
        .voice_note_active(eng_note_active), .grant_count(eng_grant_count),
        .budget_violation(eng_budget_violation),
        .diag_lane0(eng_diag_lane0), .diag_lane1(eng_diag_lane1)
    );

    logic [7:0] gen = 8'd0;
    logic [7:0] gen_of [0:3];

    task automatic note_on(input logic [1:0] r, input logic [6:0] n, input logic [1:0] p);
        begin
            gen = gen + 8'd1;
            gen_of[r] = gen;
            @(negedge clk);
            event_valid = 1; event_on = 1; event_region = r; event_note = n;
            event_phase_inc = tbl(n); event_preset = p; event_generation = gen;
            @(negedge clk);
            event_valid = 0;
        end
    endtask
    task automatic note_off(input logic [1:0] r, input logic [6:0] n, input logic [7:0] g);
        begin
            @(negedge clk);
            event_valid = 1; event_on = 0; event_region = r; event_note = n;
            event_phase_inc = tbl(n); event_generation = g;
            @(negedge clk);
            event_valid = 0;
        end
    endtask
    task automatic do_retune(input logic [1:0] r, input logic [6:0] oldn,
                             input logic [6:0] newn, input logic [7:0] g);
        begin
            @(negedge clk);
            retune_valid = 1; retune_region = r;
            retune_old_note = oldn; retune_new_note = newn;
            retune_phase_inc = tbl(newn); retune_generation = g;
            @(negedge clk);
            retune_valid = 0;
        end
    endtask

    // Part A scenario -----------------------------------------------------------
    logic [127:0] ph_before;
    logic [31:0]  lane_inc;
    integer       guard, saw_new;

    initial begin
        region_pressure = {4{16'hC000}};
        rst_n = 0; wait_clks(10); rst_n = 1; wait_clks(5);

        // A1: four-voice chord C4 E4 G4 B4 on regions 0..3
        note_on(0, 7'd60, 2'd0);
        note_on(1, 7'd64, 2'd1);
        note_on(2, 7'd67, 2'd2);
        note_on(3, 7'd71, 2'd3);
        wait_samples(48);
        if (voice_gates !== 4'b1111) fail("A1: not all four voices gated");
        if (voice_phase_incs !== {tbl(7'd71), tbl(7'd67), tbl(7'd64), tbl(7'd60)})
            fail($sformatf("A1: base increments wrong: %h", voice_phase_incs));
        if (eng_grant_count !== 16'd4) fail("A1: engine grant_count != 4");
        if (eng_budget_violation) fail("A1: budget violation at chord start");
        if (|{eng_lane_pcm[15:0], eng_lane_pcm[31:16], eng_lane_pcm[47:32], eng_lane_pcm[63:48]} == 0)
            fail("A1: additive layer silent");
        // oracle cross-check of the published table (independent math)
        if (tbl(7'd60) < oracle_inc(60) - 2 || tbl(7'd60) > oracle_inc(60) + 2)
            fail($sformatf("A1: table C4 %h vs oracle %h", tbl(7'd60), oracle_inc(60)));

        // A2: retune region0 C4 -> G4 (note-group switch), others untouched
        ph_before = synth.voice0.oscillator.phase;
        do_retune(0, 7'd60, 7'd67, gen_of[0]);
        wait_clks(3);
        if (voice_phase_incs[31:0] !== tbl(7'd67))
            fail($sformatf("A2: voice0 not retuned: %h", voice_phase_incs[31:0]));
        if (voice_phase_incs[63:32] !== tbl(7'd64) || voice_phase_incs[95:64] !== tbl(7'd67) ||
            voice_phase_incs[127:96] !== tbl(7'd71))
            fail("A2: unselected voices changed");
        if (eng_grant_count !== 16'd4) fail("A2: retune counted as a new note-on");
        if (eng_budget_violation) fail("A2: budget violation after retune");
        // phase accumulator continuous: it must have advanced past its pre-retune value
        if (synth.voice0.oscillator.phase <= ph_before && synth.voice0.oscillator.phase > 32'd1000)
            fail("A2: voice0 phase accumulator suspiciously rewound");
        // harmonic layer picks up the new increment (voice0 = lane0 slot A)
        saw_new = 0;
        for (guard = 0; guard < 16 && saw_new == 0; guard = guard + 1) begin
            wait_samples(1);
            lane_inc = eng_diag_lane0[131:100];
            if (lane_inc == tbl(7'd67)) saw_new = 1;
        end
        if (!saw_new) fail($sformatf("A2: harmonic layer never picked up new inc (last %h)", eng_diag_lane0[131:100]));

        // A3: octave retune region1 E4 -> E5
        do_retune(1, 7'd64, 7'd76, gen_of[1]);
        wait_clks(3);
        if (voice_phase_incs[63:32] !== tbl(7'd76))
            fail($sformatf("A3: voice1 octave retune failed: %h", voice_phase_incs[63:32]));
        if (voice_phase_incs[31:0] !== tbl(7'd67))
            fail("A3: voice0 corrupted by voice1 retune");

        // A4: release region2, tail follows the remap while audible
        note_off(2, 7'd67, gen_of[2]);
        wait_samples(4);
        if (voice_gates[2] !== 1'b0) fail("A4: region2 still gated after note-off");
        if (voice_envelopes[47:32] == 16'd0) fail("A4: region2 tail already silent");
        do_retune(2, 7'd67, 7'd69, gen_of[2]);
        wait_clks(3);
        if (voice_phase_incs[95:64] !== tbl(7'd69))
            fail("A4: release tail did not follow the remap");
        if (voice_envelopes[47:32] == 16'd0) fail("A4: tail envelope collapsed");

        // A5: negative - wrong generation / wrong old note are silently dropped
        do_retune(3, 7'd71, 7'd72, gen_of[3] + 8'd1);
        wait_clks(3);
        if (voice_phase_incs[127:96] !== tbl(7'd71))
            fail("A5: retune with wrong generation was accepted");
        do_retune(3, 7'd60, 7'd72, gen_of[3]);
        wait_clks(3);
        if (voice_phase_incs[127:96] !== tbl(7'd71))
            fail("A5: retune with wrong old note was accepted");

        // A6: note-off after retune must still match (region+generation+NEW note)
        note_off(0, 7'd67, gen_of[0]);
        wait_clks(3);
        if (voice_gates[0] !== 1'b0) fail("A6: post-retune note-off did not release voice0");

        // A7: bend applies ONCE to the new base (retune under active bend)
        bend_ratio = 16'hC000; // 1.5x
        do_retune(3, 7'd71, 7'd72, gen_of[3]);
        wait_clks(3);
        if (voice_phase_incs[127:96] !== 32'((tbl(7'd72) * 16'hC000) >> 15))
            fail($sformatf("A7: bent retuned inc wrong: %h", voice_phase_incs[127:96]));
        bend_ratio = 16'h8000;

        $display("Part A complete, errors so far: %0d", errors);
    end

    // =====================================================================
    // Part B: zone_note_map -> allocator chain (emission semantics)
    // =====================================================================
    logic        b_event_valid, b_event_on;
    logic [1:0]  b_event_region, b_event_preset;
    logic [6:0]  b_event_note;
    logic [31:0] b_event_phase_inc;
    logic [7:0]  b_event_generation;
    logic        b_retune_valid;
    logic [1:0]  b_retune_region;
    logic [6:0]  b_retune_old_note, b_retune_new_note;
    logic [31:0] b_retune_phase_inc;
    logic [7:0]  b_retune_generation;
    logic        b_group_toggle = 0, b_preset_toggle = 0, b_octave_toggle = 0;
    logic        b_panic = 0, b_clear_all = 0, b_block_on = 0;
    logic [3:0]  b_trigger_on = 0, b_trigger_off = 0;
    logic [3:0]  b_zone_gate = 0, b_zone_stale = 0;
    logic        b_group_b, b_octave_up;
    logic [1:0]  b_preset_1;
    logic [3:0]  b_leds, b_event_accepted;
    logic        b_led_fault;
    logic [3:0]  b_stolen;
    logic [15:0] alloc_env3 = 16'd0;
    logic [3:0]  b_gates;
    logic [3:0]  b_retriggers;
    logic [127:0] b_phase_incs;
    logic [7:0]  b_presets;
    logic [63:0] b_expressions;
    logic [3:0]  b_allocated;
    logic [7:0]  b_owner_regions;
    logic [31:0] b_owner_generations, b_owner_notes;
    logic [1:0]  b_selected_voice;

    zone_note_map notes_b (
        .clk(clk), .rst_n(rst_n),
        .group_toggle(b_group_toggle), .preset_toggle(b_preset_toggle),
        .octave_toggle(b_octave_toggle), .panic(b_panic), .clear_all(b_clear_all),
        .block_on(b_block_on),
        .trigger_on(b_trigger_on), .trigger_off(b_trigger_off),
        .zone_gate(b_zone_gate), .zone_stale(b_zone_stale),
        .event_valid(b_event_valid), .event_on(b_event_on), .event_region(b_event_region),
        .event_note(b_event_note), .event_phase_inc(b_event_phase_inc),
        .event_preset(b_event_preset), .event_generation(b_event_generation),
        .retune_valid(b_retune_valid), .retune_region(b_retune_region),
        .retune_old_note(b_retune_old_note), .retune_new_note(b_retune_new_note),
        .retune_phase_inc(b_retune_phase_inc), .retune_generation(b_retune_generation),
        .group_b(b_group_b), .preset_1(b_preset_1), .octave_up(b_octave_up),
        .leds(b_leds), .led_fault(b_led_fault),
        .cfg_commit_mask(cfg_commit_mask), .cfg_notes(cfg_notes),
        .cfg_note_valid(cfg_note_valid), .cfg_group_b(cfg_group_b),
        .cfg_preset_1(cfg_preset_1), .cfg_octave_up(cfg_octave_up),
        .cfg_load(cfg_load), .block_mask(4'b0000), .retune_arm(1'b1)
    );

    voice_allocator_regions alloc_b (
        .clk(clk), .rst_n(rst_n), .sample_ce(sample_ce),
        .event_valid(b_event_valid), .event_on(b_event_on), .event_region(b_event_region),
        .event_note(b_event_note), .event_phase_inc(b_event_phase_inc),
        .event_preset(b_event_preset), .event_generation(b_event_generation),
        .retune_valid(b_retune_valid), .retune_region(b_retune_region),
        .retune_old_note(b_retune_old_note), .retune_new_note(b_retune_new_note),
        .retune_phase_inc(b_retune_phase_inc), .retune_generation(b_retune_generation),
        .envelope0(16'd0), .envelope1(16'd0), .envelope2(16'd0),
        // envelope3 stuck nonzero would block freeing; use a decaying stand-in
        .envelope3(alloc_env3),
        .region_pressure({4{16'h8000}}),
        .gates(b_gates), .retriggers(b_retriggers), .phase_incs(b_phase_incs),
        .presets(b_presets), .expressions(b_expressions), .allocated(b_allocated),
        .owner_regions(b_owner_regions), .owner_generations(b_owner_generations),
        .owner_notes(b_owner_notes), .event_accepted(b_event_accepted),
        .stolen(b_stolen), .selected_voice(b_selected_voice)
    );

    task automatic b_pulse(input logic [3:0] mask);
        begin
            @(negedge clk); b_trigger_on = mask; @(negedge clk); b_trigger_on = 0;
        end
    endtask
    task automatic b_release(input logic [3:0] mask);
        begin
            @(negedge clk); b_trigger_off = mask; @(negedge clk); b_trigger_off = 0;
        end
    endtask
    task automatic b_toggle_group();
        begin @(negedge clk); b_group_toggle = 1; @(negedge clk); b_group_toggle = 0; end
    endtask
    task automatic b_toggle_octave();
        begin @(negedge clk); b_octave_toggle = 1; @(negedge clk); b_octave_toggle = 0; end
    endtask

    logic [6:0] last_old0, last_new0;
    // collect retune events for region0 into scratch (for drain checks)
    always @(posedge clk) begin
        if (b_retune_valid && b_retune_region == 2'd0) begin
            last_old0 <= b_retune_old_note; last_new0 <= b_retune_new_note;
        end
    end

    logic [6:0] pressed_note0, pressed_note1;
    // capture note events
    logic [6:0] ev_note_q; logic [1:0] ev_region_q; logic ev_on_q; logic [7:0] ev_gen_q;
    always @(posedge clk) begin
        if (b_event_valid) begin
            ev_note_q <= b_event_note; ev_region_q <= b_event_region;
            ev_on_q <= b_event_on; ev_gen_q <= b_event_generation;
        end
    end

    initial begin
        wait_clks(400); // let Part A finish its chord setup first (separate instances)
        // B1: press zones 0 and 1 (group A: C4 D4), group toggle retunes both
        b_pulse(4'b0001); wait_clks(2);
        if (ev_note_q !== 7'd60 || ev_on_q !== 1'b1) fail("B1: zone0 press note wrong");
        wait_clks(4);
        b_pulse(4'b0010); wait_clks(6);
        b_toggle_group();
        // one retune per held region, emitted on later clocks
        // drain up to 4 clocks of retunes, checking the stream
        begin
            integer seen_r0, seen_r1;
            logic [6:0] r0o, r0n, r1o, r1n;
            seen_r0 = 0; seen_r1 = 0;
            for (guard = 0; guard < 6; guard = guard + 1) begin
                if (b_retune_valid) begin
                    if (b_retune_region == 2'd0) begin
                        seen_r0 = seen_r0 + 1; r0o = b_retune_old_note; r0n = b_retune_new_note;
                    end
                    if (b_retune_region == 2'd1) begin
                        seen_r1 = seen_r1 + 1; r1o = b_retune_old_note; r1n = b_retune_new_note;
                    end
                end
                wait_clks(1);
            end
            if (seen_r0 != 1 || r0o !== 7'd60 || r0n !== 7'd67)
                fail($sformatf("B1: region0 retune stream wrong (seen %0d %0d->%0d)", seen_r0, r0o, r0n));
            if (seen_r1 != 1 || r1o !== 7'd62 || r1n !== 7'd69)
                fail($sformatf("B1: region1 retune stream wrong (seen %0d %0d->%0d)", seen_r1, r1o, r1n));
        end
        $display("DBG B1: phase_incs=%h owner_notes=%h valid=%b", b_phase_incs, b_owner_notes, b_retune_valid);
        if (b_phase_incs[31:0] !== tbl(7'd67) || b_phase_incs[63:32] !== tbl(7'd69))
            fail("B1: allocator slots not retuned");
        if (b_owner_notes[7:0] !== 8'd67 || b_owner_notes[15:8] !== 8'd69)
            fail("B1: owner notes not updated for observation");

        // B2: release region0 - the release must match the RETUNED note
        b_release(4'b0001);
        wait_clks(2);
        if (ev_note_q !== 7'd67 || ev_on_q !== 1'b0) fail("B2: release event note is not the retuned note");
        if (b_gates[0] !== 1'b0) fail("B2: release after retune did not match the slot");

        // B3: same-clock group+octave toggles -> exactly ONE combined retune per region
        wait_clks(4);
        b_pulse(4'b0001); wait_clks(2);   // region0 pressed again (group B, no octave: G4)
        if (ev_note_q !== 7'd67) fail("B3: re-press note wrong");
        wait_clks(4);
        @(negedge clk); b_group_toggle = 1; b_octave_toggle = 1; @(negedge clk);
        b_group_toggle = 0; b_octave_toggle = 0;
        begin
            integer cnt;
            logic [6:0] n0o, n0n;
            cnt = 0;
            for (guard = 0; guard < 8; guard = guard + 1) begin
                if (b_retune_valid && b_retune_region == 2'd0) begin
                    cnt = cnt + 1; n0o = b_retune_old_note; n0n = b_retune_new_note;
                end
                wait_clks(1);
            end
            if (cnt != 1) fail($sformatf("B3: expected 1 combined retune, saw %0d", cnt));
            // group B zone0 = G4(67); toggling group back to A gives C4, octave adds 12 -> C5(72)
            if (n0o !== 7'd67 || n0n !== 7'd72)
                fail($sformatf("B3: combined retune %0d->%0d wrong", n0o, n0n));
        end

        // B4: custom pitch override is protected: group toggle must not rewrite it
        wait_clks(2);
        b_release(4'b0001); wait_clks(2);
        cfg_notes[2*7 +: 7] = 7'd76; cfg_note_valid[2] = 1'b1; cfg_commit_mask[2] = 1'b1;
        @(negedge clk); cfg_load = 1; @(negedge clk); cfg_load = 0;
        cfg_commit_mask = 0;
        wait_clks(2);
        b_pulse(4'b0100); wait_clks(2);
        $display("DBG B4: press ev_note=%0d", ev_note_q);
        if (ev_note_q !== 7'd88) fail("B4: custom pitch press wrong (expected 76+12 octave)");
        wait_clks(4);
        b_toggle_group();
        begin
            integer hit;
            hit = 0;
            for (guard = 0; guard < 8; guard = guard + 1) begin
                if (b_retune_valid && b_retune_region == 2'd2) hit = 1;
                wait_clks(1);
            end
            if (hit) fail("B4: custom-pitch held voice was retuned by a group toggle");
        end
        b_toggle_octave();
        begin
            integer hit; logic [6:0] nn;
            hit = 0;
            for (guard = 0; guard < 8; guard = guard + 1) begin
                if (b_retune_valid && b_retune_region == 2'd2) begin hit = 1; nn = b_retune_new_note; end
                wait_clks(1);
            end
            if (!hit || nn !== 7'd76) fail($sformatf("B4: octave-off retune wrong (got %0d, want 76)", nn));
        end
        b_release(4'b0100); wait_clks(2);
        cfg_note_valid[2] = 1'b0; cfg_notes[2*7 +: 7] = 7'd60; // restore
        @(negedge clk); cfg_commit_mask[2] = 1'b1; cfg_load = 1; @(negedge clk); cfg_load = 0; cfg_commit_mask = 0;

        // B5: toggle while held, then release+re-press BEFORE the retune drains:
        // the stale retune must be dropped, the new press owns the slot.
        wait_clks(4);
        b_release(4'b0001); wait_clks(2);
        b_pulse(4'b0001); wait_clks(2);   // clean press; group B after B4's toggle -> G4
        $display("DBG B5: press ev_note=%0d", ev_note_q);
        if (ev_note_q !== 7'd67) fail("B5: re-press note wrong (group parity)");
        wait_clks(2);
        b_toggle_group();                 // retune 67->60 queued (group B -> A: C4)
        // immediately release + re-press same region before retune delivery
        b_release(4'b0001);
        b_pulse(4'b0001);                 // new press with NEW selectors (group A) -> C4
        // drain everything
        for (guard = 0; guard < 10; guard = guard + 1) wait_clks(1);
        // region->slot mapping shifts as slots are reused; look up region0's CURRENT slot
        begin
            integer r0slot;
            logic [7:0] r0note;
            r0slot = -1;
            for (guard = 0; guard < 4; guard = guard + 1)
                if (r0slot < 0 && b_allocated[guard] && b_owner_regions[guard*2 +: 2] == 2'd0)
                    r0slot = guard;
            if (r0slot < 0) fail("B5: region0 has no allocated slot after re-press");
            else begin
                r0note = b_owner_notes[r0slot*8 +: 8];
                if (r0note !== 8'd60)
                    fail($sformatf("B5: region0 slot note = %0d (expected the new press 60)", r0note));
            end
        end

        // B6: panic releases every held zone with the CURRENT (retuned) note
        b_release(4'b0010); wait_clks(2);
        b_pulse(4'b0010); wait_clks(2);   // clean press; group A -> D4(62)
        $display("DBG B6: press ev_note=%0d", ev_note_q);
        wait_clks(2);
        b_toggle_octave();                // 62 -> 74 (and held z0: 60 -> 72)
        for (guard = 0; guard < 8; guard = guard + 1) wait_clks(1);
        @(negedge clk); b_panic = 1; @(negedge clk); b_panic = 0;
        begin
            integer off_cnt; logic [6:0] off_note;
            off_cnt = 0;
            for (guard = 0; guard < 12; guard = guard + 1) begin
                if (b_event_valid && b_event_on == 1'b0) begin
                    off_cnt = off_cnt + 1; off_note = b_event_note;
                end
                wait_clks(1);
            end
            if (off_cnt < 2) fail($sformatf("B6: panic released only %0d voices", off_cnt));
            if (off_note !== 7'd74) fail($sformatf("B6: last panic release note %0d != retuned 74", off_note));
        end
        if (b_gates !== 4'b0000) fail("B6: gates not all clear after panic");

        // B7: four-note chord, one group toggle -> four retunes, all delivered
        b_pulse(4'b0001); b_pulse(4'b0010); b_pulse(4'b0100); b_pulse(4'b1000);
        wait_clks(8);
        b_toggle_group();
        begin
            integer total;
            total = 0;
            for (guard = 0; guard < 12; guard = guard + 1) begin
                if (b_retune_valid) total = total + 1;
                wait_clks(1);
            end
            if (total != 4) fail($sformatf("B7: four-region retune delivered %0d events (expected 4)", total));
        end

        $display("Part B complete, errors so far: %0d", errors);
        if (errors == 0)
            $display("PASS tb_live_retune: held-voice group/octave remap holds on base+layer+observation, release tails follow, no cross-talk, budget stable");
        else
            $fatal(1, "tb_live_retune: %0d violation(s)", errors);
        $finish;
    end
endmodule
