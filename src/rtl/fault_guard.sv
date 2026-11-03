// final_instrument work candidate: detected-anomaly fault guard.
//
// ORIGIN: candidates/instrument_verified/rtl/iv_fault_guard.sv (source SHA-256 in
// SOURCE_LEDGER.json). Local changes: module renamed to fault_guard, the header re-stated for
// this candidate, and nothing else - the detection/recovery logic is byte-identical. The
// instrument_verified candidate keeps its own untouched copy so its frozen negative tests still
// bind to the frozen source.
//
// Detected-anomaly policy, kept ABOVE the zones' documented "missing sample holds the
// expression" contract:
//   * any detected anomaly on the FIVE conditioning channels (CH0..CH4) - a stale channel
//     (age > STALE_FRAMES), an incomplete scan frame, or an increasing scan-timeout counter -
//     latches the fault and pulses force_release once: every held voice gets the controlled
//     all-notes-off sweep (controlled envelope release, never an oscillator reset) and new
//     note-ons are blocked (block_on to the note map). Diagnostics keep running.
//   * recovery needs ALL of: at least FRESH_FRAMES_REQUIRED consecutive complete scan frames
//     with all five channels fresh, every playing zone released, and one explicit SUCCESSFUL
//     calibration observed after the latch. A sensor going high again never un-latches by
//     itself, so the instrument cannot resume on its own.
//   * the three AUXILIARY axes CH5..CH7 are deliberately NOT part of this five-channel guard:
//     they never trigger a note, and their own per-axis stale/centre handling
//     (vibrato_control, aux_joystick_controls, joystick_axis_center) degrades them to their
//     documented defaults instead of stopping the instrument.
//   * undetectable cases are documented, not hidden: the MCP3208 has no CRC, and a MISO line
//     stuck at a constant level can still produce "successful" conversions. A stuck line is
//     therefore NOT claimed as detectable; only stale/timeout/incomplete detections are.
module fault_guard #(
    parameter integer FRESH_FRAMES_REQUIRED = 4
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic [4:0]  zone_stale,          // from the five expression channels
    input  logic        frame_done,
    input  logic        frame_incomplete,    // scanner flag for the finishing frame
    input  logic [4:0]  zone_valid,          // channels converted in the finishing frame
    input  logic [3:0]  zone_gate,           // CH0..CH3 held state
    input  logic [15:0] scan_timeout_count,  // running scanner timeout counter
    input  logic        cal_done,            // one-clock pulse: successful calibration
    output logic        fault_latched,
    output logic        force_release,       // one-clock pulse at latch time
    output logic [3:0]  fresh_run,           // diagnostics: consecutive complete fresh frames
    output logic        cal_seen,            // diagnostics: successful cal since latch
    output logic        timeout_detected     // diagnostics: counter moved
);
    logic [15:0] prev_timeout;
    logic [3:0]  fresh_run_r;
    logic        cal_seen_r;
    logic        fresh_frame;
    logic        fault_r;
    logic        timeout_inc;
    logic        anomaly_now;
    logic [3:0]  fresh_run_next;

    assign fault_latched    = fault_r;
    assign fresh_run        = fresh_run_r;
    assign cal_seen         = cal_seen_r;
    assign timeout_detected = timeout_inc;

    always_comb begin
        timeout_inc = (scan_timeout_count != prev_timeout);
        // A complete frame that also delivered all five channels fresh. A frame with a
        // timeout or an incomplete mask cannot be fresh by definition.
        anomaly_now = (|zone_stale) || frame_incomplete || timeout_inc;
        fresh_frame = frame_done && !anomaly_now && (zone_valid == 5'b11111);
        fresh_run_next = fresh_run_r;
        if (anomaly_now || (frame_done && !fresh_frame)) fresh_run_next = 4'd0;
        else if (fresh_frame && fresh_run_r != 4'd15) fresh_run_next = fresh_run_r + 4'd1;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fault_r      <= 1'b0;
            prev_timeout <= 16'd0;
            fresh_run_r  <= 4'd0;
            cal_seen_r   <= 1'b0;
            force_release <= 1'b0;
        end else begin
            prev_timeout  <= scan_timeout_count;
            force_release <= 1'b0;

            if (!fault_r) begin
                if (anomaly_now) begin
                    fault_r       <= 1'b1;
                    force_release <= 1'b1;   // controlled all-notes-off via the note map
                    fresh_run_r   <= 4'd0;
                    cal_seen_r    <= 1'b0;
                end
            end else begin
                // A new anomaly wins over recovery, including on its last qualifying
                // edge. It invalidates the previous run and calibration acknowledgement.
                fresh_run_r <= fresh_run_next;
                if (anomaly_now) cal_seen_r <= 1'b0;
                else if (cal_done) cal_seen_r <= 1'b1;
                if (!anomaly_now && (fresh_run_next >= FRESH_FRAMES_REQUIRED[3:0]) &&
                    (zone_gate == 4'd0) && (cal_seen_r || cal_done)) begin
                    fault_r     <= 1'b0;
                    fresh_run_r <= 4'd0;
                    cal_seen_r  <= 1'b0;
                end
            end
        end
    end
endmodule
