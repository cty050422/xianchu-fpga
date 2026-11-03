// Thumb-axis (CH4) centre capture for the global pitch bend (M4).
//
// The stick has a mechanical centre that is NOT the converter's mid-code: a real
// potentiometer or joystick rests anywhere in the 12-bit range, and this dock's stick is
// UNTESTED. The bend therefore needs a MEASURED centre, and that centre has to be captured
// from the stick itself instead of being assumed to be 0x800.
//
// Contract:
//   * sample_valid pulses when CH4 was converted; sample_code is its raw 12-bit result.
//   * A calibration request is served only when the stick is provably at rest:
//       - the last STABLE_FRAMES complete scan frames each delivered a fresh CH4 sample, and
//       - the maximum minus the minimum code across those frames is at most STABLE_SPREAD.
//     A frame without a sample restarts the window, so "four frames of data" always means
//     four frames that really carried data rather than four frame ticks.
//   * The captured centre must also be plausible:
//       - the FIRST calibration must land within ACCEPT_WINDOW codes of reference_center
//         (the board's external thumb_center_code, 0x800 on the dock), and
//       - a REPEAT calibration must land within ACCEPT_WINDOW codes of the centre already in
//         use, so a stick parked against a rail cannot silently become the new centre.
//   * start is a one-cycle grant from the calibration arbiter in rtl/instrument_top.sv and
//     latches the candidate; commit is the one-cycle completion pulse of the same
//     transaction, and only then does the centre change. If the transaction is not completed
//     because another selected channel refused, the candidate is dropped and the old centre
//     stays: the five-channel calibration is all-or-nothing, never partial.
//   * clear_calibration (the long two-key gesture, or the board input) invalidates the
//     centre, and so does rst_n. An invalid centre makes the instrument BYPASS the bend:
//     rtl/instrument_top.sv then forces the ratio to exactly 32768, so an uncalibrated stick
//     can neither transpose the instrument nor make it sound out of tune.
//   * reference_center is a plausibility window and a compatibility input ONLY. Once a valid
//     captured centre exists, changing reference_center cannot move the centre.
//
// STATUS: RTL simulation only (sim/tb_thumb_center_calibrator.sv and the whole-instrument
// sim/tb_instrument_top_bend_center.sv). The real stick, its drift, its noise and its
// mechanical hysteresis are UNTESTED.
module thumb_center_calibrator #(
    parameter logic [7:0]  STABLE_FRAMES = 8'd4,     // complete frames required, each with a sample
    parameter logic [12:0] STABLE_SPREAD = 13'd32,   // max code minus min code in that window
    parameter logic [12:0] ACCEPT_WINDOW = 13'd400,  // plausibility window in converter codes
    // "Fresh" is a wall-clock property, not only a frame property: if the scanner stops
    // delivering complete frames (input disabled, converter dead, cable pulled) the last
    // window is history, not evidence of rest. Eight milliseconds is eight scan frames at the
    // 1 ms frame rate, so a healthy scanner never trips it.
    parameter logic [23:0] FRESH_TIMEOUT = 24'd98_304
) (
    input  logic        clk,
    input  logic        rst_n,
    // CH4 sample stream (rtl/mcp3208_scan_engine.sv)
    input  logic        sample_valid,
    input  logic [11:0] sample_code,
    input  logic        frame_done,
    // Calibration transaction, arbitrated in rtl/instrument_top.sv
    input  logic        start,           // one cycle: this channel was granted a calibration
    input  logic        commit,          // one cycle: the whole transaction completed
    input  logic        clear_calibration,
    input  logic [11:0] reference_center,
    // Result
    output logic [11:0] center_code,
    output logic        center_valid,
    // Arbitration support and telemetry
    output logic        ready,           // a grant issued NOW would be accepted
    output logic [11:0] candidate_code,  // the code a grant would capture
    output logic [7:0]  stable_frames    // length of the current stable frame run
);
    logic [11:0] frame_min, frame_max;
    logic        sample_this_frame;
    logic [11:0] last_code;
    logic [11:0] window_min, window_max;
    logic [7:0]  window_frames;
    logic        pending;
    logic [11:0] pending_code;

    // Min/max of the frame being closed, including a sample that arrives in the very clock as
    // frame_done: the scanner can deliver the last channel and the frame tick together, and a
    // sample must never be dropped from the window. frame_has_sample folds that same-clock
    // sample into the frame decision as well, because the registered flag is still low at that
    // edge (a pure register test would classify the frame as empty and restart the window).
    logic [11:0] close_min, close_max;
    logic        frame_has_sample;
    assign frame_has_sample = sample_this_frame || sample_valid;
    always_comb begin
        if (!sample_valid) begin
            close_min = frame_min;
            close_max = frame_max;
        end else if (!sample_this_frame) begin
            close_min = sample_code;
            close_max = sample_code;
        end else begin
            close_min = (sample_code < frame_min) ? sample_code : frame_min;
            close_max = (sample_code > frame_max) ? sample_code : frame_max;
        end
    end

    // Window statistics if this frame joins the run. Kept one bit wider than a code so that
    // the difference of two 12-bit codes cannot wrap.
    logic [11:0] merged_min, merged_max;
    logic [12:0] spread_next;
    always_comb begin
        merged_min = (window_frames == 8'd0) ? close_min :
                     ((close_min < window_min) ? close_min : window_min);
        merged_max = (window_frames == 8'd0) ? close_max :
                     ((close_max > window_max) ? close_max : window_max);
        spread_next = {1'b0, merged_max} - {1'b0, merged_min};
    end

    assign candidate_code = last_code;
    assign stable_frames  = window_frames;

    // The reference the capture has to respect: the centre already in use when there is one,
    // otherwise the external first-calibration reference. That ordering is what stops the
    // external input from ever overriding a valid auto-captured centre.
    logic [11:0] plausibility_reference;
    logic [12:0] distance;
    assign plausibility_reference = center_valid ? center_code : reference_center;
    always_comb begin
        distance = (candidate_code >= plausibility_reference)
                 ? ({1'b0, candidate_code} - {1'b0, plausibility_reference})
                 : ({1'b0, plausibility_reference} - {1'b0, candidate_code});
    end

    // The spread test is applied again here even though a window only ever grows while it
    // holds, so the published condition is the one that is actually checked.
    logic window_spread_ok;
    always_comb begin
        window_spread_ok = (({1'b0, window_max} - {1'b0, window_min}) <= STABLE_SPREAD);
    end

    // Time since the last completed scan frame. A stopped scanner must not be able to supply a
    // centre from a window that was filled before it stopped.
    logic [23:0] frame_gap;
    logic        frame_gap_expired;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) frame_gap <= 24'd0;
        else if (frame_done) frame_gap <= 24'd0;
        else if (frame_gap != FRESH_TIMEOUT) frame_gap <= frame_gap + 24'd1;
    end
    assign frame_gap_expired = (frame_gap >= FRESH_TIMEOUT);

    assign ready = (window_frames >= STABLE_FRAMES) && window_spread_ok &&
                   (distance <= ACCEPT_WINDOW) && !frame_gap_expired;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            frame_min         <= 12'h000;
            frame_max         <= 12'h000;
            sample_this_frame <= 1'b0;
            last_code         <= 12'h000;
            window_min        <= 12'h000;
            window_max        <= 12'h000;
            window_frames     <= 8'd0;
            pending           <= 1'b0;
            pending_code      <= 12'h000;
            center_code       <= 12'h000;
            center_valid      <= 1'b0;
        end else begin
            if (sample_valid) begin
                if (!sample_this_frame) begin
                    frame_min <= sample_code;
                    frame_max <= sample_code;
                end else begin
                    if (sample_code < frame_min) frame_min <= sample_code;
                    if (sample_code > frame_max) frame_max <= sample_code;
                end
                sample_this_frame <= 1'b1;
                last_code         <= sample_code;
            end

            if (frame_done) begin
                if (!frame_has_sample) begin
                    // A frame without a CH4 sample is not evidence of rest: restart the window.
                    window_min    <= 12'h000;
                    window_max    <= 12'h000;
                    window_frames <= 8'd0;
                end else if ((window_frames != 8'd0) && (spread_next <= STABLE_SPREAD) &&
                             (window_frames != 8'hff)) begin
                    window_min    <= merged_min;
                    window_max    <= merged_max;
                    window_frames <= window_frames + 8'd1;
                end else begin
                    window_min    <= close_min;
                    window_max    <= close_max;
                    window_frames <= 8'd1;
                end
                sample_this_frame <= 1'b0;
            end else if (frame_gap_expired) begin
                // No complete frame for FRESH_TIMEOUT clocks: the window is no longer evidence.
                window_min        <= 12'h000;
                window_max        <= 12'h000;
                window_frames     <= 8'd0;
                sample_this_frame <= 1'b0;
            end

            if (clear_calibration) begin
                center_valid <= 1'b0;
                pending      <= 1'b0;
            end else begin
                if (start) begin
                    pending      <= 1'b1;
                    pending_code <= candidate_code;
                end
                if (commit && pending) begin
                    center_code  <= pending_code;
                    center_valid <= 1'b1;
                    pending      <= 1'b0;
                end
            end
        end
    end
endmodule
