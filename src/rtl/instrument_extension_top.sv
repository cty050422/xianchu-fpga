// Audio/control board wrapper without the integrated HDMI dashboard.
// The release top is instrument_display_top; see docs/architecture.md.
module instrument_extension_top (
    input  logic       sys_clk_50m,     // V22, 50 MHz, LVCMOS33
    input  logic       rst_n_raw,       // Y12, EXT_KEY with pull-up, LVCMOS15
    input  logic       joy1_z_n_raw,    // PMOD1 IO4, 3.3 V digital switch, active low
    input  logic       joy2_z_n_raw,    // PMOD1 IO5, 3.3 V digital switch, active low
    input  logic       ESP_UART_RX,     // PMOD1 IO7 / AB20, from ESP32 GPIO18
    output logic       ESP_UART_TX,     // PMOD1 IO6 / AA19, to ESP32 GPIO17
    // MCP3208 on PMOD0 (IO4..IO7), 3.3 V
    output logic       SENSOR_CS_N,
    output logic       SENSOR_SCK,
    output logic       SENSOR_MOSI,
    input  logic       SENSOR_MISO,
    // PT8211 on-board stereo DAC and the NS4263 amplifier enable
    output logic       HP_BCK,
    output logic       HP_WS,
    output logic       HP_DIN,
    output logic       PA_EN,
    // Four zone LEDs on PMOD1 (IO0..IO3), active high through 1 kOhm
    output logic [3:0] LED,
    // On-board FPGA UART TX (U15), 115200 8N1: the performance telemetry stream
    output logic       UART_TX
);
    logic audio_clk_12m288;
    logic pll_lock;

    audio_pll_50_to_12m288 pll (
        .clkin_50m(sys_clk_50m),
        .clkout_12m288(audio_clk_12m288),
        .lock(pll_lock)
    );

    instrument_extension_core core (
        .clk_audio_12m288(audio_clk_12m288),
        .pll_lock(pll_lock),
        .rst_n_raw(rst_n_raw),
        // Reuse the proven two-key gesture/debounce logic, now driven only by
        // the joystick push switches. Panel KEY0/KEY1 are not top-level inputs.
        .key_n_raw({joy2_z_n_raw, joy1_z_n_raw}),
        .SENSOR_SCK(SENSOR_SCK), .SENSOR_MOSI(SENSOR_MOSI),
        .SENSOR_CS_N(SENSOR_CS_N), .SENSOR_MISO(SENSOR_MISO),
        .HP_BCK(HP_BCK), .HP_WS(HP_WS), .HP_DIN(HP_DIN), .PA_EN(PA_EN),
        .LED(LED), .UART_TX(UART_TX), .ESP_UART_RX(ESP_UART_RX), .ESP_UART_TX(ESP_UART_TX),
        // No logic analyser is attached to the board: the interesting state travels in the
        // telemetry stream, and the remaining analysis ports are left open exactly like the
        // frozen board top does. They are still checked by simulation and by the netlist report.
        .diag_pcm_voice(), .diag_pcm_layer(), .diag_pcm_out(), .diag_mix_clipped(),
        .diag_layer_valid(), .diag_layer_owner(), .diag_layer_mask(), .diag_layer_gain(),
        .diag_layer_switching(), .diag_layer_partials(),
        .diag_vibrato_ratio(), .diag_vibrato_depth(),
        .diag_vibrato_center_valid(), .diag_vibrato_stale(),
        .diag_fx_ready(), .diag_fx_peak(), .diag_fx_clip(),
        .diag_viz_frames(), .diag_viz_rejected(), .diag_test_mode(),
        .diag_zone_valid(), .diag_scan_timeouts(), .diag_records_sent(), .diag_uart_rejected(),
        .diag_core_rst_n(), .diag_pll_locked()
    );
endmodule
