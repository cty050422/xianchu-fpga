// Board-independent MCP3208 scan and per-zone input conditioning.
// ADC_CHANNELS and ZONES can differ: raw joystick channels need no trigger zone.
// The integrated product uses eight ADC channels; defaults support the base core.
module zone_input_top #(
    parameter integer      ZONES          = 5,
    parameter integer      SCAN_INTERVAL  = 12_288,   // 1 ms scan frame at 12.288 MHz
    parameter integer      FRAME_TIMEOUT  = 4_096,
    parameter integer      ADC_CLK_DIV    = 8,
    parameter integer      ADC_SETTLE     = 64,
    parameter integer      ADC_CS_HIGH    = 16,
    parameter integer      FILTER_SHIFT   = 3,
    parameter logic [15:0] SLEW_STEP      = 16'd4096,
    parameter integer      STALE_FRAMES   = 5,
    parameter integer      CONFIRM_FRAMES = 1,
    parameter logic [ZONES-1:0] TRIGGER_ENABLE_MASK = {ZONES{1'b1}},
    // Keep five conditioned playing channels; an extension may scan CH5 as a raw
    // control and consume it from the tagged code stream without adding a zone.
    parameter integer      ADC_CHANNELS   = 5
) (
    input  logic                clk,
    input  logic                rst_n,
    input  logic                enable,
    // SPI wires to the converter (no pin is assigned here)
    output logic                SENSOR_SCK,
    output logic                SENSOR_MOSI,
    output logic                SENSOR_CS_N,
    input  logic                SENSOR_MISO,
    // Per-zone trigger thresholds, packed: zone i uses bits [i*12 +: 12].
    input  logic [ZONES*12-1:0] on_thresholds,
    input  logic [ZONES*12-1:0] off_thresholds,
    // Calibration procedure.
    input  logic                cal_request,
    input  logic [ZONES-1:0]    cal_mask,
    input  logic                clear_calibration,
    output logic                cal_busy,
    output logic                cal_done,
    output logic                cal_refused,
    // Expression results, packed (zone i: pressure[i*16 +: 16], age[i*8 +: 8]).
    output logic [ZONES*16-1:0] pressure,
    output logic [ZONES-1:0]    gate,
    output logic [ZONES-1:0]    trigger_on,
    output logic [ZONES-1:0]    trigger_off,
    output logic [ZONES-1:0]    stale,
    output logic [ZONES-1:0]    calibrated,
    output logic [ZONES-1:0]    has_sample,
    output logic [ZONES-1:0]    zone_valid,   // this channel was converted in the current frame
    output logic [ZONES*8-1:0]  age,
    // Scan telemetry (what a diagnostic image or a logic analyser can show)
    output logic [2:0]          channel_id,
    output logic [11:0]         code,
    output logic                code_valid,
    output logic [7:0]          frame_id,
    output logic [7:0]          channel_seen,
    output logic                frame_done,
    output logic                frame_incomplete,
    output logic [15:0]         frame_clocks,
    output logic [15:0]         frame_skew_clocks,
    output logic [15:0]         refused_requests,
    output logic [15:0]         timeouts
);
    mcp3208_scan_engine #(
        .CHANNELS(ADC_CHANNELS), .SCAN_INTERVAL(SCAN_INTERVAL), .FRAME_TIMEOUT(FRAME_TIMEOUT),
        .ADC_CLK_DIV(ADC_CLK_DIV), .ADC_SETTLE(ADC_SETTLE), .ADC_CS_HIGH(ADC_CS_HIGH)
    ) scan (
        .clk(clk), .rst_n(rst_n), .enable(enable),
        .SENSOR_SCK(SENSOR_SCK), .SENSOR_MOSI(SENSOR_MOSI),
        .SENSOR_CS_N(SENSOR_CS_N), .SENSOR_MISO(SENSOR_MISO),
        .channel_id(channel_id), .code(code), .code_valid(code_valid),
        .frame_id(frame_id), .channel_seen(channel_seen),
        .frame_done(frame_done), .frame_incomplete(frame_incomplete),
        .frame_clocks(frame_clocks), .frame_skew_clocks(frame_skew_clocks),
        .scan_busy(), .refused_requests(refused_requests), .timeouts(timeouts)
    );

    zone_bank #(
        .ZONES(ZONES), .FILTER_SHIFT(FILTER_SHIFT), .SLEW_STEP(SLEW_STEP),
        .STALE_FRAMES(STALE_FRAMES), .CONFIRM_FRAMES(CONFIRM_FRAMES),
        .TRIGGER_ENABLE_MASK(TRIGGER_ENABLE_MASK)
    ) zones (
        .clk(clk), .rst_n(rst_n),
        .channel_id(channel_id), .code(code), .code_valid(code_valid),
        .frame_done(frame_done),
        .on_thresholds(on_thresholds), .off_thresholds(off_thresholds),
        .cal_request(cal_request), .cal_mask(cal_mask),
        .clear_calibration(clear_calibration),
        .cal_busy(cal_busy), .cal_done(cal_done), .cal_refused(cal_refused),
        .pressure(pressure), .gate(gate), .trigger_on(trigger_on),
        .trigger_off(trigger_off), .stale(stale), .calibrated(calibrated),
        .has_sample(has_sample), .valid(zone_valid), .cal_refused_zone(), .age(age)
    );
endmodule
