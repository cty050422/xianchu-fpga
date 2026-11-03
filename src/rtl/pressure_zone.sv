// DEFAULT IMAGE 2026-10-24: this file is now the root rtl/pressure_zone.sv driven by
// rtl/zone_bank.sv (the default top). It replaces the frozen copy SHA-256 DC4186CB...,
// which reproduced two contract defects on this image (CONFIRM_FRAMES counted clocks
// instead of fresh samples; a cleared-but-held zone could be re-zeroed). Ported
// verbatim from candidates/productized_instrument/rtl/pressure_zone.sv (SHA-256
// 4C86D601...): the logic is unchanged, only this provenance note was added, plus the
// `suppressed` output that the default top leaves unconnected.
//
// final_instrument work candidate: the pressure zone with the modern reliability fixes.
//
// ORIGIN: candidates/instrument_verified/rtl/iv_pressure_zone.sv (source SHA-256 in
// SOURCE_LEDGER.json). Local change: the module is renamed iv_pressure_zone -> pressure_zone so
// that this single enabled copy replaces the old zone instead of being compiled next to it. The
// logic is unchanged, and that matters: the old dual_joystick copy this file replaces was missing
// two contract fixes that an independent review (2026-10-18, findings R1 and R6) reproduced on the
// delivered image:
//
//   R6 (CONFIRM_FRAMES_COUNTS_CLOCKS_NOT_SAMPLES): the trigger decision here is evaluated ONLY on
//   a NEW sample of this channel, using the incoming code in that same clock. A missing sample can
//   never advance the confirmation counter, so CONFIRM_FRAMES>1 cannot be satisfied by one high
//   sample plus elapsed clocks.
//
//   R1 part 1 (clear must not re-fire): a cleared zone latches suppressed and refuses to arm
//   until a fresh sample shows the electrode back at or below the off threshold; a calibration
//   request while suppressed is REFUSED (cal_refused) instead of re-zeroing a held finger. The
//   note map's one-shot all-notes-off sweep is what actually releases the sounding voices.
//
// One expression channel of the instrument_verified candidate (M1 reliability fix).
// Derived from frozen rtl/pressure_zone.sv (SHA-256 DC4186CB...) with EXACTLY three
// contract changes; everything else is byte-for-byte the same design:
//
//  FIX SW-04 (CONFIRM_FRAMES_COUNTS_CLOCKS_NOT_SAMPLES): the trigger decision is now
//  evaluated ONLY on a NEW sample of this channel, and the threshold judgment uses the
//  INCOMING sample_code in the same clock (eff_code) - never the previous code and never
//  a free-running clock counter. A missing sample cannot advance the confirmation count,
//  and a qualifying sample is judged in the clock it arrives, so CONFIRM_FRAMES=1 keeps
//  the fast path (the gate register is set on the sample's own clock edge, one clock
//  after sample_valid, instead of two clocks after it in the frozen module).
//
//  FIX SW-01 part 1 (clear must not re-fire): a cleared zone latches `suppressed` and
//  refuses to arm the trigger path until a fresh sample shows the electrode back at or
//  below the off threshold ("released to idle"). While suppressed, an explicit
//  calibration request is REFUSED (cal_refused) instead of re-zeroing a still-held
//  finger, so the only way back to playing is: release to idle -> explicit successful
//  calibration -> press again. 0 and 0xFFF are legal codes and are never treated as
//  faults here.
//
//  Provenance: frozen module otherwise unchanged. The expression filter now follows the
//  same new sample (the frozen filter lagged one frame because it used the previous
//  code_r on the sample clock); this is the same no-extra-delay rule applied to the
//  expression path.
module pressure_zone #(
    parameter integer      FILTER_SHIFT   = 3,
    parameter logic [15:0] SLEW_STEP      = 16'd4096,
    parameter integer      SPAN_SHIFT     = 4,
    parameter logic [15:0] SATURATION_LEVEL = 16'hfef0,
    parameter integer      STALE_FRAMES   = 5,
    parameter integer      CONFIRM_FRAMES = 1,
    parameter logic        TRIGGER_ENABLE = 1'b1
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        sample_valid,
    input  logic [11:0] sample_code,
    input  logic        frame_done,
    input  logic        calibrate,
    input  logic        clear_calibration,
    input  logic [11:0] on_threshold,
    input  logic [11:0] off_threshold,
    output logic [11:0] code,
    output logic [15:0] pressure,
    output logic        valid,
    output logic [7:0]  age,
    output logic        stale,
    output logic        calibrated,
    output logic        has_sample,
    output logic        cal_refused,
    output logic        gate,
    output logic        trigger_on,
    output logic        trigger_off,
    output logic [2:0]  state,
    output logic        saturated,
    output logic        suppressed   // cleared-while-held lockout; observability + tests
);
    localparam logic [2:0] ST_UNCALIBRATED = 3'd0;
    localparam logic [2:0] ST_RELEASED     = 3'd1;
    localparam logic [2:0] ST_ARMING       = 3'd2;
    localparam logic [2:0] ST_PRESSED      = 3'd3;
    localparam logic [2:0] ST_RELEASING    = 3'd4;

    logic [11:0] code_r;
    logic [11:0] zero_r;
    logic [15:0] normalised;
    logic [15:0] filtered;
    logic [15:0] filtered_next;
    logic [15:0] slewed;
    logic [15:0] slewed_next;
    logic [3:0]  confirm_counter;
    logic [7:0]  age_r;
    logic        gate_r;
    logic        cal_valid;
    logic        has_sample_r;
    logic        sample_this_frame;
    logic        suppressed_r;
    logic [16:0] offset;
    logic signed [17:0] difference;
    logic signed [17:0] step;
    logic signed [17:0] filter_sum;
    logic [11:0] eff_code;
    logic [11:0] release_threshold;

    // A configurable ON value may fall below the requested OFF value. Without
    // this guard a held sample between them alternates note-on and note-off.
    // Preserve the factory 512/256 pair; retain a lower requested OFF threshold.
    assign release_threshold = (off_threshold < on_threshold) ? off_threshold
                                                               : (on_threshold >> 1);

    assign code       = code_r;
    assign valid      = sample_this_frame;
    assign age        = age_r;
    assign stale      = (age_r > STALE_FRAMES[7:0]);
    assign calibrated = cal_valid;
    assign has_sample = has_sample_r;
    assign gate       = gate_r;
    assign pressure   = slewed;
    assign saturated  = (slewed >= SATURATION_LEVEL);
    assign suppressed = suppressed_r;

    // The threshold judgment always sees the sample that is arriving NOW, never the
    // previously latched code. This is the whole point of fix SW-04.
    assign eff_code = sample_valid ? sample_code : code_r;

    always_comb begin
        offset = {5'd0, eff_code} - {5'd0, zero_r};
        if (eff_code <= zero_r) begin
            normalised = 16'd0;
        end else if (offset > 17'd4095) begin
            normalised = 16'hffff;
        end else begin
            normalised = (offset[11:0] << SPAN_SHIFT) > 17'd65535
                       ? 16'hffff : (offset[11:0] << SPAN_SHIFT);
        end
    end

    always_comb begin
        difference = $signed({2'b0, normalised}) - $signed({2'b0, filtered});
        step       = difference >>> FILTER_SHIFT;
        if (step == 18'sd0 && difference != 18'sd0)
            step = (difference > 18'sd0) ? 18'sd1 : -18'sd1;
        filter_sum = $signed({2'b0, filtered}) + step;
        if (filter_sum < 18'sd0)
            filtered_next = 16'd0;
        else if (filter_sum > 18'sd65535)
            filtered_next = 16'hffff;
        else
            filtered_next = filter_sum[15:0];
        if (slewed < filtered_next) begin
            slewed_next = ((filtered_next - slewed) <= SLEW_STEP) ? filtered_next : (slewed + SLEW_STEP);
        end else if (slewed > filtered_next) begin
            slewed_next = ((slewed - filtered_next) <= SLEW_STEP) ? filtered_next : (slewed - SLEW_STEP);
        end else begin
            slewed_next = slewed;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            code_r            <= 12'd0;
            zero_r            <= 12'd0;
            confirm_counter   <= 4'd0;
            age_r             <= 8'd0;
            gate_r            <= 1'b0;
            filtered          <= 16'd0;
            slewed            <= 16'd0;
            trigger_on        <= 1'b0;
            trigger_off       <= 1'b0;
            cal_refused       <= 1'b0;
            cal_valid         <= 1'b0;
            has_sample_r      <= 1'b0;
            sample_this_frame <= 1'b0;
            suppressed_r      <= 1'b0;
            state             <= ST_UNCALIBRATED;
        end else begin
            trigger_on  <= 1'b0;
            trigger_off <= 1'b0;
            cal_refused <= 1'b0;

            if (sample_valid) begin
                code_r            <= sample_code;
                sample_this_frame <= 1'b1;
                has_sample_r      <= 1'b1;
                age_r             <= 8'd0;
                if (cal_valid) begin
                    filtered <= filtered_next;
                    slewed   <= slewed_next;
                end
            end

            if (clear_calibration) begin
                cal_valid    <= 1'b0;
                state        <= ST_UNCALIBRATED;
                gate_r       <= 1'b0;
                // Only a zone whose TRIGGER PATH IS ACTUALLY PRESSED needs the
                // release-to-idle lockout. Latching suppression for every zone breaks a
                // legitimate calibration right after a clear: the MCP3208 scans one
                // channel per frame, so zones that have not been sampled yet would keep
                // `suppressed` set and the five-channel re-calibration would refuse them.
                // A released zone has nothing to protect, so it may be re-zeroed at once.
                suppressed_r <= TRIGGER_ENABLE && gate_r;
            end else if (calibrate) begin
                if (gate_r || (state == ST_PRESSED) || (state == ST_ARMING) || suppressed_r) begin
                    // suppressed: the zone has not been seen idle since its last clear,
                    // so re-zeroing a held finger is reported, not silently accepted.
                    cal_refused <= 1'b1;
                end else begin
                    zero_r    <= code_r;
                    filtered  <= 16'd0;
                    slewed    <= 16'd0;
                    cal_valid <= 1'b1;
                    state     <= ST_RELEASED;
                end
            end

            // The trigger path advances only on a NEW sample of THIS channel and never in
            // the same clock as a calibration control change. A missing sample cannot
            // count as a confirmation (fix SW-04); a suppressed zone cannot arm (fix SW-01).
            if (TRIGGER_ENABLE && cal_valid && !clear_calibration && !calibrate
                && sample_valid && !suppressed_r) begin
                if (!gate_r) begin
                    if (normalised >= {4'd0, on_threshold}) begin
                        if (CONFIRM_FRAMES <= 1) begin
                            gate_r     <= 1'b1;
                            trigger_on <= 1'b1;
                            state      <= ST_PRESSED;
                        end else if (confirm_counter + 4'd1 >= CONFIRM_FRAMES[3:0]) begin
                            gate_r          <= 1'b1;
                            trigger_on      <= 1'b1;
                            confirm_counter <= 4'd0;
                            state           <= ST_PRESSED;
                        end else begin
                            confirm_counter <= confirm_counter + 4'd1;
                            state           <= ST_ARMING;
                        end
                    end else begin
                        confirm_counter <= 4'd0;
                        state           <= ST_RELEASED;
                    end
                end else begin
                    if (normalised <= {4'd0, release_threshold}) begin
                        if (CONFIRM_FRAMES <= 1) begin
                            gate_r      <= 1'b0;
                            trigger_off <= 1'b1;
                            state       <= ST_RELEASED;
                        end else if (confirm_counter + 4'd1 >= CONFIRM_FRAMES[3:0]) begin
                            gate_r          <= 1'b0;
                            trigger_off     <= 1'b1;
                            confirm_counter <= 4'd0;
                            state           <= ST_RELEASED;
                        end else begin
                            confirm_counter <= confirm_counter + 4'd1;
                            state           <= ST_RELEASING;
                        end
                    end else begin
                        confirm_counter <= 4'd0;
                        state           <= ST_PRESSED;
                    end
                end
            end

            // Released to idle (fresh sample at/below the off threshold): the cleared-zone
            // lockout ends and an explicit calibration becomes acceptable again.
            if (sample_valid && suppressed_r && (normalised <= {4'd0, release_threshold}))
                suppressed_r <= 1'b0;

            if (frame_done) begin
                if (!sample_this_frame && (age_r != 8'hff)) age_r <= age_r + 8'd1;
                sample_this_frame <= 1'b0;
            end
        end
    end
endmodule
