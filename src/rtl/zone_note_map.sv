// Zone triggers to note events, with note groups, preset and octave selection (M2/M4).
//
// The panel keys change what the NEXT note will be; they never change a note that is already
// sounding. That is enforced structurally: the note, preset and generation of a press are
// LATCHED per region at note-on, and the release event is built from those latched values,
// so releasing a key after switching groups still releases the original note (charter 4.2).
//
// Two note groups are implemented as the design baseline:
//   group A: C4 D4 E4 G4   (60 62 64 67)
//   group B: G4 A4 B4 C5   (67 69 71 72)
// plus one octave switch (+12 semitones, i.e. the C5..C6 range). The reachable range is
// C3..C6, which is the range the charter limits the design to before pitch bend.
//
// Phase increments come from a 12-entry table for C4..B4 plus an exact power-of-two octave
// shift. The table values are computed offline from the board's real sample rate
// (48000.529661 Hz) - they are coefficients, not recorded material.
module zone_note_map #(
    parameter logic ENABLE_PROTECTION = 1'b0
) (
    input  logic        clk,
    input  logic        rst_n,
    // Panel keys as one-clock pulses (synchronised and debounced outside).
    input  logic        group_toggle,
    input  logic        preset_toggle,
    input  logic        octave_toggle,
    input  logic        panic,          // all-notes-off: releases every held zone
    input  logic        clear_all,
    input  logic        block_on,
    // Zone state from rtl/zone_bank.sv
    input  logic [3:0]  trigger_on,     // one-clock pulse per zone press
    input  logic [3:0]  trigger_off,    // one-clock pulse per zone release
    input  logic [3:0]  zone_gate,      // held state, used for the LEDs
    input  logic [3:0]  zone_stale,     // channel stopped delivering samples
    // Note events (at most one per clock, releases first)
    output logic        event_valid,
    output logic        event_on,
    output logic [1:0]  event_region,
    output logic [6:0]  event_note,
    output logic [31:0] event_phase_inc,
    output logic [1:0]  event_preset,
    output logic [7:0]  event_generation,
    // T1 live retune stream: when the note-group or octave selector changes (panel
    // gesture or a committed config field), every HELD region whose pitch the change
    // affects emits one retune event {region, old note, new note, inc, generation}.
    // The release bookkeeping (latched_note) is rewritten only at DELIVERY, so a
    // release racing a queued retune still carries the note the allocator currently
    // holds and can never strand a voice. Re-pressing a region drops its stale retune.
    // retune_arm=0 (demo takeover) freezes the whole mechanism: no enqueue, no
    // delivery, no latched_note rewrite, so manual state stays consistent with the
    // synth the demo is driving.
    output logic        retune_valid,
    output logic [1:0]  retune_region,
    output logic [6:0]  retune_old_note,
    output logic [6:0]  retune_new_note,
    output logic [31:0] retune_phase_inc,
    output logic [7:0]  retune_generation,
    input  logic        retune_arm = 1'b1,
    // Panel state and indicators
    output logic        group_b,
    output logic [1:0] preset_1,
    output logic        octave_up,
    output logic [3:0]  leds,
    output logic        led_fault,
    // Configuration consumers (S02). All of them are "next note" selectors: a
    // commit never changes a note that is already sounding, because every press
    // latches its note/preset/generation and the release rebuilds from the latch.
    //   cfg_load is a one-clock strobe (config_session apply_strobe); only the
    //   fields present in cfg_commit_mask are loaded, so a threshold-only commit
    //   cannot rewind a selector the player moved with a panel gesture.
    //   A group_toggle gesture returns to the note-group TABLE and therefore
    //   clears the custom per-zone pitch overrides: the gesture table stays the
    //   documented escape hatch away from a remotely configured mapping.
    input  logic [21:0] cfg_commit_mask,   // bit i = field id i+1 carried by the commit
    input  logic [27:0] cfg_notes,         // {zone3,zone2,zone1,zone0} x 7 bits
    input  logic [3:0]  cfg_note_valid,    // zone has a committed custom pitch
    input  logic        cfg_group_b,
    input  logic [1:0] cfg_preset_1,
    input  logic        cfg_octave_up,
    input  logic        cfg_load,
    // Guide/challenge gate (S05): bit i set suppresses NEW note-ons of zone i
    // (wrong FSR in guided practice). Note-offs always pass, so a wrong press
    // can never strand a sounding note; the physical press still lights the
    // zone LED, which is what the guide counts as a visible wrong event.
    input  logic [3:0]  block_mask
);
    // C4..B4 phase increments for 48000.529661 Hz. inc(note) = round(2^32 * f/fs).
    function automatic logic [31:0] inc_for_note(input logic [6:0] note);
        // Exact offline expansion of the former /12, %12 and variable octave shift.
        // Coefficients are unchanged; this is a lookup, not recorded sound.
        case(note)
            7'd0: inc_for_note=32'h00594cf0;
            7'd1: inc_for_note=32'h00594cf0;
            7'd2: inc_for_note=32'h00594cf0;
            7'd3: inc_for_note=32'h00594cf0;
            7'd4: inc_for_note=32'h00594cf0;
            7'd5: inc_for_note=32'h00594cf0;
            7'd6: inc_for_note=32'h00594cf0;
            7'd7: inc_for_note=32'h00594cf0;
            7'd8: inc_for_note=32'h00594cf0;
            7'd9: inc_for_note=32'h00594cf0;
            7'd10: inc_for_note=32'h00594cf0;
            7'd11: inc_for_note=32'h00594cf0;
            7'd12: inc_for_note=32'h00594cf0;
            7'd13: inc_for_note=32'h00594cf0;
            7'd14: inc_for_note=32'h00594cf0;
            7'd15: inc_for_note=32'h00594cf0;
            7'd16: inc_for_note=32'h00594cf0;
            7'd17: inc_for_note=32'h00594cf0;
            7'd18: inc_for_note=32'h00594cf0;
            7'd19: inc_for_note=32'h00594cf0;
            7'd20: inc_for_note=32'h00594cf0;
            7'd21: inc_for_note=32'h00594cf0;
            7'd22: inc_for_note=32'h00594cf0;
            7'd23: inc_for_note=32'h00594cf0;
            7'd24: inc_for_note=32'h00594cf0;
            7'd25: inc_for_note=32'h00594cf0;
            7'd26: inc_for_note=32'h00594cf0;
            7'd27: inc_for_note=32'h00594cf0;
            7'd28: inc_for_note=32'h00594cf0;
            7'd29: inc_for_note=32'h00594cf0;
            7'd30: inc_for_note=32'h00594cf0;
            7'd31: inc_for_note=32'h00594cf0;
            7'd32: inc_for_note=32'h00594cf0;
            7'd33: inc_for_note=32'h00594cf0;
            7'd34: inc_for_note=32'h00594cf0;
            7'd35: inc_for_note=32'h00594cf0;
            7'd36: inc_for_note=32'h00594cf0;
            7'd37: inc_for_note=32'h005e9c52;
            7'd38: inc_for_note=32'h00643c89;
            7'd39: inc_for_note=32'h006a3264;
            7'd40: inc_for_note=32'h007082fa;
            7'd41: inc_for_note=32'h007733b1;
            7'd42: inc_for_note=32'h007e4a3f;
            7'd43: inc_for_note=32'h0085ccb4;
            7'd44: inc_for_note=32'h008dc17a;
            7'd45: inc_for_note=32'h00962f5c;
            7'd46: inc_for_note=32'h009f1d8f;
            7'd47: inc_for_note=32'h00a893b4;
            7'd48: inc_for_note=32'h00b299e0;
            7'd49: inc_for_note=32'h00bd38a4;
            7'd50: inc_for_note=32'h00c87912;
            7'd51: inc_for_note=32'h00d464c8;
            7'd52: inc_for_note=32'h00e105f4;
            7'd53: inc_for_note=32'h00ee6762;
            7'd54: inc_for_note=32'h00fc947f;
            7'd55: inc_for_note=32'h010b9969;
            7'd56: inc_for_note=32'h011b82f4;
            7'd57: inc_for_note=32'h012c5eb9;
            7'd58: inc_for_note=32'h013e3b1f;
            7'd59: inc_for_note=32'h01512769;
            7'd60: inc_for_note=32'h016533c1;
            7'd61: inc_for_note=32'h017a7148;
            7'd62: inc_for_note=32'h0190f225;
            7'd63: inc_for_note=32'h01a8c990;
            7'd64: inc_for_note=32'h01c20be9;
            7'd65: inc_for_note=32'h01dccec4;
            7'd66: inc_for_note=32'h01f928ff;
            7'd67: inc_for_note=32'h021732d3;
            7'd68: inc_for_note=32'h023705e9;
            7'd69: inc_for_note=32'h0258bd73;
            7'd70: inc_for_note=32'h027c763f;
            7'd71: inc_for_note=32'h02a24ed2;
            7'd72: inc_for_note=32'h02ca6782;
            7'd73: inc_for_note=32'h02f4e290;
            7'd74: inc_for_note=32'h0321e44a;
            7'd75: inc_for_note=32'h03519320;
            7'd76: inc_for_note=32'h038417d2;
            7'd77: inc_for_note=32'h03b99d88;
            7'd78: inc_for_note=32'h03f251fe;
            7'd79: inc_for_note=32'h042e65a6;
            7'd80: inc_for_note=32'h046e0bd2;
            7'd81: inc_for_note=32'h04b17ae6;
            7'd82: inc_for_note=32'h04f8ec7e;
            7'd83: inc_for_note=32'h05449da4;
            7'd84: inc_for_note=32'h0594cf04;
            7'd85: inc_for_note=32'h05e9c520;
            7'd86: inc_for_note=32'h0643c894;
            7'd87: inc_for_note=32'h06a32640;
            7'd88: inc_for_note=32'h07082fa4;
            7'd89: inc_for_note=32'h07733b10;
            7'd90: inc_for_note=32'h07e4a3fc;
            7'd91: inc_for_note=32'h085ccb4c;
            7'd92: inc_for_note=32'h08dc17a4;
            7'd93: inc_for_note=32'h0962f5cc;
            7'd94: inc_for_note=32'h09f1d8fc;
            7'd95: inc_for_note=32'h0a893b48;
            7'd96: inc_for_note=32'h0b299e08;
            7'd97: inc_for_note=32'h0bd38a40;
            7'd98: inc_for_note=32'h0c879128;
            7'd99: inc_for_note=32'h0d464c80;
            7'd100: inc_for_note=32'h0e105f48;
            7'd101: inc_for_note=32'h0ee67620;
            7'd102: inc_for_note=32'h0fc947f8;
            7'd103: inc_for_note=32'h10b99698;
            7'd104: inc_for_note=32'h11b82f48;
            7'd105: inc_for_note=32'h12c5eb98;
            7'd106: inc_for_note=32'h13e3b1f8;
            7'd107: inc_for_note=32'h15127690;
            7'd108: inc_for_note=32'h16533c10;
            7'd109: inc_for_note=32'h16533c10;
            7'd110: inc_for_note=32'h16533c10;
            7'd111: inc_for_note=32'h16533c10;
            7'd112: inc_for_note=32'h16533c10;
            7'd113: inc_for_note=32'h16533c10;
            7'd114: inc_for_note=32'h16533c10;
            7'd115: inc_for_note=32'h16533c10;
            7'd116: inc_for_note=32'h16533c10;
            7'd117: inc_for_note=32'h16533c10;
            7'd118: inc_for_note=32'h16533c10;
            7'd119: inc_for_note=32'h16533c10;
            7'd120: inc_for_note=32'h16533c10;
            7'd121: inc_for_note=32'h16533c10;
            7'd122: inc_for_note=32'h16533c10;
            7'd123: inc_for_note=32'h16533c10;
            7'd124: inc_for_note=32'h16533c10;
            7'd125: inc_for_note=32'h16533c10;
            7'd126: inc_for_note=32'h16533c10;
            7'd127: inc_for_note=32'h16533c10;
            default: inc_for_note=32'd0;
        endcase
    endfunction

    logic group_b_r, octave_up_r;
    logic [1:0] preset_1_r;
    logic [3:0]  note_override_r;      // zone has a committed custom pitch
    logic [27:0] custom_note_r;        // {zone3,zone2,zone1,zone0} x 7 bits
    // Packed instead of unpacked arrays, so every simulator in the regression can index them.
    logic [27:0] latched_note;        // 4 x 7 bits
    logic [7:0] latched_preset;
    logic [31:0] latched_generation;  // 4 x 8 bits
    // Pitch SOURCE latched at press (T1): a held voice that was played from a custom
    // pitch keeps that custom base for every retune decision, even after a group
    // gesture has dropped the custom override for FUTURE notes. Without this, an
    // octave toggle following a group toggle would silently snap a held custom pitch
    // to the table note - exactly the "accidental retune" the charter forbids.
    logic [3:0]  latched_custom;
    logic [27:0] latched_custom_note; // 4 x 7 bits
    logic [7:0]  generation;
    logic [7:0]  next_generation;
    logic        found;
    logic [3:0]  held;             // one bit per zone: the latched note is currently sounding
    logic [1:0]  panic_index;      // walks the zones while a panic is being serviced
    logic        panic_active;
    logic        panic_seen;
    // T1 live retune bookkeeping: at most one pending entry per region (a second
    // selector change before delivery collapses into the same entry, because
    // latched_note only moves at delivery), so the four-entry table cannot overflow.
    logic [3:0]  retune_pending;
    logic [27:0] retune_old_q;     // 4 x 7 bits: allocator match key
    logic [27:0] retune_new_q;     // 4 x 7 bits: target note
    logic [31:0] retune_gen_q;     // 4 x 8 bits: delivery-time generation of the pending region
    logic [1:0]  retune_pop_idx;
    logic        retune_pop_found;
    logic [6:0]  retune_cand;
    wire         selector_change = retune_arm &&
                                   (group_toggle | octave_toggle |
                                    (cfg_load && (cfg_commit_mask[20] || cfg_commit_mask[21])));
    // Next-state of the two pitch selectors, visible in the same clock evaluation
    // (the registered versions update via NBA and would read stale below).
    logic group_b_w, octave_w;
    always_comb begin
        group_b_w = group_b_r;
        octave_w  = octave_up_r;
        if (group_toggle) group_b_w = ~group_b_r;
        else if (cfg_load && (cfg_commit_mask[20] === 1'b1)) group_b_w = cfg_group_b;
        if (octave_toggle) octave_w = ~octave_up_r;
        else if (cfg_load && (cfg_commit_mask[21] === 1'b1)) octave_w = cfg_octave_up;
    end
    wire         sweep_request = panic | (ENABLE_PROTECTION && clear_all);
    wire         block_note_on = ENABLE_PROTECTION && block_on;

    // Group A and group B differ only in which zone plays which note. The function keeps the
    // mapping combinational and free of shared temporaries. A committed custom pitch for the
    // zone replaces the table entry. All schema notes 36..96, including +12 octave,
    // have a phase coefficient. No accepted pitch is silently changed to C3/C6.
    function automatic logic [6:0] note_for(input logic [1:0] zone, input logic group_b,
                                            input logic octave_up,
                                            input logic override_active,
                                            input logic [6:0] override_note);
        logic [6:0] base;
        begin
            if (override_active) begin
                base = override_note;
                if (base < 7'd36) base = 7'd36;
                if (base > 7'd96) base = 7'd96;
            end else begin
                case (zone)
                    2'd0: base = group_b ? 7'd67 : 7'd60;    // G4 or C4
                    2'd1: base = group_b ? 7'd69 : 7'd62;    // A4 or D4
                    2'd2: base = group_b ? 7'd71 : 7'd64;    // B4 or E4
                    default: base = group_b ? 7'd72 : 7'd67; // C5 or G4
                endcase
            end
            if (octave_up) base = base + 7'd12;
            note_for = base;
        end
    endfunction

    integer i;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            group_b_r    <= 1'b0;
            preset_1_r   <= 1'b0;
            octave_up_r  <= 1'b0;
            note_override_r <= 4'b0000;
            custom_note_r   <= {7'd67, 7'd64, 7'd62, 7'd60};
            generation   <= 8'd0;
            event_valid  <= 1'b0;
            event_on     <= 1'b0;
            event_region <= 2'd0;
            event_note   <= 7'd60;
            event_phase_inc <= 32'd0;
            event_preset <= 2'd0;
            event_generation <= 8'd0;
            latched_note       <= {7'd67, 7'd64, 7'd62, 7'd60};
            latched_generation <= 32'd0;
            latched_preset <= 8'd0;
            latched_custom    <= 4'b0000;
            latched_custom_note <= {7'd67, 7'd64, 7'd62, 7'd60};
            held               <= 4'b0000;
            panic_index        <= 2'd0;
            panic_active       <= 1'b0;
            panic_seen         <= 1'b0;
            retune_pending     <= 4'b0000;
            retune_old_q       <= 28'd0;
            retune_new_q       <= 28'd0;
            retune_gen_q       <= 32'd0;
            retune_valid       <= 1'b0;
            retune_region      <= 2'd0;
            retune_old_note    <= 7'd0;
            retune_new_note    <= 7'd0;
            retune_phase_inc   <= 32'd0;
            retune_generation  <= 8'd0;
        end else begin
            event_valid     <= 1'b0;
            retune_valid    <= 1'b0;
            next_generation  = generation + 8'd1;
            if (group_toggle) begin
                group_b_r   <= ~group_b_r;
                // Returning to the note-group table drops any remote custom pitch:
                // the gesture table is the documented escape hatch.
                note_override_r <= 4'b0000;
            end
            if (preset_toggle) preset_1_r  <= preset_1_r + 2'd1;
            if (octave_toggle) octave_up_r <= ~octave_up_r;

            // Configuration commit (one clock after the capability engine applied
            // its values). Only the fields this commit carried are loaded, so an
            // unrelated commit can never rewind a gesture-moved selector.
            if (cfg_load) begin
                if (cfg_commit_mask[0])  begin custom_note_r[0*7 +: 7] <= cfg_notes[0*7 +: 7]; note_override_r[0] <= cfg_note_valid[0]; end
                if (cfg_commit_mask[1])  begin custom_note_r[1*7 +: 7] <= cfg_notes[1*7 +: 7]; note_override_r[1] <= cfg_note_valid[1]; end
                if (cfg_commit_mask[2])  begin custom_note_r[2*7 +: 7] <= cfg_notes[2*7 +: 7]; note_override_r[2] <= cfg_note_valid[2]; end
                if (cfg_commit_mask[3])  begin custom_note_r[3*7 +: 7] <= cfg_notes[3*7 +: 7]; note_override_r[3] <= cfg_note_valid[3]; end
                // bit i of commit_mask is field id i+1: preset=20 -> bit 19,
                // group=21 -> bit 20, octave=22 -> bit 21.
                if (cfg_commit_mask[19]) preset_1_r  <= cfg_preset_1;
                if (cfg_commit_mask[20]) group_b_r   <= cfg_group_b;
                if (cfg_commit_mask[21]) octave_up_r <= cfg_octave_up;
            end

            // T1 enqueue: a group/octave change re-maps every HELD region whose pitch
            // moves. The candidate uses the override state as it stands at this clock
            // (a group gesture clears custom overrides only for FUTURE notes, so a held
            // custom pitch is never rewritten behind the player's back), and only
            // group/octave deltas enqueue - a preset or custom-note commit never retunes.
            if (selector_change) begin
                for (i = 0; i < 4; i = i + 1) begin
                    if (held[i]) begin
                        retune_cand = note_for(i[1:0], group_b_w, octave_w,
                                               latched_custom[i], latched_custom_note[i*7 +: 7]);
                        if (retune_cand !== latched_note[i*7 +: 7]) begin
                            retune_old_q[i*7 +: 7] <= latched_note[i*7 +: 7];
                            retune_new_q[i*7 +: 7] <= retune_cand;
                            retune_gen_q[i*8 +: 8] <= latched_generation[i*8 +: 8];
                            retune_pending[i]      <= 1'b1;
                        end
                    end
                end
            end

            // A panic releases every zone that is still held, one region per clock, so a stuck
            // note can always be silenced without touching the converter or the panel layout.
            if (!sweep_request) panic_seen <= 1'b0;
            if (sweep_request && !panic_active && !panic_seen) begin
                panic_active <= 1'b1;
                panic_index <= 2'd0;
                panic_seen <= 1'b1;
            end
            if (panic_active) begin
                if (held[panic_index]) begin
                    event_valid      <= 1'b1;
                    event_on         <= 1'b0;
                    event_region     <= panic_index;
                    event_note       <= latched_note[panic_index*7 +: 7];
                    event_generation <= latched_generation[panic_index*8 +: 8];
                    event_phase_inc  <= inc_for_note(latched_note[panic_index*7 +: 7]);
                    event_preset     <= latched_preset[panic_index*2 +: 2];
                    held[panic_index] <= 1'b0;
                end
                if (panic_index == 2'd3) begin
                    panic_index  <= 2'd0;
                    panic_active <= 1'b0;
                end else begin
                    panic_index <= panic_index + 2'd1;
                end
            end

            // Releases first: a release must be able to close the voice that is still owned,
            // even in the same clock as a new press elsewhere.
            found = 1'b0;
            for (i = 0; i < 4; i = i + 1) begin
                if (!panic_active && !found && trigger_off[i]) begin
                    found            = 1'b1;
                    held[i]          <= 1'b0;
                    event_valid      <= 1'b1;
                    event_on         <= 1'b0;
                    event_region     <= i[1:0];
                    event_note       <= latched_note[i*7 +: 7];
                    event_generation <= latched_generation[i*8 +: 8];
                    event_phase_inc  <= inc_for_note(latched_note[i*7 +: 7]);
                    event_preset     <= latched_preset[i*2 +: 2];
                end
            end
            if (!found) begin
                for (i = 0; i < 4; i = i + 1) begin
                    // `===` keeps a caller that leaves block_mask unconnected
                    // playing freely: an undriven input is neither 1'b1 nor 1'b0.
                    if (!panic_active && !sweep_request && !block_note_on && !found &&
                        trigger_on[i] && !(block_mask[i] === 1'b1)) begin
                        found            = 1'b1;
                        held[i]          <= 1'b1;
                        generation       <= next_generation;
                        latched_note[i*7 +: 7]        <= note_for(i[1:0], group_b_r, octave_up_r,
                                                     note_override_r[i], custom_note_r[i*7 +: 7]);
                        latched_generation[i*8 +: 8]  <= next_generation;
                        latched_custom[i]             <= note_override_r[i];
                        latched_custom_note[i*7 +: 7] <= custom_note_r[i*7 +: 7];
                        latched_preset[i*2 +: 2] <= preset_1_r;
                        event_valid      <= 1'b1;
                        event_on         <= 1'b1;
                        event_region     <= i[1:0];
                        event_note       <= note_for(i[1:0], group_b_r, octave_up_r,
                                                     note_override_r[i], custom_note_r[i*7 +: 7]);
                        event_generation <= next_generation;
                        event_phase_inc  <= inc_for_note(note_for(i[1:0], group_b_r, octave_up_r,
                                                     note_override_r[i], custom_note_r[i*7 +: 7]));
                        event_preset     <= preset_1_r;
                        // A re-press creates a new identity: its own pending retune is
                        // stale (it described the OLD slot) and must never rewrite the
                        // new press's note behind the new generation.
                        retune_pending[i] <= 1'b0;
                    end
                end
            end

            // T1 delivery: one retune per clock, never in a clock that carries a note
            // event (releases/presses win) and never during a panic sweep. Delivery
            // rewrites latched_note, so every later release rebuilds from the note the
            // allocator now holds.
            if (!panic_active && !sweep_request && !found && retune_arm &&
                (retune_pending != 4'b0000)) begin
                retune_pop_found = 1'b0;
                retune_pop_idx   = 2'd0;
                for (i = 0; i < 4; i = i + 1) begin
                    if (!retune_pop_found && retune_pending[i]) begin
                        retune_pop_found = 1'b1;
                        retune_pop_idx   = i[1:0];
                    end
                end
                if (retune_pop_found) begin
                    retune_valid      <= 1'b1;
                    retune_region     <= retune_pop_idx;
                    retune_old_note   <= retune_old_q[retune_pop_idx*7 +: 7];
                    retune_new_note   <= retune_new_q[retune_pop_idx*7 +: 7];
                    retune_phase_inc  <= inc_for_note(retune_new_q[retune_pop_idx*7 +: 7]);
                    retune_generation <= retune_gen_q[retune_pop_idx*8 +: 8];
                    latched_note[retune_pop_idx*7 +: 7] <= retune_new_q[retune_pop_idx*7 +: 7];
                    retune_pending[retune_pop_idx] <= 1'b0;
                end
            end
        end
    end

    assign group_b  = group_b_r;
    assign preset_1 = preset_1_r;
    assign octave_up = octave_up_r;
    assign leds     = zone_gate;
    assign led_fault = |zone_stale;
endmodule
