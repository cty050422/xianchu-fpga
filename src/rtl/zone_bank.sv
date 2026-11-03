// Five expression channels for the instrument (M1): CH0..CH3 are the four pressure
// zones, CH4 is the thumb axis. Each channel is an independent rtl/pressure_zone.sv.
//
// Channel identity is structural: a sample is routed to the zone whose index equals the
// scanner's channel_id, so a value can never be applied to the wrong electrode by a
// later stage, and the four zones cannot share one global pressure value again.
//
// Calibration is an explicit procedure, not an automatic zero: it runs only on a
// cal_request, only for the masked channels, and only while those channels are released
// and have a recent (not stale) sample. Pressing an electrode during calibration makes the bank
// refuse (cal_refused) instead of quietly re-zeroing a held finger. clear_calibration
// returns every channel to the safe, non-firing state.
module zone_bank #(
    parameter integer      ZONES          = 5,
    parameter integer      FILTER_SHIFT   = 3,
    parameter logic [15:0] SLEW_STEP      = 16'd4096,
    parameter integer      STALE_FRAMES   = 5,
    parameter integer      CONFIRM_FRAMES = 1,
    // Which channels are trigger channels. The instrument makes CH4 (the thumb axis) an
    // expression-only channel, so it can never hold the bank's "every selected electrode is
    // released" precondition and block a repeat calibration.
    parameter logic [ZONES-1:0] TRIGGER_ENABLE_MASK = {ZONES{1'b1}}
) (
    input  logic             clk,
    input  logic             rst_n,
    // Sample stream from the scan engine (rtl/mcp3208_scan_engine.sv).
    input  logic [2:0]       channel_id,
    input  logic [11:0]      code,
    input  logic             code_valid,
    input  logic             frame_done,
    // Per-zone trigger thresholds, packed: zone i uses bits [i*12 +: 12].
    input  logic [ZONES*12-1:0] on_thresholds,
    input  logic [ZONES*12-1:0] off_thresholds,
    // Calibration procedure.
    input  logic             cal_request,
    input  logic [ZONES-1:0] cal_mask,
    input  logic             clear_calibration,
    output logic             cal_busy,
    output logic             cal_done,
    output logic             cal_refused,
    // Results, packed the same way (zone i: pressure[i*16 +: 16], age[i*8 +: 8]).
    output logic [ZONES*16-1:0] pressure,
    output logic [ZONES-1:0]    gate,
    output logic [ZONES-1:0]    trigger_on,
    output logic [ZONES-1:0]    trigger_off,
    output logic [ZONES-1:0]    stale,
    output logic [ZONES-1:0]    calibrated,
    output logic [ZONES-1:0]    has_sample,
    output logic [ZONES-1:0]    valid,
    output logic [ZONES-1:0]    cal_refused_zone,
    output logic [ZONES*8-1:0]  age
);
    localparam logic [1:0] CAL_IDLE  = 2'd0;
    localparam logic [1:0] CAL_LATCH = 2'd1;
    localparam logic [1:0] CAL_DONE  = 2'd2;

    logic [1:0]  cal_state;
    logic [2:0]  cal_index;
    logic [ZONES-1:0] zone_calibrate;
    logic            all_released;
    logic            all_ready;

    assign cal_busy = (cal_state != CAL_IDLE);

    // Calibration is only meaningful for a released electrode with a fresh sample.
    always_comb begin
        all_released = 1'b1;
        all_ready    = 1'b1;
        for (integer i = 0; i < ZONES; i = i + 1) begin
            if (cal_mask[i]) begin
                if (gate[i]) all_released = 1'b0;
                // A channel is calibratable when it has produced a sample and that sample
                // is not stale. Requiring a sample inside the CURRENT frame would make the
                // request fail whenever it lands just after a frame tick.
                if (!has_sample[i] || stale[i]) all_ready = 1'b0;
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cal_state     <= CAL_IDLE;
            cal_index     <= 3'd0;
            cal_done      <= 1'b0;
            cal_refused   <= 1'b0;
            zone_calibrate <= '0;
        end else begin
            cal_done       <= 1'b0;
            zone_calibrate <= '0;
            case (cal_state)
                CAL_IDLE: begin
                    cal_index <= 3'd0;
                    if (cal_request) begin
                        if (!all_released) begin
                            // Never re-zero a held electrode; report instead.
                            cal_refused <= 1'b1;
                        end else if (!all_ready) begin
                            cal_refused <= 1'b1;
                        end else begin
                            cal_refused <= 1'b0;
                            cal_state   <= CAL_LATCH;
                        end
                    end
                end
                CAL_LATCH: begin
                    if (cal_mask[cal_index]) zone_calibrate[cal_index] <= 1'b1;
                    if (cal_index + 3'd1 >= ZONES[2:0]) begin
                        cal_index <= 3'd0;
                        cal_state <= CAL_DONE;
                    end else begin
                        cal_index <= cal_index + 3'd1;
                    end
                end
                CAL_DONE: begin
                    cal_done  <= 1'b1;
                    cal_state <= CAL_IDLE;
                end
                default: cal_state <= CAL_IDLE;
            endcase
        end
    end

    genvar z;
    generate
        for (z = 0; z < ZONES; z = z + 1) begin : zone
            pressure_zone #(
                .FILTER_SHIFT(FILTER_SHIFT), .SLEW_STEP(SLEW_STEP),
                .STALE_FRAMES(STALE_FRAMES), .CONFIRM_FRAMES(CONFIRM_FRAMES),
                .TRIGGER_ENABLE(TRIGGER_ENABLE_MASK[z])
            ) channel (
                .clk(clk), .rst_n(rst_n),
                .sample_valid(code_valid && (channel_id == z[2:0])),
                .sample_code(code),
                .frame_done(frame_done),
                .calibrate(zone_calibrate[z]),
                .clear_calibration(clear_calibration),
                .on_threshold(on_thresholds[z*12 +: 12]),
                .off_threshold(off_thresholds[z*12 +: 12]),
                .code(),
                .pressure(pressure[z*16 +: 16]),
                .valid(valid[z]),
                .age(age[z*8 +: 8]),
                .stale(stale[z]),
                .calibrated(calibrated[z]),
                .has_sample(has_sample[z]),
                .cal_refused(cal_refused_zone[z]),
                .gate(gate[z]),
                .trigger_on(trigger_on[z]),
                .trigger_off(trigger_off[z]),
                .state(),
                .saturated()
            );
        end
    endgenerate
endmodule