// Diagnostic reporter: turns the scan/expression state into a byte stream a PC can read.
//
// WHY: the MCP3208 has no readable register file. To verify channel identity and a known
// voltage on the bench (tutorial H2) the operator needs the raw codes, and the tutorial says
// the implementer must supply a real protocol rather than assume a serial console exists.
//
// PROTOCOL (one 8N1 UART byte at a time; every multi-byte field is big endian):
//
//   record := 0xA5 0x5A type payload checksum
//   checksum := (type + payload bytes) mod 256
//
//   type 0x01, one conversion (3 payload bytes)
//        byte 0: flags = {4'b0000, channel[2:0], 1'b1}
//        byte 1: code[11:8]
//        byte 2: code[7:0]
//   type 0x02, full status (1 + 5*4 = 21 payload bytes)
//        byte 0    : frame_id[7:0]
//        bytes 4*i+1 .. 4*i+4 for channel i:
//            pressure[15:8], pressure[7:0], age[7:0], flags
//            flags = {3'b000, valid, calibrated, stale, gate}
//
// PROTOCOL VERSION 2 (the product default, PROTOCOL_VERSION = 2). The v1 records above are kept
// unchanged so old captures stay parseable; v2 adds a 16-bit global record_seq number to EVERY
// record, which is what lets a PC detect a record that was lost as a whole rather than only a
// corrupted byte inside one. A record_seq number that appears only in status records could not do
// that, so it is carried by the conversion records too.
//
//   type 0x11, one conversion (5 payload bytes)
//        byte 0    : seq[15:8]      byte 1: seq[7:0]
//        byte 2    : flags = {4'b0000, channel[2:0], 1'b1}
//        bytes 3,4 : code[11:8], code[7:0]
//   type 0x12, full status (29 payload bytes)
//        bytes 0,1 : seq[15:8], seq[7:0]
//        byte  2   : frame_id[7:0]
//        bytes 3..22 for channel i (i = 0..4, four bytes each):
//            pressure[15:8], pressure[7:0], age[7:0], flags (same encoding as v1)
//        bytes 23,24: changes_coalesced[15:8], [7:0]
//        bytes 25,26: uart_rejected[15:8], [7:0]     (bytes lost to a busy transmitter)
//        bytes 27,28: scan_timeouts[15:8], [7:0]     (converter frames that timed out)
//
// POLICY (what a bench operator actually needs):
//   * a conversion record is sent only when that channel's code moved by at least
//     REPORT_DELTA since it was last reported, so an idle instrument is quiet and a slow
//     serial link is never asked to carry five 1 kHz channels plus 24-byte status records;
//   * a status record is sent every STATUS_DIV scan frames (default 10);
//   * while a record is being shifted out, further changes are COALESCED into the next
//     record and counted in changes_coalesced. Nothing is dropped silently, and no byte is
//     ever lost because there is no queue to overflow.
//
// The first version of this module used a byte FIFO. Writing its count from both the push and
// the pop path in the same clock made the count drift, and the FIFO started reporting empty
// while bytes were still queued - the second sync byte of the first record vanished. The
// current design serialises records directly and stalls until the transmitter is free, which
// removes that entire class of bug at the cost of up to one record of latency.
//
// STATUS: simulation complete. sim/tb_uart_tx.sv verifies the 8N1 waveform clock by clock (it
// caught a real defect: the last data bit was one clock wide), and sim/tb_diag_reporter.sv
// verifies the records - envelope, checksums, all five channel identities, the frame id, the
// zone pressure, quiet operation, the delta threshold and the coalescing counter. The pin, the
// baud tolerance and the physical link are UNTESTED.
//
// Original status line kept for context: simulation complete (sim/tb_diag_reporter.sv decodes the stream and checks framing,
// checksum and content); the serial link itself, its pin and its baud tolerance are UNTESTED.
module diag_reporter #(
    parameter integer      REPORT_DELTA     = 8,
    parameter integer      STATUS_DIV       = 10,
    // 2 = the product protocol (0x11/0x12 with a record_seq number), 1 = the legacy record set
    // (0x01/0x02). The parser in model/parse_diag_uart.py accepts both.
    parameter integer      PROTOCOL_VERSION = 2
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        code_valid,
    input  logic [2:0]  channel,
    input  logic [11:0] code,
    input  logic        frame_done,
    input  logic [7:0]  frame_id,
    input  logic [79:0] zone_pressure,
    input  logic [39:0] zone_age,
    input  logic [4:0]  zone_gate,
    input  logic [4:0]  zone_stale,
    input  logic [4:0]  zone_calibrated,
    input  logic [4:0]  zone_valid,
    output logic        uart_start,
    output logic [7:0]  uart_data,
    input  logic        uart_busy,
    input  logic        uart_rejected,      // one-clock pulse from rtl/uart_tx.sv
    input  logic [15:0] scan_timeouts,      // converter frame timeouts, for the status record
    output logic [15:0] records_sent,
    output logic [15:0] changes_coalesced
);
    localparam logic [7:0] SYNC_A = 8'hA5;
    localparam logic [7:0] SYNC_B = 8'h5A;
    localparam logic [2:0] REC_NONE      = 3'd0;
    localparam logic [2:0] REC_CONV      = 3'd1;   // 0x01
    localparam logic [2:0] REC_STATUS    = 3'd2;   // 0x02
    localparam logic [2:0] REC_CONV_V2   = 3'd3;   // 0x11
    localparam logic [2:0] REC_STATUS_V2 = 3'd4;   // 0x12

    logic [59:0] last_code;        // 5 x 12 bits, last REPORTED value per channel
    logic [59:0] latest_code;      // 5 x 12 bits, most recent value seen per channel
    logic [4:0]  code_seen;
    logic [2:0]  round_robin;      // next channel to consider, so every channel gets a turn
    logic [2:0]  pending_channel;
    logic [11:0] pending_code;
    logic        conv_pending;
    logic [7:0]  status_divider;
    logic [15:0] frames_seen;      // counted even while a record is being sent
    logic [15:0] last_status_frame;

    logic [2:0]  rec_type;
    logic [5:0]  rec_index;
    logic [5:0]  rec_length;
    logic        rec_active;
    logic [2:0]  conv_channel;
    logic [11:0] conv_code;
    logic [7:0]  checksum_acc;
    logic [7:0]  push_byte;
    logic [7:0]  rec_type_byte;           // the WIRE code of the record type (0x01/0x02/0x11/0x12)
    logic        last_byte;

    logic [15:0] record_seq;              // global record sequence number (protocol v2)
    logic [15:0] next_record_seq;         // what the record being started will carry
    logic [15:0] uart_rejected_count;   // bytes the transmitter refused because it was busy
    logic [5:0]  status_slot;           // payload slot inside a status record, v1 and v2 alike

    logic [2:0]  next_channel;
    logic [11:0] next_code;
    logic        detect;
    logic [2:0]  detect_channel;
    logic [11:0] detect_code;
    logic [11:0] last_value;
    logic [11:0] delta;

    // The internal record-type enum is NOT the wire code: the v2 types are 0x11 and 0x12, so the
    // byte that goes on the wire is decoded here instead of happening to equal the enum value.
    always_comb begin
        case (rec_type)
            REC_CONV:      rec_type_byte = 8'h01;
            REC_STATUS:    rec_type_byte = 8'h02;
            REC_CONV_V2:   rec_type_byte = 8'h11;
            REC_STATUS_V2: rec_type_byte = 8'h12;
            default:       rec_type_byte = 8'h00;
        endcase
    end

    assign next_record_seq = record_seq + 16'd1;

    // ---- the byte the current record position carries ---------------------------
    // status_slot is the offset inside the per-channel block of a status record. The v1 and v2
    // status records carry the same five four-byte channel blocks; only their offset differs,
    // so the decoding is written once.
    always_comb begin
        push_byte   = 8'h00;
        status_slot = 6'd0;
        if (rec_index == 6'd0)      push_byte = SYNC_A;
        else if (rec_index == 6'd1) push_byte = SYNC_B;
        else if (rec_index == 6'd2) push_byte = rec_type_byte;
        else if (rec_index == rec_length + 6'd3) push_byte = checksum_acc;
        else begin
            case (rec_type)
                REC_CONV: begin
                    case (rec_index)
                        6'd3: push_byte = {4'b0000, conv_channel, 1'b1};
                        6'd4: push_byte = {4'b0000, conv_code[11:8]};
                        default: push_byte = conv_code[7:0];
                    endcase
                end
                REC_CONV_V2: begin
                    case (rec_index)
                        6'd3: push_byte = record_seq[15:8];
                        6'd4: push_byte = record_seq[7:0];
                        6'd5: push_byte = {4'b0000, conv_channel, 1'b1};
                        6'd6: push_byte = {4'b0000, conv_code[11:8]};
                        default: push_byte = conv_code[7:0];
                    endcase
                end
                REC_STATUS: begin
                    if (rec_index == 6'd3) begin
                        push_byte = frame_id;
                    end else begin
                        status_slot = rec_index - 6'd4;
                        case (status_slot % 6'd4)
                            6'd0: push_byte = zone_pressure[(status_slot / 6'd4)*16 + 8 +: 8];
                            6'd1: push_byte = zone_pressure[(status_slot / 6'd4)*16 +: 8];
                            6'd2: push_byte = zone_age[(status_slot / 6'd4)*8 +: 8];
                            default: push_byte = {3'b000, zone_valid[(status_slot / 6'd4)],
                                                                zone_calibrated[(status_slot / 6'd4)],
                                                                zone_stale[(status_slot / 6'd4)],
                                                                zone_gate[(status_slot / 6'd4)]};
                        endcase
                    end
                end
                REC_STATUS_V2: begin
                    if (rec_index == 6'd3) begin
                        push_byte = record_seq[15:8];
                    end else if (rec_index == 6'd4) begin
                        push_byte = record_seq[7:0];
                    end else if (rec_index == 6'd5) begin
                        push_byte = frame_id;
                    end else if (rec_index <= 6'd25) begin
                        status_slot = rec_index - 6'd6;
                        case (status_slot % 6'd4)
                            6'd0: push_byte = zone_pressure[(status_slot / 6'd4)*16 + 8 +: 8];
                            6'd1: push_byte = zone_pressure[(status_slot / 6'd4)*16 +: 8];
                            6'd2: push_byte = zone_age[(status_slot / 6'd4)*8 +: 8];
                            default: push_byte = {3'b000, zone_valid[(status_slot / 6'd4)],
                                                                zone_calibrated[(status_slot / 6'd4)],
                                                                zone_stale[(status_slot / 6'd4)],
                                                                zone_gate[(status_slot / 6'd4)]};
                        endcase
                    end else begin
                        case (rec_index)
                            6'd26: push_byte = changes_coalesced[15:8];
                            6'd27: push_byte = changes_coalesced[7:0];
                            6'd28: push_byte = uart_rejected_count[15:8];
                            6'd29: push_byte = uart_rejected_count[7:0];
                            6'd30: push_byte = scan_timeouts[15:8];
                            default: push_byte = scan_timeouts[7:0];
                        endcase
                    end
                end
                default: push_byte = 8'h00;
            endcase
        end
    end

    assign last_byte = (rec_index == rec_length + 6'd3);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            last_code         <= 60'd0;
            latest_code       <= 60'd0;
            code_seen         <= 5'd0;
            round_robin       <= 3'd0;
            pending_channel   <= 3'd0;
            pending_code      <= 12'd0;
            conv_pending      <= 1'b0;
            status_divider    <= 8'd0;
            frames_seen       <= 16'd0;
            last_status_frame <= 16'd0;
            rec_type          <= REC_NONE;
            rec_index         <= 6'd0;
            rec_length        <= 6'd0;
            rec_active        <= 1'b0;
            conv_channel      <= 3'd0;
            conv_code         <= 12'd0;
            checksum_acc      <= 8'd0;
            uart_start        <= 1'b0;
            uart_data         <= 8'd0;
            records_sent      <= 16'd0;
            changes_coalesced <= 16'd0;
            record_seq          <= 16'd0;
            uart_rejected_count <= 16'd0;
        end else begin
            uart_start <= 1'b0;

            // A byte the transmitter refused is counted, never ignored: a rejected start pulse
            // means a byte of a record did not go out, and the status record reports it.
            if (uart_rejected && (uart_rejected_count != 16'hffff))
                uart_rejected_count <= uart_rejected_count + 16'd1;
            detect         = 1'b0;
            detect_channel = 3'd0;
            detect_code    = 12'd0;

            // ---- who moved? ----------------------------------------------------
            if (code_valid) begin
                last_value = last_code[channel*12 +: 12];
                latest_code[channel*12 +: 12] <= code;
                code_seen[channel] <= 1'b1;
                if (!code_seen[channel]) begin
                    detect = 1'b1;              // first sample of a channel is always sent
                end else begin
                    delta = (code > last_value) ? (code - last_value) : (last_value - code);
                    if (delta >= REPORT_DELTA[11:0]) detect = 1'b1;
                end
                if (detect) begin
                    detect_channel = channel;
                    detect_code    = code;
                end
            end

            // ---- serialise one record at a time --------------------------------
            if (!rec_active) begin
                // Strict round robin over the five channels: a channel is reported when its
                // value differs from the last REPORTED one, and the pointer always advances.
                // A "newest change wins" policy would spend the whole slow link on whichever
                // electrode moved last and never show the others.
                round_robin <= (round_robin == 3'd4) ? 3'd0 : round_robin + 3'd1;
                next_channel = round_robin;
                next_code    = latest_code[round_robin*12 +: 12];
                if (code_seen[round_robin] &&
                    (next_code != last_code[round_robin*12 +: 12])) begin
                    // Start a conversion record for this channel, lowest index first, one record
                    // per turn: a slow link then still shows every electrode.
                    rec_active   <= 1'b1;
                    rec_index    <= 6'd0;
                    conv_channel <= next_channel;
                    conv_code    <= next_code;
                    record_seq     <= record_seq + 16'd1;
                    // The flags byte is {4'b0000, channel[2:0], 1'b1}: exactly eight bits, so the
                    // sum is built from eight-bit operands only. A nine-bit operand here (the
                    // first version wrote {5'd0, ...}) produces the same value but makes the
                    // synthesiser report an expression-width truncation, so the width is fixed
                    // rather than tolerated.
                    // v2 carries the record_seq number in the payload as well, so the whole sum is
                    // seeded here for both versions.
                    if (PROTOCOL_VERSION >= 2) begin
                        rec_type     <= REC_CONV_V2;
                        rec_length   <= 6'd5;
                        // Seeded from the sequence number the record WILL carry: the register
                        // is loaded on the same edge, so reading it here would put the previous
                        // value in the checksum and make every conversion record fail its sum.
                        checksum_acc <= 8'h11 + next_record_seq[15:8] + next_record_seq[7:0]
                                        + {4'b0000, next_channel, 1'b1}
                                        + {4'b0000, next_code[11:8]} + next_code[7:0];
                    end else begin
                        rec_type     <= REC_CONV;
                        rec_length   <= 6'd3;
                        checksum_acc <= 8'h01 + {4'b0000, next_channel, 1'b1}
                                        + {4'b0000, next_code[11:8]} + next_code[7:0];
                    end
                    last_code[next_channel*12 +: 12] <= next_code;
                end else if ((frames_seen - last_status_frame) >= STATUS_DIV[15:0]) begin
                    last_status_frame <= frames_seen;
                    rec_active     <= 1'b1;
                    rec_index      <= 6'd0;
                    record_seq       <= record_seq + 16'd1;
                    if (PROTOCOL_VERSION >= 2) begin
                        rec_type     <= REC_STATUS_V2;
                        rec_length   <= 6'd29;   // seq(2) + frame(1) + 5*4 channels + 3 counters
                        checksum_acc <= 8'h12;   // the type byte; payload is added as it goes
                    end else begin
                        rec_type     <= REC_STATUS;
                        rec_length   <= 6'd21;
                        checksum_acc <= 8'h02;   // the type byte; payload is added as it goes
                    end
                end
            end else begin
                if (!uart_busy && !(uart_start)) begin
                    uart_data  <= push_byte;
                    uart_start <= 1'b1;
                    if (last_byte) begin
                        rec_active   <= 1'b0;
                        records_sent <= records_sent + 16'd1;
                    end else begin
                        rec_index <= rec_index + 6'd1;
                        // Only payload bytes are added, because checksum_acc was seeded with the
                        // type byte when the record started (rec_index 2 IS that type byte) and
                        // the v1 conversion record seeds its complete payload at the same time.
                        // Every other record type adds its payload byte by byte.
                        if ((rec_type != REC_CONV) && (rec_type != REC_CONV_V2) && (rec_index >= 6'd3))
                            checksum_acc <= checksum_acc + push_byte;
                    end
                end
            end

            // Frames are counted unconditionally: a frame that arrives while a record is being
            // shifted out must still schedule the next status record, otherwise a slow link
            // silently loses status updates.
            if (frame_done && (frames_seen != 16'hffff)) frames_seen <= frames_seen + 16'd1;

            // ---- queue a detected change, in ONE place ---------------------------
            // A change that arrives while a record is being serialised, or while another change
            // is already queued, is coalesced: the newest position is kept and the coalescing is
            // counted. No change disappears without a counter moving.
            if (detect) begin
                // A change that is waiting for its turn is superseded by this newer value; the
                // counter records that, so nothing disappears without a number moving.
                if ((latest_code[detect_channel*12 +: 12] != detect_code) &&
                    (last_code[detect_channel*12 +: 12] != detect_code))
                    changes_coalesced <= changes_coalesced + 16'd1;
            end
        end
    end
endmodule