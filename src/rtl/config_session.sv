// Configuration session wrapper: lease, epoch and replay protection (2026-10-24).
//
// config_capability answers "may this field be written, and does a consumer read
// it". This wrapper answers the orthogonal questions a real transport has to
// answer before that policy is even consulted:
//
//   * OWNER  - only one client may change the instrument at a time. A client
//              acquires a lease with an explicit 16-bit token; every later
//              request must carry the same token. This is arbitration, not a
//              security credential; BLE authentication belongs to the bridge.
//   * LEASE  - the lease expires after LEASE_CLOCKS without traffic from the
//              holder. A client that walks away (or crashes) cannot lock the
//              instrument out of configuration forever.
//   * EPOCH  - the epoch increments whenever the owner changes. A staged set
//              captured under an older epoch can never be committed into a new
//              session, so a half-finished edit cannot leak across owners.
//   * REPLAY - a request repeats (same sequence number, same body) returns the
//              cached result and changes nothing. The same sequence number with
//              a DIFFERENT body is refused instead of applied, so a truncated
//              or corrupted retry cannot silently rewrite a field.
//
// Nothing here decides whether a field is supported; that stays in
// config_capability so the two can be tested apart.
module config_session #(
    // 1 s at the 12.288 MHz audio clock. A client must renew during longer edits.
    parameter integer LEASE_CLOCKS = 12_288_000,
    parameter logic [21:0] SUPPORTED_MASK       = 22'h3F80FF,
    parameter logic [11:0] DEFAULT_ON_THRESHOLD = 12'd512,
    parameter logic [5:0]  DEFAULT_PARTIAL      = 6'd32,
    parameter logic [6:0]  DEFAULT_ATTENUATION  = 7'd0
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        req_valid,
    input  logic [2:0]  req_op,        // 0 SET 1 COMMIT 2 GET 3 ACQUIRE 4 RELEASE 5 CAPABILITY
    input  logic [7:0]  req_field,
    input  logic [15:0] req_value,
    input  logic [15:0] req_token,
    input  logic [15:0] req_seq,
    input  logic        held,          // panic mute or guide active: commits refused
    output logic        ack,
    output logic [7:0]  result,
    output logic [15:0] reply_value,
    output logic [15:0] epoch,
    output logic [21:0] supported_mask,
    output logic [7:0]  first_field,
    output logic        lease_held,
    output logic [15:0] lease_owner,
    output logic        replayed,      // the request was an idempotent repeat
    // applied values: the wires a consumer must actually read
    output logic [11:0] applied_on_threshold [0:3],
    output logic [5:0]  applied_partial_target,
    output logic [6:0]  applied_attenuation,
    output logic        attenuation_valid,
    // next-note selectors and custom per-zone pitches (S02), plus the one-clock
    // apply strobe: asserted one cycle AFTER a successful commit, when every
    // applied_* output above is already stable with the committed values.
    output logic [21:0] commit_mask,
    output logic [27:0] applied_notes,
    output logic [3:0]  applied_note_valid,
    output logic        applied_group_b,
    output logic [1:0] applied_preset_1,
    output logic        applied_octave_up,
    output logic [6:0]   applied_wet_max,
    output logic        applied_effect_family,
    output logic        effect_family_valid,
    output logic        apply_strobe
);
    localparam logic [2:0] OP_SET        = 3'd0;
    localparam logic [2:0] OP_COMMIT     = 3'd1;
    localparam logic [2:0] OP_GET        = 3'd2;
    localparam logic [2:0] OP_ACQUIRE    = 3'd3;
    localparam logic [2:0] OP_RELEASE    = 3'd4;
    localparam logic [2:0] OP_CAPABILITY = 3'd5;

    localparam logic [7:0] R_OK       = 8'd0;
    localparam logic [7:0] R_LEASE    = 8'd23;   // no lease, or a different owner holds it
    localparam logic [7:0] R_REPLAY   = 8'd24;   // same sequence, different body

    // ---- the policy engine ------------------------------------------------------
    logic        cap_valid, cap_ack, cap_commit, cap_get_valid, cap_atten_valid;
    logic [1:0]  cap_op;
    logic [7:0]  cap_field, cap_result, cap_first;
    logic [15:0] cap_value, cap_epoch, cap_get_value;
    logic [21:0] cap_commit_mask;
    logic [27:0] cap_notes;
    logic [3:0]  cap_note_valid;
    logic cap_group_b, cap_octave_up;
    logic [1:0] cap_preset_1;
    logic [6:0]  cap_wet_max;
    logic        cap_effect_family, cap_effect_family_valid;

    config_capability #(
        .SUPPORTED_MASK(SUPPORTED_MASK),
        .DEFAULT_ON_THRESHOLD(DEFAULT_ON_THRESHOLD),
        .DEFAULT_PARTIAL(DEFAULT_PARTIAL),
        .DEFAULT_ATTENUATION(DEFAULT_ATTENUATION)
    ) policy (
        .clk, .rst_n,
        .req_valid(cap_valid), .req_op(cap_op), .req_field(cap_field),
        .req_value(cap_value), .req_epoch(cap_epoch), .cur_epoch(epoch),
        .held,
        .ack(cap_ack), .result(cap_result), .first_field(cap_first),
        .staged_mask(), .commit_pulse(cap_commit), .commit_mask(cap_commit_mask),
        .get_valid(cap_get_valid), .get_value(cap_get_value),
        .applied_on_threshold, .applied_partial_target,
        .applied_attenuation, .attenuation_valid(cap_atten_valid),
        .applied_notes(cap_notes), .applied_note_valid(cap_note_valid),
        .applied_group_b(cap_group_b), .applied_preset_1(cap_preset_1),
        .applied_octave_up(cap_octave_up), .applied_wet_max(cap_wet_max),
        .applied_effect_family(cap_effect_family), .effect_family_valid(cap_effect_family_valid)
    );

    assign attenuation_valid = cap_atten_valid;
    assign supported_mask    = SUPPORTED_MASK;
    assign first_field       = cap_first;
    assign commit_mask       = cap_commit_mask;
    assign applied_notes     = cap_notes;
    assign applied_note_valid = cap_note_valid;
    assign applied_group_b   = cap_group_b;
    assign applied_preset_1  = cap_preset_1;
    assign applied_octave_up = cap_octave_up;
    assign applied_wet_max   = cap_wet_max;
    assign applied_effect_family = cap_effect_family;
    assign effect_family_valid   = cap_effect_family_valid;

    // The apply strobe lags the commit by one clock: the consumers load the
    // applied_* outputs only once they already hold the committed values.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) apply_strobe <= 1'b0;
        else        apply_strobe <= cap_commit;
    end

    // ---- lease ------------------------------------------------------------------
    logic [15:0] lease_token_r;
    logic        lease_valid_r;
    logic [31:0] lease_age;
    logic [15:0] epoch_r;

    assign lease_held  = lease_valid_r;
    assign lease_owner = lease_token_r;
    assign epoch       = epoch_r;

    // ---- replay cache -----------------------------------------------------------
    // The fingerprint covers every field a request can carry, so a retry with the
    // same sequence number but a different body can never be mistaken for a repeat.
    logic [15:0] last_seq_r;
    logic [47:0] last_fp_r;
    logic [7:0]  last_result_r;
    logic [15:0] last_value_r;
    logic        have_last_r;

    logic [47:0] req_fp;
    assign req_fp = {req_op, req_field, req_value, req_token};

    logic        is_repeat, is_conflict;
    assign is_repeat   = have_last_r && (req_seq == last_seq_r) && (req_fp == last_fp_r);
    assign is_conflict = have_last_r && (req_seq == last_seq_r) && (req_fp != last_fp_r);

    logic        owner_ok;
    assign owner_ok = lease_valid_r && (lease_token_r == req_token);

    // Which operation is currently inside the policy engine, so the reply can be
    // shaped for it (a COMMIT has no value of its own to echo).
    logic [1:0]  pending_op_r;

    always_ff @(posedge clk or negedge rst_n) begin
        logic [7:0]  r;
        logic [15:0] v;
        logic        handed;
        if (!rst_n) begin
            ack <= 1'b0; result <= R_OK; reply_value <= 16'd0;
            lease_token_r <= 16'd0; lease_valid_r <= 1'b0; lease_age <= 32'd0;
            epoch_r <= 16'd1;
            last_seq_r <= 16'd0; last_fp_r <= 48'd0; last_result_r <= 8'd0;
            last_value_r <= 16'd0; have_last_r <= 1'b0; replayed <= 1'b0;
            pending_op_r <= 2'd0;
            cap_valid <= 1'b0; cap_op <= 2'd0; cap_field <= 8'd0;
            cap_value <= 16'd0; cap_epoch <= 16'd0;
        end else begin
            ack        <= 1'b0;
            replayed   <= 1'b0;
            cap_valid  <= 1'b0;

            // Lease age: any request from the holder refreshes it, silence expires it.
            if (lease_valid_r) begin
                if (owner_ok && req_valid) lease_age <= 32'd0;
                else if (lease_age >= LEASE_CLOCKS-1) begin
                    lease_age <= 32'd0;
                    lease_valid_r <= 1'b0;
                    // Expiry invalidates every staged set: the next owner must start
                    // from a known state rather than inherit a half-finished edit.
                    epoch_r <= epoch_r + 16'd1;
                    // An expired ACQUIRE must not replay an old OK without
                    // actually owning a lease. Replies belong to this session.
                    have_last_r <= 1'b0;
                end else lease_age <= lease_age + 32'd1;
            end else begin
                lease_age <= 32'd0;
                if (lease_valid_r) lease_valid_r <= 1'b0;
            end

            if (req_valid) begin
                r = R_OK; v = epoch_r; handed = 1'b0;
                if (is_conflict) begin
                    // A sequence number is spent once used with a different body.
                    ack         <= 1'b1;
                    result      <= R_REPLAY;
                    reply_value <= epoch_r;
                end else if (is_repeat) begin
                    ack         <= 1'b1;
                    result      <= last_result_r;
                    reply_value <= last_value_r;
                    replayed    <= 1'b1;
                end else begin
                    last_seq_r  <= req_seq;
                    last_fp_r   <= req_fp;
                    have_last_r <= 1'b1;
                    case (req_op)
                        OP_ACQUIRE: begin
                            if (!lease_valid_r) begin
                                // Fresh acquisition starts a new session: the epoch
                                // moves so anything staged by the previous owner dies.
                                epoch_r       <= epoch_r + 16'd1;
                                v              = epoch_r + 16'd1;
                                lease_valid_r <= 1'b1;
                                lease_token_r <= req_token;
                                lease_age     <= 32'd0;
                            end else if (lease_token_r == req_token) begin
                                // Idempotent re-acquire by the same owner keeps the
                                // epoch, so an in-flight edit survives a refresh.
                                lease_age <= 32'd0;
                                v         = epoch_r;
                            end else begin
                                // A different owner cannot steal a live lease. It waits
                                // for expiry or for the holder to release it.
                                r = R_LEASE;
                            end
                        end
                        OP_RELEASE: begin
                            if (owner_ok) begin
                                lease_valid_r <= 1'b0;
                                lease_age     <= 32'd0;
                                epoch_r       <= epoch_r + 16'd1;
                                v              = epoch_r + 16'd1;
                            end else begin
                                r = R_LEASE;
                            end
                        end
                        OP_CAPABILITY: begin
                            // Read-only and lease-free: a client must be able to ask
                            // what it may ask for before it has any permission. The
                            // full 22-bit mask is exported on supported_mask.
                            v = SUPPORTED_MASK[15:0];
                        end
                        default: begin
                            if (req_op > OP_CAPABILITY) begin
                                r = 8'd16; // UNSUPPORTED, never reinterpret as GET
                            end else if (!owner_ok) begin
                                r = R_LEASE;
                            end else begin
                                // Hand the request to the policy engine. The reply is
                                // captured one clock later, when cap_ack rises.
                                cap_valid <= 1'b1;
                                cap_op    <= (req_op == OP_SET)    ? 2'd0 :
                                             (req_op == OP_COMMIT) ? 2'd1 : 2'd2;
                                cap_field <= req_field;
                                cap_value <= req_value;
                                cap_epoch <= epoch_r;
                                pending_op_r <= (req_op == OP_SET) ? 2'd0 :
                                                (req_op == OP_COMMIT) ? 2'd1 : 2'd2;
                                handed    = 1'b1;
                            end
                        end
                    endcase

                    // Only the operations answered here update the cache; SET/COMMIT/
                    // GET are cached when the policy engine replies.
                    if (!handed) begin
                        // Answered right here: one-cycle pulse, one cycle after the
                        // request. Handed-off operations answer on cap_ack instead so
                        // the transport can never read a result that is still pending.
                        ack           <= 1'b1;
                        result        <= r;
                        reply_value   <= v;
                        last_result_r <= r;
                        last_value_r  <= v;
                    end
                end
            end

            // Policy reply: capture the result and the value the client may read back.
            if (cap_ack) begin
                ack    <= 1'b1;
                result <= cap_result;
                if (cap_get_valid)      reply_value <= cap_get_value;
                else if (pending_op_r == 2'd1) reply_value <= epoch_r;
                else                    reply_value <= cap_value;
                last_result_r <= cap_result;
                last_value_r  <= cap_get_valid ? cap_get_value :
                                 (pending_op_r == 2'd1) ? epoch_r : cap_value;
            end
        end
    end
endmodule
