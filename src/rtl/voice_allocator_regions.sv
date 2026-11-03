// Region-aware voice allocator (M2): every voice is owned by a (region, generation) pair,
// not only by a note number.
//
// Why this exists: the old allocator matched voices by note_id alone, so two regions that
// played the same note shared one voice, and a late note-off or a stale pressure value
// from a released gesture could take over the note that replaced it. Here:
//
//   * a note-on carries region, note, phase increment, preset and a generation counter;
//   * a note-off is only accepted when region AND generation AND note match a gated voice,
//     so an event that belongs to a previous owner cannot unbind the current one;
//   * stealing clears the old owner by construction (the slot is rewritten), and the
//     allocator reports which slot was stolen;
//   * when a voice is released, the expression it needs for its tail is LATCHED into the
//     slot, so the next press of the same region cannot reshape the previous generation's
//     release, and the tail keeps its own brightness instead of following the new gesture;
//   * allocation order is free -> released -> oldest-gated, and releases are resolved
//     before requests in the same clock (a note-off and a note-on for the same owner are
//     processed as release-then-request);
//   * a slot is freed only after its envelope has actually reached zero, so a stolen voice
//     never leaves a tail that nobody owns.
//
// The generation counter is 8 bits and is compared for equality only; a wrap cannot make a
// stale event match because events older than one queue residence cannot survive: the
// router emits one event per clock and the queue holds a bounded number of events
// (see rtl/voice_event_router.sv and sim/tb_voice_allocator_regions.sv).
module voice_allocator_regions #(
    parameter integer VOICES = 4
) (
    input  logic               clk,
    input  logic               rst_n,
    input  logic               sample_ce,
    // Note events (one per clock, already arbitrated and queued upstream)
    input  logic               event_valid,
    input  logic               event_on,        // 1 = note-on, 0 = note-off
    input  logic [1:0]         event_region,
    input  logic [6:0]         event_note,
    input  logic [31:0]        event_phase_inc,
    input  logic [1:0]         event_preset,
    input  logic [7:0]         event_generation,
    // T1 live retune: re-pitch the slot a (region, generation, OLD note) still owns -
    // gated voices AND release tails of the same generation follow. The slot's note and
    // phase increment are rewritten in one clock; a non-match is silently dropped. A
    // remap is not a new note: it never pulses event_accepted/retrigger/stolen and never
    // advances the ageing or the phase accumulators (only the per-sample increment).
    input  logic               retune_valid,
    input  logic [1:0]         retune_region,
    input  logic [6:0]         retune_old_note,
    input  logic [6:0]         retune_new_note,
    input  logic [31:0]        retune_phase_inc,
    input  logic [7:0]         retune_generation,
    // Envelope levels of the four voices, used to decide when a release has finished
    input  logic [15:0]        envelope0,
    input  logic [15:0]        envelope1,
    input  logic [15:0]        envelope2,
    input  logic [15:0]        envelope3,
    // Current expression of each region (16 bits per region, 2 bits of region each)
    input  logic [63:0]        region_pressure,
    // Per-voice control for the synthesis cores
    output logic [3:0]         gates,
    output logic [3:0]         retriggers,
    output logic [127:0]       phase_incs,      // voice i uses bits [i*32 +: 32]
    output logic [7:0]         presets,         // voice i uses bits [i*2 +: 2]
    output logic [63:0]        expressions,     // expression each voice must use now
    output logic [3:0]         allocated,
    output logic [7:0]         owner_regions,   // voice i uses bits [i*2 +: 2]
    output logic [31:0]        owner_generations,
    output logic [31:0]        owner_notes,     // voice i uses bits [i*8 +: 8]
    output logic [3:0]         event_accepted,
    output logic [3:0]         stolen,          // one pulse per stolen slot
    output logic [1:0]         selected_voice
);
    logic [3:0]  alloc;
    logic [3:0]  slot_gate;
    logic [7:0]  slot_region;        // 4 x 2 bits
    logic [31:0] slot_generation;    // 4 x 8 bits
    logic [31:0] slot_note;          // 4 x 8 bits (7 used)
    logic [127:0] slot_phase_inc;    // 4 x 32 bits
    logic [7:0]  slot_preset;        // 4 x 2 bits
    logic [63:0] slot_expression;    // 4 x 16 bits, latched while released
    logic [63:0] slot_age;           // 4 x 16 bits
    logic [3:0]  slot_retrigger;
    logic [3:0]  slot_stolen;
    integer      i;
    integer      free_slot;
    integer      released_slot;
    integer      oldest_slot;
    logic [15:0] oldest_age;
    integer      match_slot;
    integer      target;
    logic        found;
    logic [15:0] envelope_of_slot;

    function automatic logic [15:0] envelope_of(input integer slot);
        begin
            case (slot)
                0: envelope_of = envelope0;
                1: envelope_of = envelope1;
                2: envelope_of = envelope2;
                default: envelope_of = envelope3;
            endcase
        end
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            alloc            <= 4'd0;
            slot_gate        <= 4'd0;
            slot_region      <= 8'd0;
            slot_generation  <= 32'd0;
            slot_note        <= 32'd0;
            slot_phase_inc   <= 128'd0;
            slot_preset      <= 8'd0;
            slot_expression  <= 64'd0;
            slot_age         <= 64'd0;
            slot_retrigger   <= 4'd0;
            slot_stolen      <= 4'd0;
            event_accepted   <= 4'd0;
            selected_voice   <= 2'd0;
        end else begin
            slot_retrigger <= 4'd0;
            slot_stolen    <= 4'd0;
            event_accepted <= 4'd0;

            // ---- releases first: a note-off must win over a same-clock request -----
            if (event_valid && !event_on) begin
                match_slot = -1;
                for (i = 0; i < VOICES; i = i + 1) begin
                    if ((match_slot < 0) && alloc[i] && slot_gate[i] &&
                        (slot_region[i*2 +: 2] == event_region) &&
                        (slot_generation[i*8 +: 8] == event_generation) &&
                        (slot_note[i*8 +: 7] == event_note)) begin
                        match_slot = i;
                    end
                end
                if (match_slot >= 0) begin
                    slot_gate[match_slot] <= 1'b0;
                    // Freeze the expression this tail needs. The slot keeps it until the
                    // envelope reaches zero, so a new gesture cannot reshape the tail.
                    slot_expression[match_slot*16 +: 16] <= region_pressure[slot_region[match_slot*2 +: 2]*16 +: 16];
                    event_accepted[match_slot] <= 1'b1;
                end
            end

            // ---- requests ----------------------------------------------------------
            if (event_valid && event_on) begin
                // 1. Same owner already gated: retrigger that voice.
                match_slot = -1;
                for (i = 0; i < VOICES; i = i + 1) begin
                    if ((match_slot < 0) && alloc[i] && slot_gate[i] &&
                        (slot_region[i*2 +: 2] == event_region) &&
                        (slot_note[i*8 +: 7] == event_note)) begin
                        match_slot = i;
                    end
                end
                // 2. A free slot.
                free_slot = -1;
                for (i = 0; i < VOICES; i = i + 1) begin
                    if ((free_slot < 0) && !alloc[i]) free_slot = i;
                end
                // 3. A slot whose release has finished (allocated, gate low).
                released_slot = -1;
                for (i = 0; i < VOICES; i = i + 1) begin
                    if ((released_slot < 0) && alloc[i] && !slot_gate[i]) released_slot = i;
                end
                // 4. Otherwise steal the oldest gated voice.
                oldest_slot = -1;
                oldest_age  = 16'd0;
                for (i = 0; i < VOICES; i = i + 1) begin
                    if (alloc[i] && slot_gate[i]) begin
                        if ((oldest_slot < 0) || (slot_age[i*16 +: 16] > oldest_age)) begin
                            oldest_slot = i;
                            oldest_age  = slot_age[i*16 +: 16];
                        end
                    end
                end

                if (match_slot >= 0) begin
                    target = match_slot;
                    slot_retrigger[target] <= 1'b1;
                end else if (free_slot >= 0) begin
                    target = free_slot;
                end else if (released_slot >= 0) begin
                    target = released_slot;
                end else begin
                    target = (oldest_slot >= 0) ? oldest_slot : 0;
                    slot_stolen[target] <= 1'b1;   // the previous owner is invalidated here
                end

                if (match_slot < 0) begin
                    alloc[target]                  <= 1'b1;
                    slot_note[target*8 +: 8]       <= {1'b0, event_note};
                    slot_region[target*2 +: 2]     <= event_region;
                    slot_generation[target*8 +: 8] <= event_generation;
                    slot_phase_inc[target*32 +: 32] <= event_phase_inc;
                    slot_preset[target*2 +: 2]     <= event_preset;
                    slot_age[target*16 +: 16]      <= 16'd0;
                    slot_expression[target*16 +: 16] <= region_pressure[event_region*16 +: 16];
                end else begin
                    // Retrigger keeps the VOICE but adopts the new gesture's identity: the
                    // generation must advance with the event, otherwise the note-off of this
                    // new press (which carries the new generation) would not match the slot
                    // and the note would stay gated forever.
                    slot_expression[target*16 +: 16] <= region_pressure[event_region*16 +: 16];
                    slot_generation[target*8 +: 8]   <= event_generation;
                    slot_preset[target*2 +: 2]       <= event_preset;
                    slot_phase_inc[target*32 +: 32]  <= event_phase_inc;
                    slot_note[target*8 +: 8]         <= {1'b0, event_note};
                    slot_region[target*2 +: 2]       <= event_region;
                end
                slot_gate[target]          <= 1'b1;
                event_accepted[target]     <= 1'b1;
                selected_voice             <= target[1:0];
            end

            // ---- live retune (T1): only when the note channel is quiet, so a same-clock
            // press always wins. Held and released-tail slots of the exact
            // (region, generation, old note) identity are rewritten in place.
            if (retune_valid && !event_valid) begin
                for (i = 0; i < VOICES; i = i + 1) begin
                    if (alloc[i] &&
                        (slot_region[i*2 +: 2] == retune_region) &&
                        (slot_generation[i*8 +: 8] == retune_generation) &&
                        (slot_note[i*8 +: 7] == retune_old_note)) begin
                        slot_note[i*8 +: 8]        <= {1'b0, retune_new_note};
                        slot_phase_inc[i*32 +: 32] <= retune_phase_inc;
                    end
                end
            end

            // ---- ageing and freeing ------------------------------------------------
            for (i = 0; i < VOICES; i = i + 1) begin
                if (sample_ce) begin
                    if (alloc[i] && (slot_age[i*16 +: 16] != 16'hffff))
                        slot_age[i*16 +: 16] <= slot_age[i*16 +: 16] + 16'd1;
                end
                // A released voice is freed only once its envelope has really reached zero.
                if (alloc[i] && !slot_gate[i] && (envelope_of(i) == 16'd0)) begin
                    alloc[i] <= 1'b0;
                end
            end
        end
    end

    // ---- outputs -------------------------------------------------------------
    genvar v;
    generate
        for (v = 0; v < VOICES; v = v + 1) begin : voice_out
            assign gates[v]        = slot_gate[v];
            assign retriggers[v]   = slot_retrigger[v];
            assign phase_incs[v*32 +: 32] = slot_phase_inc[v*32 +: 32];
            assign presets[v*2 +: 2]      = slot_preset[v*2 +: 2];
            assign allocated[v]    = alloc[v];
            assign owner_regions[v*2 +: 2] = slot_region[v*2 +: 2];
            assign owner_generations[v*8 +: 8] = slot_generation[v*8 +: 8];
            assign owner_notes[v*8 +: 8] = slot_note[v*8 +: 8];
            assign stolen[v]       = slot_stolen[v];
            // A gated voice follows its region's live expression; a released voice uses
            // the value latched at note-off so the tail keeps its own brightness.
            assign expressions[v*16 +: 16] = slot_gate[v]
                ? region_pressure[slot_region[v*2 +: 2]*16 +: 16]
                : slot_expression[v*16 +: 16];
        end
    endgenerate
endmodule