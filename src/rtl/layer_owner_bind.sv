// final_instrument work candidate: the NON-PREEMPTIBLE owner of the single 32-partial
// auxiliary layer.
//
// WHY THIS MODULE EXISTS
// ======================
// candidates/dual_joystick/rtl/zone_additive_layer.sv selects its owner by pressure: the hardest
// pressed sounding voice owns the layer and a voice pressed at least OWN_MARGIN harder takes it
// over. That is exactly the behaviour the product contract forbids in normal mode ("pressure must
// not take ownership"), so the layer's own arbitration is not allowed to see more than one voice.
//
// This module is the only thing that decides WHICH voice the layer may follow. It hands the layer
// at most ONE gate, ONE expression slot and ONE phase increment, so the layer's internal takeover
// logic can never fire.
//
// OWNERSHIP CONTRACT (frozen before the RTL was written; the tests assert each clause)
// ==============================================================================
// C1. Only an ACCEPTED note-ON may claim a free layer. The allocator publishes `event_accepted`
//     for BOTH a bound note-on and an accepted note-off (an independent review, finding R2,
//     reproduced a phantom grant on a note-off of another held voice). The grant path therefore
//     uses `accepted_on` - event_accepted qualified by the event type - while `event_accepted`
//     still ends an ownership. A grant and a retire in the same clock: RETIRE WINS and the grant
//     is refused, so ownership never passes in one step.
// C2. Simultaneous requests are resolved by a FIXED priority: the LOWEST voice index wins.
// C3. Once bound, the owner cannot change for the lifetime of that note-on. Ownership ends on:
//       * the owner's gate falling (note-off after the release has been accepted), or
//       * `stolen[owner]` (the slot was preempted: the voice now plays another note), or
//       * any `event_accepted[owner]` that is not the grant itself (a retrigger rewrites the
//         slot's identity), or
//       * `force_free` (panic / clear calibration / fault guard), or reset.
// C4. A claim is REFUSED - and counted - while the previous owner's tail is still ramping down.
//     A held voice whose acceptance happened during that window never gets the layer later.
// C5. Leaving ownership releases the tail with an EXPLICIT policy. Finding R3 showed the first
//     version latching the WRONG parameters: the allocator rewrites the slot before the binder sees
//     the steal, so `voice_phase_incs[owner]` at retire time already belongs to the replacement
//     note. The owner's phase and expression are therefore SHADOWED one clock behind while ACTIVE,
//     and the retire uses the shadow. The latched pressure then ramps down by RELEASE_STEP per
//     sample enable (128 -> 512 sample enables = 10.67 ms at 48 kHz) and ownership ends only when
//     the ramp is zero AND the layer reports gain 0.
// C6. While ACTIVE the layer follows the owner LIVE (its own pressure, its own phase including the
//     global bend and vibrato). The forbidden influence is a NON-owner's, and that is structurally
//     impossible here: every other gate/expression/phase slot handed to the layer is zero.
//
// NOT CLAIMED: this is a digital ownership/isolation proof only. Whether 32 partials on one note are
// audible, pleasant or free of clicks needs measurement on hardware.
module layer_owner_bind #(
    // Pressure units per sample enable while releasing. 128 makes the 16-bit expression ramp take
    // 512 sample enables (10.67 ms at 48 kHz), a controlled release rather than a hard cut.
    parameter logic [15:0] RELEASE_STEP = 16'd128,
    parameter logic BIND_ENVELOPE = 1'b0
) (
    input  logic               clk,
    input  logic               rst_n,
    input  logic               sample_ce,        // one pulse per audio sample
    input  logic [3:0]         voice_gates,      // frozen instrument's per-voice gates
    input  logic [63:0]        voice_expression, // 4 x 16 bits, per-voice pressure
    input  logic [63:0]        voice_envelopes,  // optional ADSR, same owner/generation as pressure
    input  logic [127:0]       voice_phase_incs, // 4 x 32 bits, bend and vibrato included
    input  logic [3:0]         accepted_on,       // per-voice pulse: an accepted NOTE-ON (C1)
    input  logic [3:0]         event_accepted,   // per-voice pulse: accepted on OR off (C3)
    input  logic [3:0]         stolen,           // per-voice pulse: the slot was preempted
    input  logic [7:0]         layer_gain,        // the layer's own gain (0 = silent)
    input  logic               force_free,        // one-clock pulse: panic/clear/fault guard
    output logic [3:0]         bind_gates,
    output logic [63:0]        bind_expression,
    output logic [63:0]        bind_envelopes,
    output logic [127:0]       bind_phase_incs,
    output logic [1:0]         owner,             // current/last owner voice index
    output logic               owner_valid,       // 1 while state == ACTIVE
    output logic [1:0]         state,             // 0 IDLE, 1 ACTIVE, 2 RELEASING
    output logic [7:0]         bind_generation,   // increments on every grant (identity, not reuse)
    output logic [15:0]        granted,           // grants since reset
    output logic [15:0]        refused,           // refused claims (layer busy, non-owner, note-off)
    output logic [15:0]        released,          // completed releases since reset
    output logic [15:0]        release_level,     // latched expression of the tail (diagnostics)
    output logic [31:0]        tail_phase        // latched phase of the tail (diagnostics, C5)
);
    localparam logic [1:0] S_IDLE      = 2'd0,
                           S_ACTIVE    = 2'd1,
                           S_RELEASING = 2'd2;

    logic [1:0]  state_r;
    logic [1:0]  owner_r;
    logic [1:0]  candidate;
    logic        candidate_valid;
    logic        accept_any;
    logic        retire_owner;
    logic        grant_now;
    logic [31:0] shadow_phase;      // owner's phase, one clock behind (C5/R3)
    logic [15:0] shadow_expression; // owner's pressure, one clock behind (C5/R3)
    logic [15:0] shadow_envelope, latched_envelope;
    logic [31:0] latched_phase;
    logic [15:0] rel_level;
    logic [7:0]  generation_r;
    logic [15:0] granted_r, refused_r, released_r;

    assign state           = state_r;
    assign owner           = owner_r;
    assign owner_valid     = (state_r == S_ACTIVE);
    assign bind_generation = generation_r;
    assign granted         = granted_r;
    assign refused         = refused_r;
    assign released        = released_r;
    assign release_level   = rel_level;
    assign tail_phase      = latched_phase;

    // C2: fixed priority over the ACCEPTED NOTE-ONS, lowest voice index first.
    always_comb begin
        candidate       = 2'd0;
        candidate_valid = 1'b1;
        if      (accepted_on[0]) candidate = 2'd0;
        else if (accepted_on[1]) candidate = 2'd1;
        else if (accepted_on[2]) candidate = 2'd2;
        else if (accepted_on[3]) candidate = 2'd3;
        else                     candidate_valid = 1'b0;
        accept_any = |event_accepted;
    end

    // C3: everything that ends an ownership in this clock.
    always_comb retire_owner = force_free | stolen[owner_r] | event_accepted[owner_r] |
                               !voice_gates[owner_r];

    // C1 + C4: a claim needs an accepted NOTE-ON, an idle state and a silent layer.
    // PRIORITY, stated explicitly: a retire is only evaluated while ACTIVE and a grant only while
    // IDLE, so the two can never be requested in the same clock. (Qualifying the grant with
    // retire_owner was wrong: in IDLE there is no owner to retire, and event_accepted[0] of the
    // very note-on being granted made the grant impossible and starved the layer.)
    always_comb grant_now = (state_r == S_IDLE) && candidate_valid &&
                           !force_free && (layer_gain == 8'd0);

    // ---- the single set of gates/expressions/phases the layer is allowed to see --------------
    always_comb begin
        bind_gates      = 4'b0000;
        bind_expression = 64'd0;
        bind_envelopes  = 64'd0;
        bind_phase_incs = 128'd0;
        if (state_r == S_ACTIVE) begin
            bind_gates = 4'b0001 << owner_r;
            if (retire_owner) begin
                // S3 (remediation review 2026-10-18): on the retire clock the state register is
                // still ACTIVE while the allocator has ALREADY rewritten the slot, so reading the
                // live slot here hands one sample of the REPLACEMENT note to the additive bank
                // (which latches base_inc on that very sample enable). The layer therefore sees the
                // shadowed - i.e. old-owner - parameters for exactly that clock.
                bind_expression[owner_r*16 +: 16] = shadow_expression;
                bind_envelopes[owner_r*16 +: 16] = shadow_envelope;
                bind_phase_incs[owner_r*32 +: 32] = shadow_phase;
            end else begin
                bind_expression[owner_r*16 +: 16] = voice_expression[owner_r*16 +: 16];
                bind_envelopes[owner_r*16 +: 16] = BIND_ENVELOPE
                    ? voice_envelopes[owner_r*16 +: 16] : 16'hffff;
                bind_phase_incs[owner_r*32 +: 32] = voice_phase_incs[owner_r*32 +: 32];
            end
        end else if ((state_r == S_RELEASING) && (rel_level != 16'd0)) begin
            // C5: latched pressure ramp and SHADOWED pitch. A re-used voice number cannot move it.
            // Local gain has a nonzero floor for a gated note. Drop the gate once
            // this release reaches zero; otherwise the layer can never become silent.
            bind_gates                        = 4'b0001 << owner_r;
            bind_expression[owner_r*16 +: 16] = rel_level;
            bind_envelopes[owner_r*16 +: 16] = latched_envelope;
            bind_phase_incs[owner_r*32 +: 32] = latched_phase;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_r           <= S_IDLE;
            owner_r           <= 2'd0;
            shadow_phase      <= 32'd0;
            shadow_expression <= 16'd0;
            shadow_envelope   <= 16'd0;
            latched_envelope  <= 16'd0;
            latched_phase     <= 32'd0;
            rel_level         <= 16'd0;
            generation_r      <= 8'd0;
            granted_r         <= 16'd0;
            refused_r         <= 16'd0;
            released_r        <= 16'd0;
        end else begin
            case (state_r)
                S_IDLE: begin
                    rel_level <= 16'd0;
                    if (grant_now) begin
                        owner_r      <= candidate;
                        state_r      <= S_ACTIVE;
                        generation_r <= generation_r + 8'd1;
                        granted_r    <= granted_r + 16'd1;
                        // Seed the shadow so a retire in the very next clock already has it.
                        shadow_phase      <= voice_phase_incs[candidate*32 +: 32];
                        shadow_expression <= voice_expression[candidate*16 +: 16];
                        shadow_envelope <= BIND_ENVELOPE
                            ? voice_envelopes[candidate*16 +: 16] : 16'hffff;
                    end else if (accept_any) begin
                        refused_r <= refused_r + 16'd1;
                    end
                end
                S_ACTIVE: begin
                    if (retire_owner) begin
                        // C5 + R3: use the SHADOW, not the live slot, which may already hold the
                        // replacement note.
                        latched_phase <= shadow_phase;
                        latched_envelope <= shadow_envelope;
                        rel_level     <= shadow_expression;
                        state_r       <= S_RELEASING;
                    end else begin
                        shadow_phase      <= voice_phase_incs[owner_r*32 +: 32];
                        shadow_expression <= voice_expression[owner_r*16 +: 16];
                        shadow_envelope <= BIND_ENVELOPE
                            ? voice_envelopes[owner_r*16 +: 16] : 16'hffff;
                        if (accept_any) begin
                            // A non-owner note-on cannot take an owned layer over.
                            refused_r <= refused_r + 16'd1;
                        end
                    end
                end
                S_RELEASING: begin
                    if (sample_ce) begin
                        if (rel_level > RELEASE_STEP) rel_level <= rel_level - RELEASE_STEP;
                        else                          rel_level <= 16'd0;
                    end
                    if (accept_any) refused_r <= refused_r + 16'd1;
                    // C5: finished only when the ramp has reached zero and the layer is silent.
                    if ((rel_level <= RELEASE_STEP) && (layer_gain == 8'd0)) begin
                        rel_level  <= 16'd0;
                        state_r    <= S_IDLE;
                        released_r <= released_r + 16'd1;
                    end
                end
                default: state_r <= S_IDLE;
            endcase
        end
    end
endmodule
