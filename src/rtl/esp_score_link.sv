// ESP32 score/control link, 115200 8N1.
// Frame: A5 5A, version, type, payload_length, sequence, payload, CRC-8/ATM.
// CRC covers version through the final payload byte (poly 0x07, init 0).
// RX types: 10 BEGIN(song_id,count), 11 STEP(index,zone|hint<<2,duration_samples[23:0]),
//           12 COMMIT(song_id), 13 GUIDE_CONTROL(0=stop,1=start), 14 PING,
//           15 CONFIG(op, field, value[15:0], token[15:0], request_seq[15:0]).
// TX type 80 is a periodic/command-triggered status frame.
// TX type 81 is the config reply: op, field, result, value, epoch, capability
//   mask and first supported field id. It is a separate frame type so the 15-byte
//   status frame stays byte-identical for every client already parsing it.
//
// Score transaction contract:
//   BEGIN opens a staging transaction and NEVER disturbs the published score.
//   STEP writes only the unpublished bank; every byte is range checked on the
//   board, not only on the host.
//   COMMIT publishes the staging bank atomically (single-cycle bank swap) only
//   when the transaction identity matches, the count is in range and every step
//   of the declared count was received. A failed, aborted or partial upload can
//   therefore never destroy the score that is currently being played.
//   Busy conditions (fault latched, guide running) reject BEGIN/STEP/COMMIT
//   with 0xE5 and leave the published score untouched.
//   Result codes: 00 accepted, E0 unknown opcode, E1 bad CRC, E2 bad length or
//   parameter, E3 incomplete/identity mismatch on COMMIT, E4 GUIDE_CONTROL not
//   allowed, E5 busy, E6 COMMIT without an open transaction.
//   A half frame that stalls for FRAME_GAP_BITS bit times is abandoned and
//   counted as a framing error; it is never answered with a fake ACK.
module esp_score_link #(
    parameter integer CLOCKS_PER_BIT = 107,
    parameter integer STATUS_INTERVAL = 1_228_800,
    // v1 transactions stay capped at 32 steps for byte-compatibility with R3
    // clients; the v2 transaction (BEGIN2/STEP2/COMMIT2) uses V2_MAX_STEPS.
    parameter integer MAX_STEPS = 32,
    parameter integer V2_MAX_STEPS = 64,
    parameter integer FRAME_GAP_BITS = 20,
    parameter integer PANEL_TTL_CLOCKS=61_440_000,
    parameter bit ENABLE_MOBILE = 1'b0,
    parameter bit ENABLE_AUDITION = 1'b0,
    parameter bit EXTENDED_STATUS = 1'b0,
    // A configuration lease expires after this many silent clocks (1 s at 12.288 MHz).
    parameter integer CFG_LEASE_CLOCKS = 12_288_000,
    parameter integer AUDITION_TAIL_MAX_SAMPLES=48000,
    parameter integer AUDITION_TAIL_QUIET_SAMPLES=16,
    // The value the configuration engine starts from must match the top-level
    // constant it replaces, otherwise "no config written yet" would silently move
    // the trigger point of every zone.
    parameter logic [11:0] CFG_DEFAULT_ON_THRESHOLD = 12'h200
) (
    input logic audition_tail_quiet=1'b1,
    input logic audition_sample_ce=1'b0,audition_abort=1'b0,audition_blocked=1'b0,
    output wire[7:0]audition_song,output wire[6:0]audition_length,
    output wire audition_active,output wire [5:0]audition_step,
    output wire audition_event_valid,audition_event_on,output wire[1:0]audition_region,audition_preset,
    output wire[6:0]audition_note,output wire[7:0]audition_generation,
    output wire[31:0]audition_inc,output wire[63:0]audition_pressure,
    input logic signed[15:0]mobile_pcm=16'sd0,input logic[247:0]mobile_state=248'd0,
    // four-voice engine snapshot for the 0x84 frame (schema 1, see voice_status_stream)
    input logic[63:0]  eng_lane_pcm=64'd0,
    input logic[23:0]  eng_voice_partials=24'd0,
    input logic[31:0]  eng_voice_gains=32'd0,
    input logic[31:0]  eng_voice_generation=32'd0,
    input logic[3:0]   eng_voice_gates=4'd0,
    input logic[3:0]   eng_note_active=4'd0,
    input logic[7:0]   eng_voice_presets=8'd0,
    input logic[31:0] eng_voice_notes=32'd0,
    input logic[7:0] eng_voice_regions=8'd0,
    input logic[63:0] eng_voice_envelopes=64'd0,
    input logic[127:0] eng_phase_incs=128'd0,
    input logic[15:0]  eng_grant_count=16'd0,
    input logic        eng_effect_family=1'b0,
    input logic        eng_budget_violation=1'b0,
    // T2 event telemetry (0x85, see rtl/event_recorder.sv): one accepted manual event
    // per frame. Same priority family as the 0x84 voice telemetry but ABOVE it, so a
    // recording burst cannot be starved by the periodic snapshot; still below the
    // status/ACK and config replies, which must never wait behind telemetry.
    input  logic        event_ready=1'b0,
    input  logic [5:0]  event_length=6'd0,
    input  logic [63:0] event_body=64'd0,
    output logic        event_take,
    // T3 0x86 statistics frame: lowest TX priority of all, paced by its producer.
    input  logic        stats_ready=1'b0,
    input  logic [5:0]  stats_length=6'd0,
    input  logic [111:0] stats_body=112'd0,
    output logic        stats_take,
    output wire practice_request,output wire[1:0]practice_request_mode,output wire[2:0]practice_action,
    output wire[15:0]practice_request_id,input logic[7:0]practice_result=8'he0,
    input  logic clk, input logic rst_n, input logic uart_rx_i, output logic uart_tx_o,
    input  logic [5:0] current_step,
    input  logic guide_active, input logic test_mode, input logic panic_mute,
    input  logic calibrated,
    input logic [1:0] panel_mode = 2'd0,
    input logic [3:0] panel_target = 4'd0,
    input logic [1:0] panel_expression = 2'd0,
    input logic [1:0] panel_preset = 2'd0,
    input logic mapping_changed = 1'b0,
    output logic score_mapping_ready,
    output logic [19:0] panel_pairing_code,
    input  logic [15:0] hit_count, wrong_count, miss_count,
    input  logic [1:0] note_layout,
    input  logic [5:0] partial_target,
    input  logic [7:0] wet_target,
    output logic score_loaded,
    output logic [7:0] song_id,
    output logic [6:0] score_length,
    output logic [1:0] score_target_zone,     // lowest set target bit (v1 view)
    output logic [3:0] score_target_mask,     // multi-hot target mask (v2 view)
    output logic        score_rest,           // current step is a rest
    output logic [1:0] score_expression,
    output logic [23:0] score_duration_samples,
    output logic [7:0] score_segment_index,   // published v2 segment identity
    output logic [7:0] score_segment_count,
    output logic        remote_guide_pulse,
    output logic [1:0] remote_guide_mode,  // 0 stop, 1 guided practice, 2 challenge
    output logic [15:0] crc_error_count,
    output logic [15:0] framing_error_count,
    // configuration transport (see rtl/config_session.sv)
    output logic [47:0] cfg_on_thresholds,   // 4 zones x 12 bits, zone0 in [11:0]
    output logic [5:0]  cfg_partial_target,
    output logic [6:0]  cfg_attenuation,
    output logic        cfg_atten_valid,
    output logic        cfg_lease_held,
    output logic [15:0] cfg_epoch,
    output logic        cfg_reply_seen,
    // S02 consumers: custom per-zone pitch, next-note selectors and the apply
    // strobe (one clock after a successful commit, applied_* already stable)
    output logic [6:0]  cfg_wet_max,       // committed chorus_wet_max (field 17)
    output logic        cfg_effect_family, // committed effect family (field 19; 0 legacy, 1 space)
    output logic        cfg_effect_family_valid,
    output logic [21:0] cfg_commit_mask,
    output logic [27:0] cfg_notes,           // {zone3,zone2,zone1,zone0} x 7 bits
    output logic [3:0]  cfg_note_valid,
    output logic        cfg_group_b,
    output logic [1:0] cfg_preset_1,
    output logic        cfg_octave_up,
    output logic        cfg_apply_strobe,
    // S08 runtime effect mode (see chorus_delay MODE_*); reset default 2.
    output logic [1:0]  fx_mode_out
);
    localparam logic [7:0] RESULT_OK       = 8'h00;
    localparam logic [7:0] RESULT_OPCODE   = 8'hE0;
    localparam logic [7:0] RESULT_CRC      = 8'hE1;
    localparam logic [7:0] RESULT_PARAM    = 8'hE2;
    localparam logic [7:0] RESULT_COMMIT   = 8'hE3;
    localparam logic [7:0] RESULT_GUIDE    = 8'hE4;
    localparam logic [7:0] RESULT_BUSY     = 8'hE5;
    localparam logic [7:0] RESULT_NO_TXN   = 8'hE6;

    localparam logic [7:0] CMD_BEGIN  = 8'h10;
    localparam logic [7:0] CMD_STEP   = 8'h11;
    localparam logic [7:0] CMD_COMMIT = 8'h12;
    localparam logic [7:0] CMD_GUIDE  = 8'h13;
    localparam logic [7:0] CMD_PING   = 8'h14;
    localparam logic [7:0] CMD_CONFIG = 8'h15;
    // v2 score transaction (S04): masks (chords), rests, 64 steps, per-segment
    // identity and a whole-transaction steps CRC. Additive opcodes: a v1 board
    // answers them with RESULT_OPCODE (0xE0) and keeps its published score.
    localparam logic [7:0] CMD_BEGIN2  = 8'h16;
    localparam logic [7:0] CMD_STEP2   = 8'h17;
    localparam logic [7:0] CMD_COMMIT2 = 8'h18;
    // S08: effect select, one payload byte {mode}. 0 bypass, 1 fixed delay,
    // 2 chorus (reset default), 3 echo (feedback). Answered only through the
    // next status frame's cmd_seq/cmd_result like the other score commands.
    localparam logic [7:0] CMD_PANEL = 8'h1A;
    logic [25:0] pairing_ttl;
    localparam logic [7:0] CMD_FX      = 8'h19;
    localparam logic [7:0] RSP_CONFIG = 8'h81;

    // Published score: two banks, one bank is live while the other is staged.
    // The reset never has to clear them: publication is gated by score_loaded
    // and by the completeness mask, so unwritten entries are unreachable.
    // One uniform step byte serves both protocol generations:
    //   bits[3:0] = target zone mask (multi-hot since v2; v1 writes a single bit)
    //   bits[5:4] = expression/hint (0..2; 3 is reserved and rejected on RX)
    //   bits[7:6] = 0
    // A mask of 0 is a REST: it occupies the step but triggers nothing.
    localparam integer BANK_STEPS = V2_MAX_STEPS;
    logic [7:0]  bank_a_mask [0:BANK_STEPS-1];
    logic [23:0] bank_a_duration [0:BANK_STEPS-1];
    logic [7:0]  bank_b_mask [0:BANK_STEPS-1];
    logic [23:0] bank_b_duration [0:BANK_STEPS-1];
    logic active_bank;                 // 1: bank B is published, 0: bank A

    logic        txn_open;
    logic        txn_v2;               // the open transaction uses BEGIN2/STEP2
    logic [7:0]  txn_song;
    logic [6:0]  txn_count;
    logic [7:0]  txn_seg_index, txn_seg_count;
    logic [63:0] txn_mask;
    logic [7:0]  txn_steps_crc;        // v2: accumulated over the staged payloads

    logic [7:0]  pub_mask_byte;
    always_comb begin
        if (score_loaded && current_step < score_length) begin
            pub_mask_byte          = active_bank ? bank_b_mask[current_step]
                                                 : bank_a_mask[current_step];
            score_duration_samples = active_bank ? bank_b_duration[current_step]
                                                 : bank_a_duration[current_step];
        end else begin
            pub_mask_byte = 8'd0;
            score_duration_samples = 24'd48000;
        end
    end
    assign score_target_mask  = pub_mask_byte[3:0];
    assign score_expression   = pub_mask_byte[5:4];
    assign score_target_zone  = (pub_mask_byte[3:0] == 4'd0) ? 2'd0 :
                                (pub_mask_byte[0] ? 2'd0 :
                                 pub_mask_byte[1] ? 2'd1 :
                                 pub_mask_byte[2] ? 2'd2 : 2'd3);
    assign score_rest         = score_loaded && (pub_mask_byte[3:0] == 4'd0);

    function automatic logic [7:0] crc8_next(input logic [7:0] crc, input logic [7:0] value);
        logic [7:0] c; integer i;
        begin
            c = crc ^ value;
            for (i=0;i<8;i=i+1) c = c[7] ? ((c << 1) ^ 8'h07) : (c << 1);
            crc8_next = c;
        end
    endfunction
    // CRC over one staged v2 step payload: opcode, index, mask, duration LE.
    function automatic logic [7:0] crc8_step2(input logic [7:0] crc,
        input logic [7:0] p0, input logic [7:0] p1, input logic [7:0] p2,
        input logic [7:0] p3, input logic [7:0] p4);
        logic [7:0] c;
        begin
            c = crc8_next(crc, 8'h17);
            c = crc8_next(c, p0);
            c = crc8_next(c, p1);
            c = crc8_next(c, p2);
            c = crc8_next(c, p3);
            c = crc8_next(c, p4);
            crc8_step2 = c;
        end
    endfunction

    function automatic logic [63:0] required_mask(input logic [6:0] count);
        integer i;
        begin
            required_mask = '0;
            for (i = 0; i < BANK_STEPS; i = i + 1) if (i < count) required_mask[i] = 1'b1;
        end
    endfunction

    logic [7:0] rx_data; logic rx_valid, rx_frame_error;
    uart_rx #(.CLOCKS_PER_BIT(CLOCKS_PER_BIT)) receiver (
        .clk, .rst_n, .rx(uart_rx_i), .data(rx_data), .data_valid(rx_valid),
        .framing_error(rx_frame_error));

    typedef enum logic [3:0] {R_A5,R_5A,R_VER,R_TYPE,R_LEN,R_SEQ,R_PAYLOAD,R_CRC} rx_state_t;
    rx_state_t rx_state;
    logic [7:0] rx_type, rx_len, rx_seq, rx_crc, rx_index;
    logic [7:0] payload [0:7];
    assign practice_request=rx_valid && rx_state==R_CRC && rx_data==rx_crc && rx_type==8'h20 && rx_len==4 && payload[0]<=2 && payload[1]<=4;
    assign practice_request_mode=payload[0][1:0];assign practice_action=payload[1][2:0];
    assign practice_request_id={payload[3],payload[2]};
    logic status_request;
    logic [7:0] last_cmd_seq, last_result;
    logic [15:0] gap_counter;
    logic        busy;
    logic        commit_ok;
    logic        commit2_ok;
    logic        step_v1_valid;
    logic        step_v2_valid;
    logic [7:0]  step_v1_byte, step_v2_byte;
    logic [5:0]  step_index;
    logic [7:0]  step_zone_byte;
    logic [23:0] step_duration;

    // ---- configuration transport -------------------------------------------------
    // The link owns the only UART, so the config session hangs off its frame
    // decoder. Nothing about the score path changes: CONFIG is a separate opcode
    // with its own reply frame type.
    logic        cfg_req_valid;
    logic [2:0]  cfg_req_op;
    logic [7:0]  cfg_req_field;
    logic [15:0] cfg_req_value, cfg_req_token, cfg_req_seq;
    logic [7:0]  cfg_op_echo, cfg_field_echo;
    logic        cfg_ack;
    logic [7:0]  cfg_result;
    logic [15:0] cfg_reply_value;
    logic [21:0] cfg_supported;
    logic [7:0]  cfg_first_field;
    logic [11:0] cfg_thresholds [0:3];
    logic        cfg_replayed;
    logic        cfg_frame_req;
    logic [7:0]  cfg_r_op, cfg_r_field, cfg_r_result, cfg_r_first, cfg_r_sequence;
    logic [15:0] cfg_r_value, cfg_r_epoch;
    logic [21:0] cfg_r_mask;

    config_session #(.LEASE_CLOCKS(CFG_LEASE_CLOCKS),
                     .DEFAULT_ON_THRESHOLD(CFG_DEFAULT_ON_THRESHOLD)) cfg_session (
        .clk, .rst_n,
        .req_valid(cfg_req_valid), .req_op(cfg_req_op), .req_field(cfg_req_field),
        .req_value(cfg_req_value), .req_token(cfg_req_token), .req_seq(cfg_req_seq),
        .held(busy),
        .ack(cfg_ack), .result(cfg_result), .reply_value(cfg_reply_value),
        .epoch(cfg_epoch), .supported_mask(cfg_supported), .first_field(cfg_first_field),
        .lease_held(cfg_lease_held), .lease_owner(), .replayed(cfg_replayed),
        .applied_on_threshold(cfg_thresholds),
        .applied_partial_target(cfg_partial_target),
        .applied_attenuation(cfg_attenuation),
        .attenuation_valid(cfg_atten_valid),
        .commit_mask(cfg_commit_mask),
        .applied_notes(cfg_notes), .applied_note_valid(cfg_note_valid),
        .applied_group_b(cfg_group_b), .applied_preset_1(cfg_preset_1),
        .applied_octave_up(cfg_octave_up), .applied_wet_max(cfg_wet_max),
        .applied_effect_family(cfg_effect_family), .effect_family_valid(cfg_effect_family_valid),
        .apply_strobe(cfg_apply_strobe)
    );
    assign cfg_on_thresholds = {cfg_thresholds[3], cfg_thresholds[2],
                                cfg_thresholds[1], cfg_thresholds[0]};

    // Reply bytes of the 0x81 frame. Payload is 11 bytes: op, field, result,
    // value LE, epoch LE, capability mask LE (22 bits), first supported field.
    function automatic logic [7:0] cfg_reply_byte(input logic [5:0] index);
        begin case(index)
            0:cfg_reply_byte=8'hA5; 1:cfg_reply_byte=8'h5A; 2:cfg_reply_byte=8'h01;
            3:cfg_reply_byte=RSP_CONFIG; 4:cfg_reply_byte=8'd11; 5:cfg_reply_byte=cfg_r_sequence;
            6:cfg_reply_byte=cfg_r_op; 7:cfg_reply_byte=cfg_r_field;
            8:cfg_reply_byte=cfg_r_result;
            9:cfg_reply_byte=cfg_r_value[7:0];  10:cfg_reply_byte=cfg_r_value[15:8];
            11:cfg_reply_byte=cfg_r_epoch[7:0]; 12:cfg_reply_byte=cfg_r_epoch[15:8];
            13:cfg_reply_byte=cfg_r_mask[7:0];  14:cfg_reply_byte=cfg_r_mask[15:8];
            15:cfg_reply_byte={2'b0,cfg_r_mask[21:16]};
            16:cfg_reply_byte=cfg_r_first;
            default:cfg_reply_byte=8'd0;
        endcase end
    endfunction

    always_comb begin
        busy = panic_mute || guide_active || audition_active;
        step_index     = payload[0][5:0];
        step_zone_byte = payload[1];
        step_duration  = {payload[4],payload[3],payload[2]};
        // v1 STEP: a single-zone target plus an expression hint, exactly the R3
        // layout. The stored byte widens to the uniform mask format.
        step_v1_valid  = txn_open && !txn_v2 && (rx_len == 8'd5) &&
                         (payload[0] < txn_count) &&
                         (step_zone_byte[7:4] == 4'd0) && (step_zone_byte[3:2] != 2'd3) &&
                         (step_duration != 24'd0);
        step_v1_byte   = {2'b00, step_zone_byte[3:2], 4'b0001 << step_zone_byte[1:0]};
        // v2 STEP2: multi-hot mask (0 = rest), expression 0..2, duration != 0.
        step_v2_valid  = txn_open && txn_v2 && (rx_len == 8'd5) &&
                         (payload[0] < txn_count) &&
                         (step_zone_byte[7:6] == 2'b00) && (step_zone_byte[5:4] != 2'd3) &&
                         (step_duration != 24'd0);
        step_v2_byte   = step_zone_byte;
        commit_ok      = txn_open && (rx_len == 8'd1) && (payload[0] == txn_song) &&
                         (txn_count >= 6'd1) &&
                         ((txn_mask & required_mask(txn_count)) == required_mask(txn_count));
        // v2 COMMIT2: song identity, the steps CRC over every staged payload,
        // and the completeness mask. Any mismatch keeps the published score.
        commit2_ok     = txn_open && txn_v2 && (rx_len == 8'd2) &&
                         (payload[0] == txn_song) && (payload[1] == txn_steps_crc) &&
                         (txn_count >= 6'd1) &&
                         ((txn_mask & required_mask(txn_count)) == required_mask(txn_count));
    end

    wire [7:0] audition_result;wire audition_loaded;
    wire audition_command=rx_valid && rx_state==R_CRC && rx_data==rx_crc && rx_type>=8'h1b && rx_type<=8'h1f;
    generate if(ENABLE_AUDITION) begin:g_audition
      audition_sequencer #(.TAIL_MAX_SAMPLES(AUDITION_TAIL_MAX_SAMPLES),
        .TAIL_QUIET_SAMPLES(AUDITION_TAIL_QUIET_SAMPLES)) player(.clk,.rst_n,.sample_ce(audition_sample_ce),
        .tail_quiet(audition_tail_quiet),.abort_playback(audition_abort || panic_mute || test_mode || !calibrated),
        .blocked(audition_blocked || guide_active || panic_mute || test_mode || !calibrated),
        .command_valid(audition_command),.command_op(rx_type),.command_seq(rx_seq),.command_len(rx_len[3:0]),
        .command_body({payload[7],payload[6],payload[5],payload[4],payload[3],payload[2],payload[1],payload[0]} &
          (64'hffffffffffffffff >> ((8-rx_len)*8))),
        .playing_song(audition_song),.playing_count(audition_length),.result(audition_result),.active(audition_active),.loaded(audition_loaded),.step(audition_step),
        .event_valid(audition_event_valid),.event_on(audition_event_on),.event_region(audition_region),
        .event_preset(audition_preset),.event_note(audition_note),.event_generation(audition_generation),
        .event_phase_inc(audition_inc),.pressure(audition_pressure));
    end else begin:g_no_audition
      assign audition_song=0;assign audition_length=0;assign audition_result=8'he0;assign audition_active=0;assign audition_loaded=0;assign audition_step=0;
      assign audition_event_valid=0;assign audition_event_on=0;assign audition_region=0;assign audition_preset=0;
      assign audition_note=0;assign audition_generation=0;assign audition_inc=0;assign audition_pressure=0;
    end endgenerate
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_state<=R_A5; rx_type<=0; rx_len<=0; rx_seq<=0; rx_crc<=0; rx_index<=0;
            panel_pairing_code<=0;pairing_ttl<=0;
            score_loaded<=0; song_id<=0; score_length<=0;score_mapping_ready<=1'b1;
            score_segment_index<=0; score_segment_count<=0;
            txn_v2<=0; txn_seg_index<=0; txn_seg_count<=0; txn_steps_crc<=0;
            fx_mode_out<=2'd2;
            remote_guide_pulse<=0; remote_guide_mode<=2'd0;
            crc_error_count<=0; framing_error_count<=0; status_request<=0;
            last_cmd_seq<=0; last_result<=0;
            active_bank<=1'b0; txn_open<=1'b0; txn_song<=0; txn_count<=0; txn_mask<='0;
            gap_counter<=0;
            cfg_req_valid<=1'b0; cfg_req_op<=3'd0; cfg_req_field<=8'd0;
            cfg_req_value<=16'd0; cfg_req_token<=16'd0; cfg_req_seq<=16'd0;
            cfg_op_echo<=8'd0; cfg_field_echo<=8'd0;
        end else begin
            remote_guide_pulse <= 1'b0;
            status_request <= 1'b0;
            // One-clock request pulse into the config session; only the R_CRC
            // decode below ever raises it.
            cfg_req_valid <= 1'b0;
            // Score and configuration have separate transactions. A changed
            // mapping cannot silently retune a retained old score after an
            // interrupted upload. Keep the old bank, but prohibit its playback
            // until a score is published against the new mapping.
            if(score_loaded && (mapping_changed ||
               (cfg_apply_strobe && |(cfg_commit_mask & 22'h30000F))))
                score_mapping_ready<=1'b0;

            // Staged write (unpublished bank only). Nothing here can reach the
            // score that is currently being played.
            // A syntactically plausible payload is not an accepted request.
            // Never write staging before CRC/opcode/busy validation has finished.
            if (rx_valid && rx_state == R_CRC && rx_data == rx_crc &&
                rx_type == CMD_STEP && !busy && step_v1_valid) begin
                if (active_bank) begin
                    bank_a_mask[step_index]     <= step_v1_byte;
                    bank_a_duration[step_index] <= step_duration;
                end else begin
                    bank_b_mask[step_index]     <= step_v1_byte;
                    bank_b_duration[step_index] <= step_duration;
                end
            end
            if (rx_valid && rx_state == R_CRC && rx_data == rx_crc &&
                rx_type == CMD_STEP2 && !busy && step_v2_valid) begin
                if (active_bank) begin
                    bank_a_mask[step_index]     <= step_v2_byte;
                    bank_a_duration[step_index] <= step_duration;
                end else begin
                    bank_b_mask[step_index]     <= step_v2_byte;
                    bank_b_duration[step_index] <= step_duration;
                end
                // Accumulate the CRC over the staged payload plus the opcode,
                // so a step cannot be silently reordered between transactions.
                txn_steps_crc <= crc8_step2(txn_steps_crc, payload[0], payload[1], payload[2], payload[3], payload[4]);
            end

            if(pairing_ttl!=0)pairing_ttl<=pairing_ttl-26'd1;
            else panel_pairing_code<=0;
            if (rx_frame_error && framing_error_count != 16'hffff)
                framing_error_count <= framing_error_count + 1'b1;

            // Half-frame watchdog: an interrupted frame must resynchronise and
            // must never be completed with unrelated later bytes.
            if (rx_state != R_A5) begin
                if (rx_valid) gap_counter <= 0;
                else if (gap_counter >= FRAME_GAP_BITS*CLOCKS_PER_BIT - 1) begin
                    gap_counter <= 0;
                    rx_state <= R_A5;
                    if (framing_error_count != 16'hffff)
                        framing_error_count <= framing_error_count + 1'b1;
                end else gap_counter <= gap_counter + 1'b1;
            end else gap_counter <= 0;

            if (rx_valid) begin
                case (rx_state)
                    R_A5: if(rx_data==8'hA5) rx_state<=R_5A;
                    R_5A: if(rx_data==8'h5A) rx_state<=R_VER; else rx_state<=R_A5;
                    R_VER: begin rx_crc<=crc8_next(0,rx_data); rx_state<=R_TYPE;
                                   if(rx_data!=8'h01) rx_state<=R_A5; end
                    R_TYPE: begin rx_type<=rx_data; rx_crc<=crc8_next(rx_crc,rx_data); rx_state<=R_LEN; end
                    R_LEN: begin rx_len<=rx_data; rx_crc<=crc8_next(rx_crc,rx_data);
                                  if(rx_data<=8) rx_state<=R_SEQ; else rx_state<=R_A5; end
                    R_SEQ: begin rx_seq<=rx_data; rx_crc<=crc8_next(rx_crc,rx_data); rx_index<=0;
                                  if(rx_len==0) rx_state<=R_CRC; else rx_state<=R_PAYLOAD; end
                    R_PAYLOAD: begin
                        payload[rx_index] <= rx_data; rx_crc<=crc8_next(rx_crc,rx_data);
                        if(rx_index+1>=rx_len) rx_state<=R_CRC; else rx_index<=rx_index+1'b1;
                    end
                    R_CRC: begin
                        rx_state<=R_A5; if(rx_type!=CMD_PANEL)begin last_cmd_seq<=rx_seq;status_request<=1'b1;end
                        if(rx_data!=rx_crc) begin
                            if(rx_type!=CMD_PANEL) last_result<=RESULT_CRC;
                            if(crc_error_count!=16'hffff) crc_error_count<=crc_error_count+1'b1;
                        end else begin
                            if(rx_type!=CMD_PANEL)last_result<=RESULT_OK;
                            case(rx_type)
                                CMD_PANEL: begin
                                    // Internal S3 display metadata only, never a phone action.
                                    // Keep the last executed command identity/result unchanged.
                                    if(rx_len==3 && payload[2][6:4]==0 && {payload[2][3:0],payload[1],payload[0]}<=20'd999999) begin
                                        // Zero is a valid six-digit PIN. The internal-only
                                        // sentinel 1000000 renders six low digits as 000000;
                                        // zero itself remains the no-pairing-display state.
                                        panel_pairing_code<=payload[2][7] ?
                                            (({payload[2][3:0],payload[1],payload[0]}==0) ?
                                             20'd1000000:{payload[2][3:0],payload[1],payload[0]}) :20'd0;
                                        pairing_ttl<=26'(PANEL_TTL_CLOCKS);
                                    end
                                end
                                CMD_BEGIN: begin
                                    if (rx_len != 8'd2 || payload[1] < 8'd1 || payload[1] > MAX_STEPS)
                                        last_result<=RESULT_PARAM;
                                    else if (busy)
                                        last_result<=RESULT_BUSY;
                                    else begin
                                        txn_open  <= 1'b1;
                                        txn_v2    <= 1'b0;
                                        txn_song  <= payload[0];
                                        txn_count <= payload[1][6:0];
                                        txn_seg_index <= 8'd0; txn_seg_count <= 8'd1;
                                        txn_mask  <= '0;
                                        txn_steps_crc <= 8'd0;
                                    end
                                end
                                CMD_BEGIN2: begin
                                    // payload: song_id, count(1..63), segment_index, segment_count
                                    if (rx_len != 8'd4 || payload[1] < 8'd1 ||
                                        payload[1] > V2_MAX_STEPS || payload[3] < 8'd1 || payload[2]>=payload[3])
                                        last_result<=RESULT_PARAM;
                                    else if (busy)
                                        last_result<=RESULT_BUSY;
                                    else begin
                                        txn_open  <= 1'b1;
                                        txn_v2    <= 1'b1;
                                        txn_song  <= payload[0];
                                        txn_count <= payload[1][6:0];
                                        txn_seg_index <= payload[2];
                                        txn_seg_count <= payload[3];
                                        txn_mask  <= '0;
                                        txn_steps_crc <= 8'd0;
                                    end
                                end
                                CMD_STEP: begin
                                    if (!txn_open)              last_result<=RESULT_NO_TXN;
                                    else if (txn_v2)            last_result<=RESULT_OPCODE;
                                    else if (rx_len != 8'd5)    last_result<=RESULT_PARAM;
                                    else if (busy)              last_result<=RESULT_BUSY;
                                    else if (!step_v1_valid)    last_result<=RESULT_PARAM;
                                    else txn_mask[step_index] <= 1'b1;
                                end
                                CMD_STEP2: begin
                                    if (!txn_open)              last_result<=RESULT_NO_TXN;
                                    else if (!txn_v2)           last_result<=RESULT_OPCODE;
                                    else if (rx_len != 8'd5)    last_result<=RESULT_PARAM;
                                    else if (busy)              last_result<=RESULT_BUSY;
                                    else if (!step_v2_valid)    last_result<=RESULT_PARAM;
                                    else txn_mask[step_index] <= 1'b1;
                                end
                                CMD_COMMIT: begin
                                    if (!txn_open)            last_result<=RESULT_NO_TXN;
                                    else if (txn_v2)          last_result<=RESULT_OPCODE;
                                    else if (busy)            last_result<=RESULT_BUSY;
                                    else if (!commit_ok)      last_result<=RESULT_COMMIT;
                                    else begin
                                        // Atomic publish: one bank swap.
                                        active_bank  <= ~active_bank;
                                        song_id      <= txn_song;
                                        score_length <= txn_count;
                                        score_loaded <= 1'b1;
                                        score_mapping_ready<=1'b1;
                                        score_segment_index <= 8'd0;
                                        score_segment_count <= 8'd1;
                                        txn_open     <= 1'b0;
                                        txn_mask     <= '0;
                                    end
                                end
                                CMD_FX: begin
                                    if (rx_len != 8'd1 || payload[0] > 8'd3)
                                        last_result<=RESULT_PARAM;
                                    else if (busy)
                                        last_result<=RESULT_BUSY;
                                    else begin
                                        fx_mode_out <= payload[0][1:0];
                                        last_result <= RESULT_OK;
                                    end
                                end
                                CMD_COMMIT2: begin
                                    if (!txn_open)            last_result<=RESULT_NO_TXN;
                                    else if (!txn_v2)         last_result<=RESULT_OPCODE;
                                    else if (busy)            last_result<=RESULT_BUSY;
                                    else if (!commit2_ok)     last_result<=RESULT_COMMIT;
                                    else begin
                                        // Atomic publish: one bank swap, v2 identity.
                                        active_bank  <= ~active_bank;
                                        song_id      <= txn_song;
                                        score_length <= txn_count;
                                        score_loaded <= 1'b1;
                                        score_mapping_ready<=1'b1;
                                        score_segment_index <= txn_seg_index;
                                        score_segment_count <= txn_seg_count;
                                        txn_open     <= 1'b0;
                                        txn_mask     <= '0;
                                    end
                                end
                                8'h20: begin
                                    if(rx_len!=4 || payload[0]>2 || payload[1]>4)last_result<=RESULT_PARAM;
                                    else last_result<=practice_result;
                                end
                                CMD_GUIDE: begin
                                    // 0 = stop, 1 = guided practice, 2 = challenge.
                                    if(audition_active && payload[0]!=0)last_result<=RESULT_BUSY;
                                    else if (rx_len != 8'd1 || payload[0] > 8'd2)
                                        last_result<=RESULT_GUIDE;
                                    else if (payload[0] != 8'd0 && (!score_loaded || !score_mapping_ready))
                                        last_result<=RESULT_GUIDE;
                                    else begin
                                        remote_guide_mode <= payload[0][1:0];
                                        remote_guide_pulse<=1'b1;
                                    end
                                end
                                CMD_PING: begin
                                    if (rx_len != 8'd0) last_result<=RESULT_PARAM;
                                end
                                CMD_CONFIG: begin
                                    if (rx_len != 8'd8 || payload[0] > 8'd5)
                                        last_result<=RESULT_PARAM;
                                    else begin
                                        cfg_req_valid <= 1'b1;
                                        cfg_req_op    <= payload[0][2:0];
                                        cfg_req_field <= payload[1];
                                        cfg_req_value <= {payload[3], payload[2]};
                                        cfg_req_token <= {payload[5], payload[4]};
                                        cfg_req_seq   <= {payload[7], payload[6]};
                                        cfg_op_echo   <= payload[0];
                                        cfg_field_echo<= payload[1];
                                    end
                                end
                                8'h1b,8'h1c,8'h1d,8'h1e,8'h1f:last_result<=audition_result;
                                default: last_result<=RESULT_OPCODE;
                            endcase
                            // A CONFIG command must not overwrite the score result that
                            // the status frame reports: its answer travels in 0x81.
                            if (rx_type == CMD_CONFIG) begin
                                last_result  <= last_result;
                                last_cmd_seq <= last_cmd_seq;
                            end
                        end
                    end
                    default: rx_state<=R_A5;
                endcase
            end
        end
    end

    logic tx_start, tx_busy, tx_rejected; logic [7:0] tx_data;
    uart_tx #(.CLOCKS_PER_BIT(CLOCKS_PER_BIT)) transmitter (
        .clk, .rst_n, .start(tx_start), .data(tx_data), .tx(uart_tx_o),
        .busy(tx_busy), .rejected(tx_rejected));
    logic [31:0] status_counter;
    logic sending; logic [5:0] tx_index; logic [7:0] tx_crc, status_sequence;
    logic frame_req;
    // Which frame the transmitter is currently draining, and the index of its CRC
    // byte: 21 for the 21-byte status frame, 17 for the 18-byte config reply.
    // 0=status 1=cfg 2=mobile 3=voice 4=event (T2 0x85).
    logic [2:0] tx_kind;
    logic[7:0]snap_sequence;
    wire mobile_ready;wire[7:0]mobile_kind;wire[5:0]mobile_length;wire[303:0]mobile_body;
    logic[7:0]snap_mobile_kind;logic[5:0]snap_mobile_length;logic[303:0]snap_mobile_body;
    logic[5:0]snap_voice_length;logic[359:0]snap_voice_body;
    // Match the sender's arbitration exactly. A ready producer may only pop
    // when THIS frame is selected; snapshots remain pending behind replies/events.
    wire mobile_take=ENABLE_MOBILE && !sending && !tx_busy && !frame_req && !cfg_frame_req && !event_ready && mobile_ready;
    generate if(ENABLE_MOBILE)begin:g_mobile
      mobile_observer observer(.clk,.rst_n,.sample_ce(audition_sample_ce),.pcm(mobile_pcm),.state_payload(mobile_state),
        .ready(mobile_ready),.kind(mobile_kind),.length(mobile_length),.body(mobile_body),.take(mobile_take));
    end else begin assign mobile_ready=0;assign mobile_kind=0;assign mobile_length=0;assign mobile_body=0;end endgenerate
    // 0x84 four-voice status: lowest TX priority (status/ACK first, telemetry drops old).
    wire voice_ready;wire[5:0]voice_length;wire[359:0]voice_body;
    generate if(ENABLE_MOBILE)begin:g_voice
      voice_status_stream voice_stream(.clk,.rst_n,.sample_ce(audition_sample_ce),
        .lane_pcm(eng_lane_pcm),.voice_partials(eng_voice_partials),.voice_gains(eng_voice_gains),
        .voice_generation(eng_voice_generation),.voice_gates(eng_voice_gates),
        .voice_note_active(eng_note_active),.voice_presets(eng_voice_presets),
        .voice_notes(eng_voice_notes),.voice_regions(eng_voice_regions),.voice_envelopes(eng_voice_envelopes),
        .voice_phase_incs(eng_phase_incs),.grant_count(eng_grant_count),
        .effect_family(eng_effect_family),.budget_violation(eng_budget_violation),
        .ready(voice_ready),.kind(),.length(voice_length),.body(voice_body),.take(voice_take));
    end else begin assign voice_ready=0;assign voice_length=0;assign voice_body=0;end endgenerate
    wire voice_take=ENABLE_MOBILE && !sending && !tx_busy && !frame_req && !cfg_frame_req && !event_ready && !mobile_ready && voice_ready;
    // T2 0x85 event frames: above the periodic snapshots, below ACK/config.
    // take is a REGISTERED one-clock pulse raised on the same edge the mux
    // snapshots the body, so the producer pops exactly one frame per frame sent
    // (a level take would drain the whole queue into the void while idle).
    logic event_take_r;
    assign event_take=event_take_r;
    logic[5:0]snap_event_length;logic[63:0]snap_event_body;
    logic stats_take_r;assign stats_take=stats_take_r;
    logic[5:0]snap_stats_length;logic[111:0]snap_stats_body;
    function automatic logic[7:0] stats_byte(input logic[5:0] index);
      case(index)
       0:stats_byte=8'ha5;1:stats_byte=8'h5a;2:stats_byte=1;3:stats_byte=8'h86;
       4:stats_byte={2'd0,snap_stats_length};5:stats_byte=snap_sequence;
       default:stats_byte=snap_stats_body[(index-6)*8+:8];
      endcase
    endfunction
    function automatic logic[7:0] event_byte(input logic[5:0] index);
      case(index)
       0:event_byte=8'ha5;1:event_byte=8'h5a;2:event_byte=1;3:event_byte=8'h85;
       4:event_byte={2'd0,snap_event_length};5:event_byte=snap_sequence;
       default:event_byte=snap_event_body[(index-6)*8+:8];
      endcase
    endfunction
    function automatic logic[7:0] mobile_byte(input logic[5:0] index);
      case(index)
       0:mobile_byte=8'ha5;1:mobile_byte=8'h5a;2:mobile_byte=1;3:mobile_byte=snap_mobile_kind;
       4:mobile_byte={2'd0,snap_mobile_length};5:mobile_byte=snap_sequence;
       default:mobile_byte=snap_mobile_body[(index-6)*8+:8];
      endcase
    endfunction
    function automatic logic[7:0] voice_byte(input logic[5:0] index);
      case(index)
       0:voice_byte=8'ha5;1:voice_byte=8'h5a;2:voice_byte=1;3:voice_byte=8'h84;
       4:voice_byte={2'd0,snap_voice_length};5:voice_byte=snap_sequence;
       default:voice_byte=snap_voice_body[(index-6)*8+:8];
      endcase
    endfunction
    wire[7:0]selected_tx_byte = (tx_kind == 3'd5) ? stats_byte(tx_index)    :
                                (tx_kind == 3'd4) ? event_byte(tx_index)    :
                                (tx_kind == 3'd3) ? voice_byte(tx_index)    :
                                (tx_kind == 3'd2) ? mobile_byte(tx_index)   :
                                (tx_kind == 3'd1) ? cfg_reply_byte(tx_index) :
                                                    status_byte(tx_index);
    logic [5:0]  tx_last;

    // Full snapshot latched once per status frame: a command arriving in the
    // middle of a frame can no longer mix fields from two different instants.
    logic [7:0]  snap_song, snap_flags, snap_step, snap_zone_expression;
    logic [15:0] snap_hits, snap_wrong, snap_miss;
    logic [7:0]  snap_meta, snap_partial, snap_wet, snap_cmd_seq, snap_result;


    function automatic logic [7:0] status_byte(input logic [5:0] index);
        begin case(index)
            0:status_byte=8'hA5; 1:status_byte=8'h5A; 2:status_byte=8'h01;
            3:status_byte=8'h80; 4:status_byte=8'd15; 5:status_byte=snap_sequence;
            6:status_byte=snap_song;
            7:status_byte=snap_flags;
            8:status_byte=snap_step;
            9:status_byte=snap_zone_expression;
            10:status_byte=snap_hits[7:0];  11:status_byte=snap_hits[15:8];
            12:status_byte=snap_wrong[7:0]; 13:status_byte=snap_wrong[15:8];
            14:status_byte=snap_miss[7:0];  15:status_byte=snap_miss[15:8];
            16:status_byte=snap_meta; 17:status_byte=snap_partial;
            18:status_byte=snap_wet; 19:status_byte=snap_cmd_seq; 20:status_byte=snap_result;
            default:status_byte=0;
        endcase end
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            status_counter<=0; sending<=0; tx_index<=0; tx_crc<=0; frame_req<=0;
            tx_start<=0; tx_data<=8'hff; status_sequence<=0;
            tx_kind<=3'd0;snap_mobile_kind<=0;snap_mobile_length<=0;snap_mobile_body<=0; tx_last<=6'd21;
            snap_event_length<=0;snap_event_body<=0;event_take_r<=0;
            snap_stats_length<=0;snap_stats_body<=0;stats_take_r<=0;
            cfg_frame_req<=1'b0; cfg_r_op<=8'd0; cfg_r_field<=8'd0; cfg_r_result<=8'd0;
            cfg_r_first<=8'd0; cfg_r_sequence<=8'd0; cfg_r_value<=16'd0;
            cfg_r_epoch<=16'd0; cfg_r_mask<=22'd0;
            snap_song<=0; snap_flags<=0; snap_step<=0; snap_zone_expression<=0;
            snap_hits<=0; snap_wrong<=0; snap_miss<=0; snap_meta<=0; snap_partial<=0;
            snap_wet<=0; snap_cmd_seq<=0; snap_result<=0; snap_sequence<=0;
            cfg_reply_seen<=1'b0;
        end else begin
            tx_start<=0;
            event_take_r<=1'b0;
            stats_take_r<=1'b0;
            cfg_reply_seen<=1'b0;
            if(status_counter>=STATUS_INTERVAL-1) begin status_counter<=0; frame_req<=1'b1; end
            else status_counter<=status_counter+1'b1;
            if(status_request) frame_req<=1'b1;

            // A configuration answer takes priority over the periodic status frame:
            // the client is blocked waiting for it. The status frame is not lost,
            // because its request flag is left set and the sender picks it up next.
            if (cfg_ack) begin
                cfg_r_op       <= cfg_op_echo;
                cfg_r_field    <= cfg_field_echo;
                cfg_r_result   <= cfg_result;
                cfg_r_value    <= cfg_reply_value;
                cfg_r_epoch    <= cfg_epoch;
                cfg_r_mask     <= cfg_supported;
                cfg_r_first    <= cfg_first_field;
                // Echo the REQUEST sequence in the frame header so a client with more
                // than one request in flight can match answer to question exactly.
                cfg_r_sequence <= cfg_req_seq[7:0];
                cfg_frame_req  <= 1'b1;
                cfg_reply_seen <= 1'b1;
            end

            if (!sending && (frame_req || cfg_frame_req || (ENABLE_MOBILE && (mobile_ready || voice_ready || event_ready || stats_ready))) && !tx_busy) begin
                sending      <= 1'b1;
                tx_index     <= 0;
                tx_crc       <= 0;
                if (cfg_frame_req) begin
                    cfg_frame_req <= 1'b0;
                    tx_kind       <= 3'd1;
                    tx_last       <= 6'd17;
                end else if(frame_req) begin
                    frame_req     <= 1'b0;
                    tx_kind       <= 3'd0;
                    tx_last       <= 6'd21;
                end else if (event_ready) begin
                    tx_kind<=3'd4;tx_last<=event_length+6'd6;
                    snap_event_length<=event_length;snap_event_body<=event_body;
                    event_take_r<=1'b1;
                end else if (mobile_ready) begin
                    tx_kind<=3'd2;tx_last<=mobile_length+6'd6;
                    snap_mobile_kind<=mobile_kind;snap_mobile_length<=mobile_length;snap_mobile_body<=mobile_body;
                end else if (voice_ready) begin
                    tx_kind<=3'd3;tx_last<=voice_length+6'd6;
                    snap_voice_length<=voice_length;snap_voice_body<=voice_body;
                end else if (stats_ready) begin
                    tx_kind<=3'd5;tx_last<=stats_length+6'd6;
                    snap_stats_length<=stats_length;snap_stats_body<=stats_body;
                    stats_take_r<=1'b1;
                end else begin
                    tx_kind<=3'd2;tx_last<=mobile_length+6'd6;
                    snap_mobile_kind<=mobile_kind;snap_mobile_length<=mobile_length;snap_mobile_body<=mobile_body;
                end
                snap_sequence<= status_sequence;
                snap_song    <= song_id;
                // Bits 0-4 keep their R3 meaning; bits[6:5] carry the new mode
                // (all v1 parsers ignore them, so the frame stays compatible).
                snap_flags   <= {EXTENDED_STATUS,(audition_active?2'd3:panel_mode),calibrated,panic_mute,test_mode,guide_active,score_loaded};
                snap_step    <= {2'd0,(audition_active?audition_step:current_step)};
                snap_zone_expression <= panel_mode==0 ? {score_target_mask,score_expression,score_target_zone} :
                    {panel_target,panel_expression,(panel_target[0]?2'd0:panel_target[1]?2'd1:panel_target[2]?2'd2:2'd3)};
                snap_hits    <= hit_count; snap_wrong <= wrong_count; snap_miss <= miss_count;
                snap_meta    <= EXTENDED_STATUS ? {1'b0,score_mapping_ready,(audition_active?audition_preset:panel_preset),fx_mode_out,note_layout} : {6'd0,note_layout};
                snap_partial <= {2'd0,partial_target};
                snap_wet     <= wet_target;
                snap_cmd_seq <= last_cmd_seq;
                snap_result  <= last_result;
                status_sequence <= status_sequence + 1'b1;
            end else if (sending && !tx_busy && !tx_start) begin
                if(tx_index==tx_last) begin
                    tx_data<=tx_crc; tx_start<=1; tx_index<=0; sending<=0;
                end else begin
                    tx_data<=selected_tx_byte;
                    tx_start<=1;
                    if(tx_index==0) tx_crc<=0;
                    else if(tx_index>=2) tx_crc <= crc8_next(tx_crc,selected_tx_byte);
                    tx_index<=tx_index+1'b1;
                end
            end
        end
    end
endmodule
