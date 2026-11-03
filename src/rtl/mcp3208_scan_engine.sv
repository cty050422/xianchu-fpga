// Scan engine: the generic scan scheduler (rtl/mcp3208_scanner.sv) bound to the real
// MCP3208 SPI driver (rtl/mcp3208_adc.sv). Every pin here is a port; the module is
// board-independent and is NOT part of the shipped KEY0/KEY1 board bitstream.
//
// Measured by sim/tb_mcp3208_scanner.sv: one scan frame converts CH0..CH4 in order in
// ~1935 clk (157.5 us); with SCAN_INTERVAL = 12_288 clk (1 ms) each channel is sampled
// at ~1 kHz, which is the M1 budget. Inter-channel skew inside one frame is reported
// (frame_skew_clocks) instead of being assumed.
module mcp3208_scan_engine #(
    parameter integer CHANNELS      = 5,
    parameter integer SCAN_INTERVAL = 12_288,
    parameter integer FRAME_TIMEOUT = 4_096,
    parameter integer ADC_CLK_DIV   = 8,
    parameter integer ADC_SETTLE    = 64,
    parameter integer ADC_CS_HIGH   = 16
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        enable,
    output logic        SENSOR_SCK,
    output logic        SENSOR_MOSI,
    output logic        SENSOR_CS_N,
    input  logic        SENSOR_MISO,
    output logic [2:0]  channel_id,
    output logic [11:0] code,
    output logic        code_valid,
    output logic [7:0]  frame_id,
    output logic [7:0]  channel_seen,
    output logic        frame_done,
    output logic        frame_incomplete,
    output logic [15:0] frame_clocks,
    output logic [15:0] frame_skew_clocks,
    output logic        scan_busy,
    output logic [15:0] refused_requests,
    output logic [15:0] timeouts
);
    logic        adc_start;
    logic [2:0]  adc_channel;
    logic        adc_busy;
    logic        adc_data_valid;
    logic [11:0] adc_data;
    logic        adc_dropped;
    logic        adc_too_soon;

    mcp3208_adc #(
        .CLK_DIV(ADC_CLK_DIV), .SETTLE_CYCLES(ADC_SETTLE), .CS_HIGH_CYCLES(ADC_CS_HIGH)
    ) adc (
        .clk(clk), .rst_n(rst_n),
        .start(adc_start), .channel(adc_channel),
        .sck(SENSOR_SCK), .mosi(SENSOR_MOSI), .cs_n(SENSOR_CS_N), .miso(SENSOR_MISO),
        .data(adc_data), .data_valid(adc_data_valid),
        .busy(adc_busy), .request_dropped(adc_dropped), .request_too_soon(adc_too_soon)
    );

    mcp3208_scanner #(
        .CHANNELS(CHANNELS), .SCAN_INTERVAL(SCAN_INTERVAL), .FRAME_TIMEOUT(FRAME_TIMEOUT)
    ) scan (
        .clk(clk), .rst_n(rst_n), .enable(enable),
        .adc_start(adc_start), .adc_channel(adc_channel),
        .adc_busy(adc_busy), .adc_data_valid(adc_data_valid), .adc_data(adc_data),
        .adc_dropped(adc_dropped), .adc_too_soon(adc_too_soon),
        .channel_id(channel_id), .code(code), .code_valid(code_valid),
        .frame_id(frame_id), .channel_seen(channel_seen),
        .frame_done(frame_done), .frame_incomplete(frame_incomplete),
        .frame_clocks(frame_clocks), .frame_skew_clocks(frame_skew_clocks),
        .scan_busy(scan_busy), .refused_requests(refused_requests), .timeouts(timeouts)
    );
endmodule
