// Performance visualisation / telemetry stream (competition add-on).
//
// WHY: the instrument already proves what it plays through the audio it makes, but a demo also
// wants the internal performance state on a PC screen. This module is the FPGA half of that
// link: it watches the post-mix audio and the live performance state, and pushes one
// self-contained frame at a time out of the on-board UART (pin U15, 115200 8N1, FPGA output,
// 12.288 MHz clock), so a PC can draw an oscilloscope plus a performance panel with no extra
// hardware.
//
// The frozen baseline configurations A/B/C are NOT touched: this block only READS signals that
// already exist in the design, drives nothing except its own UART pin, and is not instantiated
// by any frozen configuration. Nothing here may feed back into the audio path.
//
// ---------------------------------------------------------------------------------------------
// PROTOCOL (one 8N1 UART byte at a time; CLOCKS_PER_BIT clocks per bit; all multi-byte fields
// are LITTLE ENDIAN, low byte first):
//
//   frame := 0xA5 type LEN payload[LEN] checksum
//
//   Two record types share one envelope:
//     type 0x21  the wave frame: the decimated oscilloscope window plus the mix/voice state. Its
//                payload is UNCHANGED from the previous revision and so is its LEN = 19 + POINTS
//                = 51 bytes; no field was inserted, because a PC decoder that already trusts the
//                '19 + i' wave offsets must keep working.
//     type 0x22  the performance record: the four zone pressures, the zone gates, the owner voice,
//                the ACTUAL number of sounding partials, the partial mask, the chorus
//                mode/peak/clip and the window clip flag. LEN = 27 bytes, no wave points.
//                When SCOPE_DIAG=1, 12 more bytes are appended (LEN = 39): CH6/CH7 raw codes,
//                joystick status, selected preset, target/active wet gain and exact signed
//                16-bit pre-effect/DAC PCM samples. The original 27 offsets remain unchanged.
//
//   LEN      := payload byte count of that type: 19 + POINTS for 0x21, 27 for 0x22
//               (51 bytes with the default POINTS = 32)
//   checksum := low eight bits of (0xA5 + type + LEN + every payload byte)
//               i.e. every byte of the frame from the sync byte up to and including the last
//               payload byte is summed with eight-bit wrap-around; the checksum byte itself is
//               not part of the sum, and the type byte IS one of the terms.
//
//   --- type 0x21: payload offsets (0-based) ---
//     0       : seq[7:0]                1       : seq[15:8]
//     2       : flags = {5'b00000, clip, wet, add}
//                 bit0 add  - the additive/partial layer is active for this frame, i.e. the
//                             partial_mask field OF THIS FRAME is non-zero. A PC can rely on
//                             bit0 and that field always agreeing, because both are taken from
//                             the same snapshot.
//                 bit1 wet  - a chorus wet signal is present for this frame, i.e. the
//                             chorus_peak field OF THIS FRAME is non-zero (same rule as bit0).
//                 bit2 clip - clipping happened at least once inside this frame's acquisition
//                             window. This one is a WINDOW property, not an instant: frame_clipped
//                             is OR-ed over the whole window, so a short overload cannot fall
//                             between two frames and become invisible.
//                 bits 7..3 always read 0.
//     3       : zone_gates[3:0]         (bits 7..4 read 0)
//     4..7    : voice_phase_inc[31:0]   (phase increment of the selected voice, bend included)
//     8..11   : partial_mask[31:0]      (additive layer partials enabled)
//     12      : level_shift[3:0]        (bits 7..4 read 0)
//     13..14  : chorus_peak[15:0]
//     15..16  : chorus_clip[15:0]
//     17..18  : peak_abs[15:0]          (unsigned magnitude |pcm|, see the window note below)
//     19..    : POINTS eight-bit decimated wave samples, oldest sample first
//
//   The eight-bit wave point is pcm[15:8]: the signed 16-bit sample TRUNCATED (not rounded, not
//   clamped) to its top eight bits, which is an arithmetic shift right by eight followed by
//   taking the low eight bits of the result. Samples -32768..-1 become 0x80..0xFF and samples
//   0..32767 become 0x00..0x7F, so the byte is a signed eight-bit sample carrying exactly the
//   code of the original sample's high byte. There is no real arithmetic, no division and no
//   multiplier anywhere in this file; the payload offsets are compile-time constants.
//
//   --- type 0x22: payload offsets (0-based) ---
//     0..1    : seq[15:0]                (the SAME counter the 0x21 frames advance)
//     2       : flags = {5'b00000, clip, wet, add}   (identical encoding to 0x21, and again
//                                                 bit0/bit1 agree with partial_mask/chorus_peak
//                                                 OF THIS FRAME, while bit2 is the window property)
//     3       : zone_gates[3:0]          (bits 7..4 read 0)
//     4..5    : zone_pressure[0]         (zone_pressure_all[15:0], unsigned)
//     6..7    : zone_pressure[1]         (zone_pressure_all[31:16])
//     8..9    : zone_pressure[2]         (zone_pressure_all[47:32])
//     10..11  : zone_pressure[3]         (zone_pressure_all[63:48])
//     12      : owner_voice[1:0]         (bits 7..2 read 0) - the voice the layer is sounding
//     13      : partials_active[5:0]     (bits 7..6 read 0) - the ACTUAL number of sounding
//                                          partials, straight from the additive layer. It is a
//                                          COUNT where partial_mask is a MASK, so a PC can show
//                                          both and see a layer that claims more partials than it
//                                          has bits set.
//     14      : chorus_mode[1:0]         (bits 7..2 read 0)
//     15..18  : partial_mask[31:0]
//     19..22  : voice_phase_inc[31:0]    (the same value the 0x21 frame of that window carries,
//                                          so the pitch panel needs no second frame)
//     23..24  : chorus_peak[15:0]
//     25..26  : chorus_clip[15:0]
//
//   A 0x22 record is therefore 31 bytes on the wire (27 payload + 4 header/checksum) and carries no
//   wave points: the oscilloscope stays in 0x21, where the ping-pong bank already is.
//
//   WHY EVERY FIFTH FRAME: one frame per acquisition window leaves the line idle most of the time
//   (see the accounting below), so the performance record rides along without disturbing four
//   windows out of five. The rule is a plain counter, not a function of seq - but the two cannot
//   drift apart, because both advance once per transmitted frame, so in a stream captured from the
//   first frame, seq mod 5 == 4 marks exactly the 0x22 records. A PC that joined late can still
//   read the type byte and never has to trust that congruence.
//
//   SEQUENCE RULE: seq counts FRAMES on the line, not windows and not records of one type. It
//   advances by exactly one for every frame, whichever type that frame has, so a missing seq is a
//   real hole in the link and a repeated seq is a duplicated frame - for both types alike. A PC
//   that only wants the wave frames must expect to skip the 0x22 numbers, not to see a contiguous
//   run of its own.
//
//   BANDWIDTH (115200 8N1 = 10 bit times per byte; one frame per acquisition window, and a window
//   is POINTS*DECIM = 1024 audio samples = 21.333 ms at 48 kHz, i.e. 46.875 windows/s):
//     0x21 frame      : 4 + 51 = 55 bytes = 550 bit times = 4.774 ms
//     0x22 frame      : 4 + 27 = 31 bytes = 310 bit times = 2.691 ms
//     five-frame group: 4 x 55 + 31 = 251 bytes = 2510 bit times = 21.79 ms
//     group period    : 5 x 21.333 ms = 106.67 ms  ->  the line is busy 20.4% of the time
//     sustained rates : 37.5 wave frames/s (2062 B/s) + 9.375 performance records/s (291 B/s)
//                       = 2353 B/s of the 11520 B/s the link can carry
//   The other 79.6% of the line is idle, so the one-byte-time inter-frame gap is never the
//   binding constraint and the UART can never be the reason a frame is late.
//
// ---------------------------------------------------------------------------------------------
// ACQUISITION (ping-pong double buffer):
//   sample_ce marks a new audio sample (48 kHz). Every DECIM-th sample_ce one eight-bit point is
//   written into the bank selected by wr_bank. When that bank holds POINTS points it is complete,
//   the performance state is snapshotted into the same bank's registers, and the frame is handed
//   to the transmitter. Acquisition carries on in the OTHER bank while the completed bank is
//   shifted out - that is what the two banks are for.
//
//   Should the second bank fill up while the first one is still going out (impossible at the
//   designed rates: one window is POINTS*DECIM = 1024 samples = 21.3 ms while 55 bytes at
//   115200 baud take 4.8 ms), acquisition STALLS - the DECIM divider and the write pointer simply
//   freeze. No point and no frame is ever dropped, so seq advances by exactly one for every frame
//   the PC receives and a missing seq is a real gap on the link.
//
//   A frame's metadata travels with the waveform it belongs to: it is captured at the instant the
//   window's last point is taken, into the same bank's snapshot registers, so a frame already
//   queued for the line cannot be overwritten by the next window's state.
//
//   peak_abs is a self-resetting window peak. The window is exactly the POINTS*DECIM = 1024
//   sample_ce slots that produced this frame's points - from the sample that produced point 0
//   through the sample that produced the last point, inclusive. It is frozen into the snapshot
//   when the window closes and restarts from zero with the next window's first sample. A sample
//   that lies outside a window never contributes to it.
//
// ---------------------------------------------------------------------------------------------
// PACING AND BACKPRESSURE:
//   * a byte is handed to rtl/uart_tx.sv only when that transmitter is free (busy low) and its
//     one-clock start pulse has already fallen, so a byte can never be launched twice and a byte
//     is never started while the transmitter is busy;
//   * rtl/uart_tx.sv reports a refused start on 'rejected'; those pulses are counted and exported
//     on tx_rejected, so a byte lost to a busy transmitter would appear as a number instead of a
//     silent hole in the stream;
//   * the gap between the end of one frame and the start of the next is at least one byte time
//     (10 bit periods) - enforced by a counter, not merely by the collection rate. Frames are
//     normally much further apart than that: the acquisition window spaces them by ~21 ms and the
//     line is idle in between.
//   * 'busy' is high from the launch of the frame's first byte until the last byte has finished
//     shifting, so exactly LEN+4 bytes go out during one busy pulse.
//
//   POINTS is limited by two eight-bit quantities: LEN21 = 19 + POINTS must fit the LEN byte and
//   the byte index must fit eight bits, so POINTS <= 232.
//
// STATUS: simulation complete. sim/tb_viz_stream.sv decodes the line with an INDEPENDENT UART
// receiver (it samples the start bit on every clock, samples the eight data bits and the stop bit
// at their centres) and then checks the envelope, the checksum, the sequence number, every
// metadata field, the window peak, the flags and all POINTS wave samples against values it
// computes itself; it also decodes and checks the 0x22 performance records, including the four
// zone pressures, owner_voice, partials_active and chorus_mode, which the testbench drives and
// therefore predicts. A SECOND instance in that testbench leaves partials_active, owner_voice and
// chorus_mode UNCONNECTED on purpose, which is what proves the port defaults: its records stay
// x-free with those three bytes reading zero and a checksum that matches (taking the defaults away
// makes the test fail on an x on that instance's tx line).
//
// INTEGRATION: rtl/instrument_extension_core.sv (configuration D) drives the three inputs of the
// 0x22 record with real signals - the additive layer's active-partial count, the layer's owner
// voice and the chorus mode - so its stream carries them. Those fields are checked here in
// simulation with per-frame values driven straight into this module, which is the strongest form
// of the check a self-contained testbench can make; whether the config-D wiring carries the right
// signals end to end is sim/tb_instrument_extension_core.sv's business, not this file's.
//
// Synthesis, place and route, the U15 pin and the physical link at 115200 baud are UNTESTED.
module viz_stream #(
    parameter integer CLOCKS_PER_BIT = 107,   // 12.288 MHz / 115200 baud
    parameter integer DECIM          = 32,    // one visualisation point per DECIM samples
    parameter integer POINTS         = 32,    // wave points per frame
    parameter bit     SCOPE_DIAG     = 1'b0,  // extend 0x22 without changing 0x21
    parameter bit     PANEL_DIAG     = 1'b0   // LEN=53, versioned 14-byte append at offset39
) (
    input  logic               clk,                // 12.288 MHz
    input  logic               rst_n,
    input  logic               sample_ce,          // one clock per 256, i.e. 48 kHz
    input  logic signed [15:0] pcm,                // mixed audio, the signal to visualise
    input  logic [3:0]         zone_gates,         // the four performance zones, pressed or not
    // Five channels x 16 bits of pressure (CH0..CH4). CH0..CH3 are the four performance zones and
    // now travel in the 0x22 record as zone_pressure_all[63:0]; the fifth converter channel
    // ([79:64]) is still not carried by any record of this revision, because the 0x22 payload was
    // specified with four zone pressures - it is left unused on purpose instead of widening a
    // record every PC decoder would then have to re-learn. The 0x21 record carries no pressure at
    // all, so its LEN stays 19 + POINTS.
    input  logic [79:0]        zone_pressure_all,
    input  logic [31:0]        voice_phase_inc,    // selected voice phase increment (bend applied)
    input  logic [31:0]        partial_mask,       // additive layer partials currently enabled
    input  logic [3:0]         level_shift,
    input  logic [15:0]        chorus_peak,
    input  logic [15:0]        chorus_clip,
    input  logic               frame_clipped,      // this sample clipped
    // ---- inputs added for the 0x22 performance record ---------------------------------------
    // rtl/instrument_extension_core.sv (configuration D) drives all three with real signals; the
    // defaults are kept anyway, because an unwired input in simulation is z, and an x in one of
    // these fields would poison the payload AND the checksum of a whole frame. An instance that
    // leaves them unconnected therefore reports zero rather than corrupting the record.
    input  logic [5:0]         partials_active = 6'd0,  // sounding partials, from the additive layer
    input  logic [1:0]         owner_voice     = 2'd0,  // voice the additive layer is playing
    input  logic [1:0]         chorus_mode     = 2'd0,  // mode the chorus effect is in
    input  logic [11:0]        scope_adc6       = 12'd0,
    input  logic [11:0]        scope_adc7       = 12'd0,
    input  logic [7:0]         scope_status     = 8'd0,
    input  logic [1:0]         scope_preset     = 1'b0,
    input  logic               scope_mapping_v2 = 1'b0, // bit 7 of byte 32: CH6 controls partial count
    input  logic [7:0]         scope_wet_target = 8'd0,
    input  logic [7:0]         scope_wet_actual = 8'd0,
    input  logic signed [15:0] pcm_pre_effect   = 16'sd0,
    input  logic [111:0]       panel_info       = 112'd0,
    // S10: the four POST-gain voice levels and the additive layer level, live
    // per sample. The frame carries each window's PEAK |level| per voice.
    input  logic [63:0]        voice_levels     = 64'd0,   // {v3,v2,v1,v0} x 16
    input  logic signed [15:0] layer_level      = 16'sd0,
    output logic               tx,                 // 8N1, idle high
    output logic               busy,
    output logic [15:0]        frames_sent,
    output logic [15:0]        tx_rejected
);
    // ---- wire-level constants (all compile-time; nothing here is arithmetic hardware) ------
    localparam integer      LEN21       = 19 + POINTS; // 0x21 payload byte count
    localparam integer      LAST21      = LEN21 + 3;   // 0-based index of that frame's checksum
    localparam logic [7:0]  LEN21_BYTE  = LEN21;       // the same value as it travels on the wire
    localparam logic [7:0]  LAST21_BYTE = LAST21;
    localparam integer      LEN22       = PANEL_DIAG ? 53 : (SCOPE_DIAG ? 39 : 27);
    localparam integer      LAST22      = LEN22 + 3;
    localparam logic [7:0]  LEN22_BYTE  = LEN22;
    localparam logic [7:0]  LAST22_BYTE = LAST22;
    localparam logic [7:0]  SYNC        = 8'hA5;
    localparam logic [7:0]  TYPE21      = 8'h21;
    localparam logic [7:0]  TYPE22      = 8'h22;
    localparam logic [7:0]  TYPE23      = 8'h23;    // S10 voice-level meter record
    localparam logic [7:0]  LEN23_BYTE  = 8'd13;    // seq(2)+flags(1)+4x16 level+layer(2)
    localparam logic [7:0]  LAST23_BYTE = 8'd16;    // 4 + 13 - 1
    // Every (GROUP_22 + 1)-th frame is a 0x22 record: four wave frames, then one performance
    // record, which works out as 37.5 wave frames and 9.375 performance records per second.
    localparam logic [2:0]  GROUP_22    = 3'd4;
    localparam logic [2:0]  GROUP_23    = 3'd5;     // one level meter after each 0x22
    localparam logic [15:0] GAP_CLK     = 10 * CLOCKS_PER_BIT;   // one byte time

    localparam logic [1:0] S_IDLE  = 2'd0,   // waiting for a completed bank
                           S_SEND  = 2'd1,   // shifting the frame's LEN+4 bytes out
                           S_DRAIN = 2'd2;   // last byte handed over, waiting for the line to idle

    // ---- ping-pong wave banks ---------------------------------------------------------------
    logic [7:0] bank_a [0:POINTS-1];
    logic [7:0] bank_b [0:POINTS-1];
    logic       wr_bank;      // bank the acquisition is filling
    logic       rd_bank;      // bank the transmitter is reading
    logic       bank_full;    // the write bank holds a complete frame for the line
    integer     wr_ptr;
    integer     decim_cnt;

    // ---- per-bank snapshot of the performance state ------------------------------------------
    logic [15:0] snap_seq   [0:1];
    logic [7:0]  snap_flags [0:1];
    logic [3:0]  snap_gates [0:1];
    logic [31:0] snap_phase [0:1];
    logic [31:0] snap_parts [0:1];
    logic [3:0]  snap_lvl   [0:1];
    logic [15:0] snap_cpeak [0:1];
    logic [15:0] snap_cclip [0:1];
    logic [15:0] snap_peak  [0:1];
    logic [63:0] snap_press [0:1];   // zones 0..3, carried by the 0x22 record only
    logic [1:0]  snap_owner [0:1];
    logic [5:0]  snap_pact  [0:1];
    logic [1:0]  snap_cmode [0:1];
    logic [11:0] snap_adc6  [0:1];
    logic [11:0] snap_adc7  [0:1];
    logic [7:0]  snap_status[0:1];
    logic [1:0]  snap_preset[0:1];
    logic        snap_mapping_v2[0:1];
    logic [7:0]  snap_wet_target[0:1];
    logic [7:0]  snap_wet_actual[0:1];
    logic [15:0] snap_pcm_pre[0:1];
    logic [15:0] snap_pcm_dac[0:1];
    logic [111:0] snap_panel[0:1];
    logic [63:0]  vl_peak;                 // window peaks of the four post-gain levels
    logic [63:0]  snap_vlevels[0:1];
    logic [15:0]  layer_peak;
    logic [15:0]  snap_layer[0:1];
    logic [63:0]  vl_next;
    logic [15:0]  layer_next;
    function automatic logic [15:0] abs16(input logic signed [15:0] v);
        begin
            if (v == -32768) abs16 = 16'h7FFF;
            else             abs16 = v[15] ? -v : v;
        end
    endfunction
    // Window peak of each post-gain voice level and of the layer level.
    always_comb begin
        vl_next = vl_peak;
        for (integer vi = 0; vi < 4; vi = vi + 1) begin
            if (abs16(voice_levels[vi*16 +: 16]) > vl_peak[vi*16 +: 16])
                vl_next[vi*16 +: 16] = abs16(voice_levels[vi*16 +: 16]);
        end
        layer_next = (abs16(layer_level) > layer_peak) ? abs16(layer_level) : layer_peak;
    end

    // ---- acquisition state -------------------------------------------------------------------
    logic [15:0] peak_acc;    // window peak so far (unsigned magnitude)
    logic        clip_seen;   // frame_clipped OR-ed over the window so far
    logic [15:0] frame_seq;   // sequence number the next completed frame will carry

    // ---- transmitter state -------------------------------------------------------------------
    logic [1:0]  state;
    logic [7:0]  tx_index;
    logic [7:0]  tx_csum;
    logic [7:0]  tx_data;
    // Header bytes of the frame currently being shifted out. They are latched when the frame is
    // handed to the transmitter, so the byte selector knows the type, the length and where the
    // checksum sits without a second copy of the frame engine.
    logic [7:0]  cur_type;
    logic [7:0]  cur_len;
    logic [7:0]  cur_last;
    logic        cur_is22;     // payload layout of the frame currently on the line
    logic        cur_is23;     // S10 voice-level record on the line
    logic [2:0]  type_cycle;   // 0..GROUP_22; GROUP_22 selects the 0x22 record
    logic        tx_start;
    logic        uart_busy;
    logic        uart_rejected;
    logic [15:0] gap_cnt;

    // ---- payload byte selection (combinational; only the transmitted bytes are computed) -----
    logic [7:0]  off;
    logic [7:0]  cur_byte;
    integer      p;           // loop variable: POINTS copies of the wave comparison
    integer      r;           // loop variable: the two snapshot banks

    // |pcm| without relying on a signed absolute-value expression. Negating the most negative
    // sample wraps to 0x8000 in 16 bits, which is exactly the magnitude 32768.
    logic [15:0] pcm_mag;
    always_comb begin
        if (pcm[15]) pcm_mag = (~pcm[15:0]) + 16'd1;
        else         pcm_mag = pcm[15:0];
    end

    // The window peak and the window clip flag are computed one sample AHEAD so that the sample
    // which closes a window is still counted inside that window instead of leaking into the next.
    logic [15:0] peak_next;
    logic        clip_next;
    always_comb begin
        peak_next = (pcm_mag > peak_acc) ? pcm_mag : peak_acc;
        clip_next = clip_seen | frame_clipped;
    end

    assign busy = (state != S_IDLE);

    // The transmitter is the repository's own module, unchanged; only the baud parameter is passed.
    uart_tx #(.CLOCKS_PER_BIT(CLOCKS_PER_BIT)) serial (
        .clk(clk), .rst_n(rst_n), .start(tx_start), .data(tx_data),
        .tx(tx), .busy(uart_busy), .rejected(uart_rejected)
    );

    // ---- the byte the current frame position carries ----------------------------------------
    always_comb begin
        off      = tx_index - 8'd3;      // payload offset; not used for the three header bytes
        cur_byte = 8'h00;
        if      (tx_index == 8'd0)       cur_byte = SYNC;
        else if (tx_index == 8'd1)       cur_byte = cur_type;
        else if (tx_index == 8'd2)       cur_byte = cur_len;
        else if (tx_index == cur_last)   cur_byte = tx_csum;     // the checksum byte
        else if (cur_is23) begin
            // 0x23 payload: the window's post-gain voice peaks and the layer.
            if      (off == 8'd0)  cur_byte = snap_seq[rd_bank][7:0];
            else if (off == 8'd1)  cur_byte = snap_seq[rd_bank][15:8];
            else if (off == 8'd2)  cur_byte = snap_flags[rd_bank];
            else if (off < 8'd11)  cur_byte = snap_vlevels[rd_bank][(off-3)*8 +: 8];
            else if (off == 8'd11) cur_byte = snap_layer[rd_bank][7:0];
            else if (off == 8'd12) cur_byte = snap_layer[rd_bank][15:8];
        end else if (cur_is22) begin
            // 0x22 payload: its own offsets, no wave points.
            if      (off == 8'd0)  cur_byte = snap_seq[rd_bank][7:0];
            else if (off == 8'd1)  cur_byte = snap_seq[rd_bank][15:8];
            else if (off == 8'd2)  cur_byte = snap_flags[rd_bank];
            else if (off == 8'd3)  cur_byte = {4'b0000, snap_gates[rd_bank]};
            else if (off == 8'd4)  cur_byte = snap_press[rd_bank][7:0];
            else if (off == 8'd5)  cur_byte = snap_press[rd_bank][15:8];
            else if (off == 8'd6)  cur_byte = snap_press[rd_bank][23:16];
            else if (off == 8'd7)  cur_byte = snap_press[rd_bank][31:24];
            else if (off == 8'd8)  cur_byte = snap_press[rd_bank][39:32];
            else if (off == 8'd9)  cur_byte = snap_press[rd_bank][47:40];
            else if (off == 8'd10) cur_byte = snap_press[rd_bank][55:48];
            else if (off == 8'd11) cur_byte = snap_press[rd_bank][63:56];
            else if (off == 8'd12) cur_byte = {6'b000000, snap_owner[rd_bank]};
            else if (off == 8'd13) cur_byte = {2'b00, snap_pact[rd_bank]};
            else if (off == 8'd14) cur_byte = {6'b000000, snap_cmode[rd_bank]};
            else if (off == 8'd15) cur_byte = snap_parts[rd_bank][7:0];
            else if (off == 8'd16) cur_byte = snap_parts[rd_bank][15:8];
            else if (off == 8'd17) cur_byte = snap_parts[rd_bank][23:16];
            else if (off == 8'd18) cur_byte = snap_parts[rd_bank][31:24];
            else if (off == 8'd19) cur_byte = snap_phase[rd_bank][7:0];
            else if (off == 8'd20) cur_byte = snap_phase[rd_bank][15:8];
            else if (off == 8'd21) cur_byte = snap_phase[rd_bank][23:16];
            else if (off == 8'd22) cur_byte = snap_phase[rd_bank][31:24];
            else if (off == 8'd23) cur_byte = snap_cpeak[rd_bank][7:0];
            else if (off == 8'd24) cur_byte = snap_cpeak[rd_bank][15:8];
            else if (off == 8'd25) cur_byte = snap_cclip[rd_bank][7:0];
            else if (off == 8'd26) cur_byte = snap_cclip[rd_bank][15:8];
            else if (off == 8'd27) cur_byte = snap_adc6[rd_bank][7:0];
            else if (off == 8'd28) cur_byte = {4'b0, snap_adc6[rd_bank][11:8]};
            else if (off == 8'd29) cur_byte = snap_adc7[rd_bank][7:0];
            else if (off == 8'd30) cur_byte = {4'b0, snap_adc7[rd_bank][11:8]};
            else if (off == 8'd31) cur_byte = snap_status[rd_bank];
            else if (off == 8'd32) cur_byte = {snap_mapping_v2[rd_bank], 5'b0, snap_preset[rd_bank]};
            else if (off == 8'd33) cur_byte = snap_wet_target[rd_bank];
            else if (off == 8'd34) cur_byte = snap_wet_actual[rd_bank];
            else if (off == 8'd35) cur_byte = snap_pcm_pre[rd_bank][7:0];
            else if (off == 8'd36) cur_byte = snap_pcm_pre[rd_bank][15:8];
            else if (off == 8'd37) cur_byte = snap_pcm_dac[rd_bank][7:0];
            else if (off == 8'd38) cur_byte = snap_pcm_dac[rd_bank][15:8];
            else if (off >= 39 && off < 53) cur_byte = snap_panel[rd_bank][(off-39)*8 +: 8];
        end else begin
            // 0x21 payload: unchanged, so a decoder written for the previous revision still works.
            if      (off == 8'd0)            cur_byte = snap_seq[rd_bank][7:0];
            else if (off == 8'd1)            cur_byte = snap_seq[rd_bank][15:8];
            else if (off == 8'd2)            cur_byte = snap_flags[rd_bank];
            else if (off == 8'd3)            cur_byte = {4'b0000, snap_gates[rd_bank]};
            else if (off == 8'd4)            cur_byte = snap_phase[rd_bank][7:0];
            else if (off == 8'd5)            cur_byte = snap_phase[rd_bank][15:8];
            else if (off == 8'd6)            cur_byte = snap_phase[rd_bank][23:16];
            else if (off == 8'd7)            cur_byte = snap_phase[rd_bank][31:24];
            else if (off == 8'd8)            cur_byte = snap_parts[rd_bank][7:0];
            else if (off == 8'd9)            cur_byte = snap_parts[rd_bank][15:8];
            else if (off == 8'd10)           cur_byte = snap_parts[rd_bank][23:16];
            else if (off == 8'd11)           cur_byte = snap_parts[rd_bank][31:24];
            else if (off == 8'd12)           cur_byte = {4'b0000, snap_lvl[rd_bank]};
            else if (off == 8'd13)           cur_byte = snap_cpeak[rd_bank][7:0];
            else if (off == 8'd14)           cur_byte = snap_cpeak[rd_bank][15:8];
            else if (off == 8'd15)           cur_byte = snap_cclip[rd_bank][7:0];
            else if (off == 8'd16)           cur_byte = snap_cclip[rd_bank][15:8];
            else if (off == 8'd17)           cur_byte = snap_peak[rd_bank][7:0];
            else if (off == 8'd18)           cur_byte = snap_peak[rd_bank][15:8];
            else begin
                // POINTS wave samples, oldest first. The loop bound is a constant, so this is a
                // plain selector over the two banks, not a memory.
                for (p = 0; p < POINTS; p = p + 1)
                    if (off == (19 + p)) cur_byte = rd_bank ? bank_b[p] : bank_a[p];
            end
        end
    end

    // ---- acquisition + frame engine (one clocked block: every register has exactly one writer) --
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= S_IDLE;
            tx_index    <= 8'd0;
            tx_csum     <= 8'd0;
            tx_data     <= 8'd0;
            cur_type    <= TYPE21;      // the first frame after reset is a 0x21 wave frame
            cur_len     <= LEN21_BYTE;
            cur_last    <= LAST21_BYTE;
            cur_is22    <= 1'b0;
            cur_is23    <= 1'b0;
            type_cycle  <= 3'd0;
            tx_start    <= 1'b0;
            gap_cnt     <= 16'd0;
            frames_sent <= 16'd0;
            tx_rejected <= 16'd0;
            rd_bank     <= 1'b0;
            wr_bank     <= 1'b0;
            bank_full   <= 1'b0;
            wr_ptr      <= 0;
            decim_cnt   <= 0;
            peak_acc    <= 16'd0;
            clip_seen   <= 1'b0;
            frame_seq   <= 16'd0;
            for (r = 0; r < 2; r = r + 1) begin
                snap_seq[r]   <= 16'd0;
                snap_flags[r] <= 8'd0;
                snap_gates[r] <= 4'd0;
                snap_phase[r] <= 32'd0;
                snap_parts[r] <= 32'd0;
                snap_lvl[r]   <= 4'd0;
                snap_cpeak[r] <= 16'd0;
                snap_cclip[r] <= 16'd0;
                snap_peak[r]  <= 16'd0;
                snap_press[r] <= 64'd0;
                snap_owner[r] <= 2'd0;
                snap_pact[r]  <= 6'd0;
                snap_cmode[r] <= 2'd0;
                snap_adc6[r] <= 12'd0;
                snap_adc7[r] <= 12'd0;
                snap_status[r] <= 8'd0;
                snap_preset[r] <= 1'b0;
                snap_mapping_v2[r] <= 1'b0;
                snap_wet_target[r] <= 8'd0;
                snap_wet_actual[r] <= 8'd0;
                snap_pcm_pre[r] <= 16'd0;
                snap_pcm_dac[r] <= 16'd0;
                snap_panel[r] <= 112'd0;
            end
        end else begin
            // The start pulse to rtl/uart_tx.sv is one clock wide: it is raised by the branch
            // below and cleared here, so the transmitter samples it on exactly one edge.
            tx_start <= 1'b0;

            if (uart_rejected) tx_rejected <= tx_rejected + 16'd1;
            if (gap_cnt != 16'd0) gap_cnt <= gap_cnt - 16'd1;

            // ---- frame engine ----------------------------------------------------------------
            case (state)
                S_IDLE: begin
                    // A frame starts only when a bank is complete, the minimum inter-frame gap has
                    // expired and the transmitter is free. The write bank becomes the read bank and
                    // acquisition moves to the bank just freed.
                    if (bank_full && (gap_cnt == 16'd0) && !uart_busy) begin
                        rd_bank   <= wr_bank;
                        wr_bank   <= ~wr_bank;
                        bank_full <= 1'b0;
                        tx_data   <= SYNC;
                        tx_csum   <= SYNC;     // the sync byte is the first term of the checksum
                        tx_index  <= 8'd1;
                        tx_start  <= 1'b1;
                        state     <= S_SEND;
                        // Latch this frame's type, LEN and checksum position, and step the group
                        // counter. Four wave frames then one performance record, for ever; the
                        // counter cannot drift from seq because both step once per frame.
                        cur_is22   <= (type_cycle == GROUP_22);
                        cur_is23   <= (type_cycle == GROUP_23);
                        cur_type   <= (type_cycle == GROUP_22) ? TYPE22 :
                                      (type_cycle == GROUP_23) ? TYPE23 : TYPE21;
                        cur_len    <= (type_cycle == GROUP_22) ? LEN22_BYTE :
                                      (type_cycle == GROUP_23) ? LEN23_BYTE : LEN21_BYTE;
                        cur_last   <= (type_cycle == GROUP_22) ? LAST22_BYTE :
                                      (type_cycle == GROUP_23) ? LAST23_BYTE : LAST21_BYTE;
                        type_cycle <= (type_cycle == GROUP_23) ? 3'd0 : (type_cycle + 3'd1);
                    end
                end
                S_SEND: begin
                    // One byte per transmitter slot. The transmitter samples 'start' on the edge
                    // after this one, so the guard must also exclude a start pulse that is still
                    // high, otherwise the same byte would be launched a second time.
                    if (!uart_busy && !tx_start) begin
                        tx_data  <= cur_byte;
                        tx_index <= tx_index + 8'd1;
                        tx_start <= 1'b1;
                        if (tx_index == cur_last) begin
                            state <= S_DRAIN;   // the checksum is on its way; do not sum it in
                        end else begin
                            tx_csum <= tx_csum + cur_byte;
                        end
                    end
                end
                S_DRAIN: begin
                    // The last byte needs a full bit period for its stop bit before the frame counts
                    // as sent, and before the next frame may touch the line.
                    if (!uart_busy && !tx_start) begin
                        gap_cnt     <= GAP_CLK;
                        frames_sent <= frames_sent + 16'd1;
                        state       <= S_IDLE;
                    end
                end
                default: state <= S_IDLE;
            endcase

            // ---- acquisition -----------------------------------------------------------------
            // Frozen while a completed bank is still waiting: stalling keeps every window exactly
            // POINTS*DECIM samples long and guarantees that no frame is dropped.
            if (sample_ce && !bank_full) begin
                if (decim_cnt == (DECIM - 1)) begin
                    decim_cnt <= 0;
                    if (wr_bank) bank_b[wr_ptr] <= pcm[15:8];
                    else         bank_a[wr_ptr] <= pcm[15:8];
                    if (wr_ptr == (POINTS - 1)) begin
                        // Window closed: freeze this frame's state into its own bank, then restart
                        // the peak/clip window for the next one.
                        wr_ptr        <= 0;
                        bank_full     <= 1'b1;
                        peak_acc      <= 16'd0;
                        clip_seen     <= 1'b0;
                        snap_seq[wr_bank]   <= frame_seq;
                        snap_flags[wr_bank] <= {5'b00000, clip_next,
                                                (|chorus_peak), (|partial_mask)};
                        snap_gates[wr_bank] <= zone_gates;
                        snap_phase[wr_bank] <= voice_phase_inc;
                        snap_parts[wr_bank] <= partial_mask;
                        snap_lvl[wr_bank]   <= level_shift;
                        snap_cpeak[wr_bank] <= chorus_peak;
                        snap_cclip[wr_bank] <= chorus_clip;
                        snap_peak[wr_bank]  <= peak_next;
                        snap_press[wr_bank] <= zone_pressure_all[63:0];   // zones 0..3 only
                        snap_owner[wr_bank] <= owner_voice;
                        snap_pact[wr_bank]  <= partials_active;
                        snap_cmode[wr_bank] <= chorus_mode;
                        snap_adc6[wr_bank] <= scope_adc6;
                        snap_adc7[wr_bank] <= scope_adc7;
                        snap_status[wr_bank] <= scope_status;
                        snap_preset[wr_bank] <= scope_preset;
                        snap_mapping_v2[wr_bank] <= scope_mapping_v2;
                        snap_wet_target[wr_bank] <= scope_wet_target;
                        snap_wet_actual[wr_bank] <= scope_wet_actual;
                        snap_pcm_pre[wr_bank] <= pcm_pre_effect;
                        snap_pcm_dac[wr_bank] <= pcm[15:0];
                        snap_panel[wr_bank] <= panel_info;
                        snap_vlevels[wr_bank] <= vl_peak;
                        snap_layer[wr_bank]   <= layer_peak;
                        vl_peak     <= 64'd0;
                        layer_peak  <= 16'd0;
                        frame_seq     <= frame_seq + 16'd1;
                    end else begin
                        wr_ptr   <= wr_ptr + 1;
                        peak_acc <= peak_next;
                        vl_peak    <= vl_next;
                        layer_peak <= layer_next;
                        clip_seen<= clip_next;
                    end
                end else begin
                    decim_cnt <= decim_cnt + 1;
                    peak_acc  <= peak_next;
                    clip_seen <= clip_next;
                end
            end
        end
    end
endmodule
