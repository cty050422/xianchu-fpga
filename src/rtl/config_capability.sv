// Configuration capability engine for the DEFAULT image (2026-10-24, extended 2026-10-25).
//
// Why this module exists: the audited productized tree can write 22 configuration
// fields, but the default image has no configuration transport and, more to the
// point, no consumer for most of those fields. Acknowledging a field that nothing
// reads is worse than not offering it, so this engine only accepts fields whose
// value demonstrably reaches a real consumer in this image, and answers every other
// field with UNSUPPORTED plus the id of the first field it does accept.
//
// Contract:
//   * SET    stages one field. Nothing takes effect until COMMIT.
//   * COMMIT applies EVERY staged field atomically, in one clock, and only if the
//            staged epoch still matches the current epoch (STALE otherwise) and the
//            instrument is not held by panic/guide (HELD otherwise). An empty
//            staging set is INCOMPLETE, not a silent success.
//   * GET    reads the APPLIED value. Staged-but-uncommitted values are never
//            visible through GET, so a client cannot mistake a stage for an effect.
//   * Result codes reuse the productized protocol: 0 OK, 1 STAGED,
//     16 UNSUPPORTED, 17 RANGE, 19 STALE, 20 HELD, 22 INCOMPLETE.
//
// Supported fields and their consumers in this image:
//   1..4   note_zone0..3         -> zone_note_map custom per-zone pitch (next note-on)
//   5..8   on_threshold_zone0..3 -> pressure_zone.on_threshold   (trigger point)
//   16     partial_target        -> zone_additive_layer.partial_target (additive count)
//   18     user_attenuation      -> pcm_output_stage.atten_gain  (output level)
//   20     next_preset           -> zone_note_map preset selector (next note-on; widens
//                                   to 0..3 when the four-timbre source lands, S07)
//   21     next_group            -> zone_note_map note-group selector (next note-on)
//   22     next_octave           -> zone_note_map octave selector (next note-on)
// Every other field is UNSUPPORTED here, including ones that are supported in the
// productized candidate, because this image has no consumer for them.
//
// commit_mask tells the downstream consumers WHICH fields this commit carried, so a
// commit that only touches thresholds cannot rewind a selector the user moved with
// a panel gesture in the meantime.
module config_capability #(
    // bit i of this mask is field id i+1; it must agree with the case function below.
    // 0x3B80FF = ids 1..8 (note_zone0..3, on_threshold_zone0..3)
    //          + 16 (partial_target) + 18 (user_attenuation) + 20,21,22 (next_preset/group/octave).
    parameter logic [21:0] SUPPORTED_MASK = 22'h3F80FF, // bit18: field 19 effect_family
    parameter logic [11:0] DEFAULT_ON_THRESHOLD = 12'd512,
    parameter logic [5:0]  DEFAULT_PARTIAL      = 6'd32,
    parameter logic [6:0]  DEFAULT_ATTENUATION  = 7'd0
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        req_valid,
    input  logic [1:0]  req_op,        // 0 = SET, 1 = COMMIT, 2 = GET
    input  logic [7:0]  req_field,
    input  logic [15:0] req_value,
    input  logic [15:0] req_epoch,
    input  logic [15:0] cur_epoch,
    input  logic        held,          // panic mute or guide active: no commit
    output logic        ack,
    output logic [7:0]  result,
    output logic [7:0]  first_field,   // lowest supported id, for UNSUPPORTED replies
    output logic [21:0] staged_mask,
    output logic        commit_pulse,
    // Which field ids the last successful COMMIT carried (bit i = id i+1). Held
    // until the next commit so the consumers can load exactly those values.
    output logic [21:0] commit_mask,
    output logic        get_valid,
    output logic [15:0] get_value,
    // applied values: these are the wires a consumer must actually read
    output logic [11:0] applied_on_threshold [0:3],
    output logic [5:0]  applied_partial_target,
    output logic [6:0]  applied_attenuation,
    output logic        attenuation_valid,
    // next-note selectors and the custom per-zone pitch overrides (S02)
    output logic [27:0] applied_notes,        // {zone3,zone2,zone1,zone0} x 7 bits
    output logic [3:0]  applied_note_valid,   // zone has a committed custom pitch
    output logic        applied_group_b,
    output logic [1:0] applied_preset_1,
    output logic        applied_octave_up,
    output logic [6:0]   applied_wet_max,
    // field 19: 0 = legacy chorus/delay family, 1 = space (FDN) family
    output logic        applied_effect_family,
    output logic        effect_family_valid
);
    localparam logic [7:0] R_OK          = 8'd0;
    localparam logic [7:0] R_STAGED      = 8'd1;
    localparam logic [7:0] R_UNSUPPORTED = 8'd16;
    localparam logic [7:0] R_RANGE       = 8'd17;
    localparam logic [7:0] R_STALE       = 8'd19;
    localparam logic [7:0] R_HELD        = 8'd20;
    localparam logic [7:0] R_INCOMPLETE  = 8'd22;

    localparam logic [7:0] OP_SET    = 2'd0;
    localparam logic [7:0] OP_COMMIT = 2'd1;
    localparam logic [7:0] OP_GET    = 2'd2;

    // ---- field metadata: generated from protocol/schema.json -------------------
    function automatic logic [15:0] field_min(input logic [7:0] id);
        case (id)
            8'd1, 8'd2, 8'd3, 8'd4:        field_min = 16'd36;   // note_zone0..3
            8'd5, 8'd6, 8'd7, 8'd8:        field_min = 16'd16;   // on_threshold_zone0..3
            8'd9, 8'd10, 8'd11, 8'd12:     field_min = 16'd0;    // curve_zone0..3
            8'd13:                         field_min = 16'd1;    // bend_range_semitones
            8'd14:                         field_min = 16'd0;    // vibrato_depth
            8'd15:                         field_min = 16'd0;    // axis_deadzone
            8'd16:                         field_min = 16'd2;    // partial_target
            8'd17:                         field_min = 16'd0;    // chorus_wet_max
            8'd18:                         field_min = 16'd0;    // user_attenuation
            8'd19:                         field_min = 16'd0;    // effect_family
            8'd20, 8'd21, 8'd22:           field_min = 16'd0;    // next_preset/group/octave
            default:                       field_min = 16'd0;
        endcase
    endfunction

    function automatic logic [15:0] field_max(input logic [7:0] id);
        case (id)
            8'd1, 8'd2, 8'd3, 8'd4:        field_max = 16'd96;
            8'd5, 8'd6, 8'd7, 8'd8:        field_max = 16'd4095;
            8'd9, 8'd10, 8'd11, 8'd12:     field_max = 16'd7;
            8'd13:                         field_max = 16'd12;
            8'd14:                         field_max = 16'd127;
            8'd15:                         field_max = 16'd64;
            8'd16:                         field_max = 16'd32;
            8'd17:                         field_max = 16'd64;
            8'd18:                         field_max = 16'd64;
            8'd19:                         field_max = 16'd1;   // effect_family (0 legacy, 1 space)
            8'd20:                         field_max = 16'd3;   // four timbres (S07)
            8'd21, 8'd22:                  field_max = 16'd1;
            default:                       field_max = 16'd0;
        endcase
    endfunction

    function automatic logic field_read_only(input logic [7:0] id);
        field_read_only = 1'b0;   // schema2: field19 is writable effect_family
    endfunction

    function automatic logic field_supported(input logic [7:0] id);
        field_supported = (id >= 8'd1) && (id <= 8'd22) && SUPPORTED_MASK[id - 8'd1];
    endfunction

    function automatic logic [7:0] first_supported();
        integer i;
        begin
            first_supported = 8'd0;
            for (i = 0; i < 22; i = i + 1)
                if (SUPPORTED_MASK[i] && first_supported == 8'd0) first_supported = i[7:0] + 8'd1;
        end
    endfunction

    logic [21:0] staged_mask_r;
    logic [15:0] staged_value [0:21];
    logic [15:0] staged_epoch_r;
    logic [11:0] on_threshold_r [0:3];
    logic [5:0]  partial_r;
    logic [6:0]  atten_r;
    logic        atten_valid_r;
    logic [6:0]  wet_max_r;
    logic [27:0] notes_r;
    logic [3:0]  note_valid_r;
    logic group_b_r, octave_up_r;
    logic [1:0] preset_1_r;
    logic effect_family_r, effect_family_seen;
    logic [21:0] commit_mask_r;

    assign staged_mask = staged_mask_r;
    assign applied_on_threshold = on_threshold_r;
    assign applied_partial_target = partial_r;
    assign applied_attenuation = atten_r;
    assign attenuation_valid = atten_valid_r;
    assign applied_notes = notes_r;
    assign applied_note_valid = note_valid_r;
    assign applied_group_b = group_b_r;
    assign applied_preset_1 = preset_1_r;
    assign applied_octave_up = octave_up_r;
    assign applied_wet_max = wet_max_r;
    assign applied_effect_family = effect_family_r;
    assign effect_family_valid = effect_family_seen;
    assign commit_mask = commit_mask_r;

    integer k;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ack <= 1'b0;
            result <= R_OK;
            first_field <= first_supported();
            staged_mask_r <= '0;
            staged_epoch_r <= 16'd0;
            commit_pulse <= 1'b0;
            commit_mask_r <= '0;
            get_valid <= 1'b0;
            get_value <= 16'd0;
            partial_r <= DEFAULT_PARTIAL;
            atten_r <= DEFAULT_ATTENUATION;
            atten_valid_r <= 1'b1;
            // The note registers mirror the group-A table so a GET before any
            // commit reports the pitches the instrument actually starts with.
            notes_r <= {7'd67, 7'd64, 7'd62, 7'd60};
            note_valid_r <= 4'b0000;
            group_b_r <= 1'b0; preset_1_r <= 1'b0; octave_up_r <= 1'b0;
            effect_family_r <= 1'b1;   // product default: space (FDN) family
            effect_family_seen <= 1'b0;
            wet_max_r <= 7'd64;   // no ceiling until a commit asks for one
            for (k = 0; k < 4; k = k + 1) on_threshold_r[k] <= DEFAULT_ON_THRESHOLD;
            for (k = 0; k < 22; k = k + 1) staged_value[k] <= 16'd0;
        end else begin
            ack <= 1'b0;
            commit_pulse <= 1'b0;
            get_valid <= 1'b0;

            if (req_valid) begin
                ack <= 1'b1;
                first_field <= first_supported();
                // COMMIT is field-independent: it applies whatever is staged, so it must
                // not be refused just because the last SET named an unsupported field.
                if (req_op == OP_COMMIT) begin
                    if (staged_mask_r == '0) begin
                        // Nothing staged is INCOMPLETE, not a success and not a stale
                        // epoch: an empty staging set has no epoch to be stale about.
                        result <= R_INCOMPLETE;
                    end else if (held) begin
                        result <= R_HELD;
                    end else if ((req_epoch != cur_epoch) || (staged_epoch_r != cur_epoch)) begin
                        // Parameters captured under an older epoch must not be
                        // applied to a different instrument session, and the poisoned
                        // set is dropped so the client can stage a fresh one.
                        staged_mask_r <= '0;
                        result <= R_STALE;
                    end else begin
                        for (k = 0; k < 22; k = k + 1) begin
                            if (staged_mask_r[k]) begin
                                if ((k + 1) == 5) on_threshold_r[0] <= staged_value[k][11:0];
                                if ((k + 1) == 6) on_threshold_r[1] <= staged_value[k][11:0];
                                if ((k + 1) == 7) on_threshold_r[2] <= staged_value[k][11:0];
                                if ((k + 1) == 8) on_threshold_r[3] <= staged_value[k][11:0];
                                if ((k + 1) == 16) partial_r <= staged_value[k][5:0];
                                if ((k + 1) == 18) begin
                                    atten_r <= staged_value[k][6:0];
                                    atten_valid_r <= 1'b1;
                                end
                                if ((k + 1) >= 1 && (k + 1) <= 4) begin
                                    notes_r[((k + 1) - 1)*7 +: 7] <= staged_value[k][6:0];
                                    note_valid_r[(k + 1) - 1] <= 1'b1;
                                end
                                if ((k + 1) == 17) wet_max_r <= staged_value[k][6:0];
                                if ((k + 1) == 20) preset_1_r  <= staged_value[k][1:0];
                                if ((k + 1) == 21) group_b_r   <= staged_value[k][0];
                                if ((k + 1) == 22) octave_up_r <= staged_value[k][0];
                                if ((k + 1) == 19) begin
                                    effect_family_r <= staged_value[k][0];
                                    effect_family_seen <= 1'b1;
                                end
                            end
                        end
                        commit_mask_r <= staged_mask_r;
                        staged_mask_r <= '0;
                        commit_pulse <= 1'b1;
                        result <= R_OK;
                    end
                end else if (!field_supported(req_field) || field_read_only(req_field)) begin
                    // An unsupported or read-only field is refused, never acknowledged
                    // as applied; first_field tells the client what it may ask for.
                    result <= R_UNSUPPORTED;
                end else begin
                    case (req_op)
                        OP_SET: begin
                            if (req_epoch != cur_epoch) begin
                                result <= R_STALE;
                            end else if ((req_value < field_min(req_field)) || (req_value > field_max(req_field))) begin
                                result <= R_RANGE;
                            end else begin
                                staged_value[req_field - 8'd1] <= req_value;
                                // Replacing only the epoch tag would revive every old
                                // staged field when a new owner sends its first SET.
                                // A different epoch starts an entirely new set.
                                if (staged_epoch_r != req_epoch)
                                    staged_mask_r <= 22'b1 << (req_field - 8'd1);
                                else
                                    staged_mask_r[req_field - 8'd1] <= 1'b1;
                                staged_epoch_r <= req_epoch;
                                result <= R_STAGED;
                            end
                        end
                        OP_GET: begin
                            get_valid <= 1'b1;
                            case (req_field)
                                8'd1: get_value <= {9'd0, notes_r[0*7 +: 7]};
                                8'd2: get_value <= {9'd0, notes_r[1*7 +: 7]};
                                8'd3: get_value <= {9'd0, notes_r[2*7 +: 7]};
                                8'd4: get_value <= {9'd0, notes_r[3*7 +: 7]};
                                8'd5: get_value <= {4'd0, on_threshold_r[0]};
                                8'd6: get_value <= {4'd0, on_threshold_r[1]};
                                8'd7: get_value <= {4'd0, on_threshold_r[2]};
                                8'd8: get_value <= {4'd0, on_threshold_r[3]};
                                8'd16: get_value <= {10'd0, partial_r};
                                8'd17: get_value <= {9'd0, wet_max_r};
                                8'd19: get_value <= {15'd0, effect_family_r};
                                8'd18: get_value <= {9'd0, atten_r};
                                8'd20: get_value <= {14'd0, preset_1_r};
                                8'd21: get_value <= {15'd0, group_b_r};
                                8'd22: get_value <= {15'd0, octave_up_r};
                                default: get_value <= 16'd0;
                            endcase
                            result <= R_OK;
                        end
                        default: result <= R_UNSUPPORTED;
                    endcase
                end
            end
        end
    end
endmodule
