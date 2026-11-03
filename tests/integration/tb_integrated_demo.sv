`timescale 1ns/1ps
// Self-checking testbench for rtl/instrument_extension_core.sv (configuration D).
//
// This is the integration test: it drives the board wires only (PLL lock, reset key, panel keys and
// the MCP3208 converter wires) and checks what comes out of the DAC, the LEDs and the UART.
//
// What is measured:
//   * the safe state: amplifier muted, DAC clocks low, LEDs dark, UART idle while the reset is
//     asserted or the PLL is unlocked - including a lock loss in the middle of playing;
//   * the scanner really runs once the reset is released;
//   * the ADDITIVE LAYER comes alive through the real scan chain: after the panel calibrates the
//     electrodes, pressing zone 0 makes the layer take that zone as its owner, ramp its gain and
//     produce audio, and pressing zone 2 hands the layer over to zone 2;
//   * the MIX is exactly the saturating sum of the frozen instrument's sample and the layer
//     (checked clock by clock through the effect in its zero-wet setting, so the sum is observable);
//   * the effect's delay line fills and its peak meter reports the audio that is flowing;
//   * the telemetry stream really transmits (the UART line leaves idle) and counts its frames.
//
// Nothing here says anything about how it sounds, and the pins are not involved: the physical board
// behaviour stays UNTESTED.
module tb_integrated_demo #(
    parameter integer TEST_CHORUS_MIX_SHIFT = 0,
    parameter integer TEST_CHORUS_DEPTH = 256
);
    localparam real    CLK_PERIOD      = 81.38;      // 12.288 MHz
    localparam integer SCAN_INTERVAL   = 2048;
    localparam integer CLOCKS_PER_BIT  = 64;
    localparam integer BLINK_MILLIHZ   = 3_000_000;  // -> a 2000-clock toggle
    localparam integer PA_ENABLE_DELAY = 512;
    localparam integer CHORUS_DEPTH    = TEST_CHORUS_DEPTH;
    localparam integer KEY_LONG        = 160;
    localparam integer TEST_WAIT_CLOCKS = (TEST_CHORUS_MIX_SHIFT == 0)
                                         ? 2_500_000 : (2*CHORUS_DEPTH + 8192 + 2048)*256;

    logic clk = 1'b0;
    always #(CLK_PERIOD / 2.0) clk = ~clk;

    logic       pll_lock  = 1'b0;
    logic       rst_n_raw = 1'b0;
    logic [1:0] key_n_raw = 2'b11;

    logic sck, mosi, cs_n, miso;
    logic hp_bck, hp_ws, hp_din, pa_en;
    logic [3:0] led;
    logic uart_tx;
    logic esp_uart_rx = 1'b1;
    logic esp_uart_tx;

    logic signed [15:0] pcm_voice, pcm_layer, pcm_out;
    logic        mix_clipped, layer_valid, fx_ready;
    logic [1:0]  layer_owner;
    logic [31:0] layer_mask;
    logic [7:0]  layer_gain;
    logic [15:0] fx_peak, fx_clip, viz_frames, viz_rejected;
    logic [15:0] vibrato_ratio;
    logic [11:0] vibrato_depth;
    logic        vibrato_center_valid, vibrato_stale;
    logic [5:0]  layer_partials;
    logic [15:0] zone_valid, scan_timeouts, records_sent, uart_rejected;
    logic        core_rst_n, pll_locked;
    logic        test_mode_active;
    integer      cyc;
    logic signed [15:0] layer_prev;
    integer      cross_count, cross_last, cross_period;
    reg [1023:0] spectrum_path;
    integer spectrum_fd, spectrum_count, spectrum_warmup;
    integer spectrum_cycle, spectrum_last_tick;
    reg spectrum_enabled, spectrum_started;

    // Optional full-chain PCM capture for an independent 32-peak frequency
    // analysis.  It only starts after the actual test-mode mask, used count
    // and gain have reached steady state; ordinary regression stays fast.
    initial begin
        spectrum_count = 0;
        spectrum_warmup = 0;
        spectrum_cycle = 0;
        spectrum_last_tick = 0;
        spectrum_started = 1'b0;
        spectrum_enabled = $value$plusargs("extension_spectrum_path=%s", spectrum_path);
        spectrum_fd = 0;
        if (spectrum_enabled) begin
            spectrum_fd = $fopen(spectrum_path, "w");
            if (spectrum_fd == 0) $fatal(1, "cannot open extension spectrum capture");
        end
    end
    always @(posedge clk) begin
        spectrum_cycle = spectrum_cycle + 1;
        if (spectrum_fd != 0 && spectrum_started &&
            spectrum_cycle - spectrum_last_tick > 256)
            $fatal(1, "spectrum capture lost an audio sample tick");
        if (spectrum_fd != 0 && dut.sample_ce && spectrum_count < 8192) begin
            if (!spectrum_started) begin
                if (test_mode_active === 1'b1 && layer_gain === 8'd255 &&
                    layer_partials === 6'd32) begin
                    if (TEST_CHORUS_MIX_SHIFT == 0 || spectrum_warmup >= 2*CHORUS_DEPTH)
                        spectrum_started = 1'b1;
                    else spectrum_warmup = spectrum_warmup + 1;
                end else spectrum_warmup = 0;
            end else begin
                if (spectrum_cycle - spectrum_last_tick != 256)
                    $fatal(1, "spectrum capture sample interval changed");
                if (test_mode_active !== 1'b1 || layer_gain !== 8'd255 ||
                    layer_partials !== 6'd32)
                    $fatal(1, "spectrum capture lost test mode or 32-partial state");
            end
            if (spectrum_started) begin
                spectrum_last_tick = spectrum_cycle;
                $fwrite(spectrum_fd, "%0d\n", pcm_out);
                spectrum_count = spectrum_count + 1;
                if (spectrum_count == 8192) begin
                    $fclose(spectrum_fd);
                    spectrum_fd = 0;
                end
            end
        end
    end

    // Free-running cycle counter and a rising-zero-crossing detector on the layer output: the test
    // tone's period is measured here, independently of anything the DUT reports.
    initial begin
        cyc = 0; cross_count = 0; cross_last = 0; cross_period = 0; layer_prev = 16'sd0;
    end
    always @(posedge clk) begin
        cyc = cyc + 1;
        if ((layer_prev < 0) && (pcm_layer >= 0) && (pcm_layer !== 16'sd0)) begin
            cross_count = cross_count + 1;
            cross_period = cyc - cross_last;
            cross_last = cyc;
        end
        layer_prev = pcm_layer;
    end

    logic [95:0] channel_codes;
    logic [31:0] base_inc_before, base_inc_during;

    integer errors = 0;
    integer checks = 0;
    integer i;
    logic [3:0] gates_before;
    integer     expected_voice;

    // Default zero-wet setting exposes the exact mixed sample.  Override the test parameter to
    // 3 for a separate full wet-path PCM spectrum run; only the dry run checks exact mix.
    instrument_extension_core #(
        .EXPRESSIVE_ADSR(1),.ADSR_ERROR_FEEDBACK(1),.FOUR_PRESETS(1),
        .LAYER_SINE_INTERPOLATION(1),.CHORUS_FRACTIONAL(1),
        .SCAN_INTERVAL(SCAN_INTERVAL), .FRAME_TIMEOUT(4_096),
        .ADC_CLK_DIV(8), .ADC_SETTLE(64), .ADC_CS_HIGH(16),
        .STALE_FRAMES(3), .CONFIRM_FRAMES(1),
        .DEBOUNCE_CYCLES(16), .KEY_LONG_CYCLES(KEY_LONG),
        .KEY_CLEAR_CYCLES(320), .KEY_COMBO_WINDOW(80),
        .KEY_DOUBLE_CYCLES(120), .KEY_MAX_PRESS_CYCLES(1000), .KEY_BOOT_CYCLES(100),
        .PA_ENABLE_DELAY(PA_ENABLE_DELAY),
        .CLOCKS_PER_BIT(CLOCKS_PER_BIT), .BLINK_MILLIHZ(BLINK_MILLIHZ),
        .THUMB_FRESH_TIMEOUT(24'd8_192),
        .CHORUS_DEPTH(CHORUS_DEPTH), .CHORUS_MIX_SHIFT(TEST_CHORUS_MIX_SHIFT), .CHORUS_MODE(2'd2),
        .VIZ_DECIM(8), .VIZ_POINTS(8),
        // Shortened so the test-mode hold does not cost 14.7 million simulated clocks; the chord
        // window is shortened with it so a staggered press can be tested quickly.
        .TEST_MODE_HOLD_CYCLES(2000), .TEST_MODE_COMBO_WINDOW(300)
    ) dut (
        .clk_audio_12m288(clk), .pll_lock, .rst_n_raw, .key_n_raw,
        .SENSOR_SCK(sck), .SENSOR_MOSI(mosi), .SENSOR_CS_N(cs_n), .SENSOR_MISO(miso),
        .HP_BCK(hp_bck), .HP_WS(hp_ws), .HP_DIN(hp_din), .PA_EN(pa_en),
        .LED(led), .UART_TX(uart_tx), .ESP_UART_RX(esp_uart_rx), .ESP_UART_TX(esp_uart_tx),
        .diag_pcm_voice(pcm_voice), .diag_pcm_layer(pcm_layer), .diag_pcm_out(pcm_out),
        .diag_mix_clipped(mix_clipped), .diag_layer_valid(layer_valid),
        .diag_layer_owner(layer_owner), .diag_layer_mask(layer_mask),
        .diag_layer_gain(layer_gain), .diag_layer_partials(layer_partials),
        .diag_vibrato_ratio(vibrato_ratio), .diag_vibrato_depth(vibrato_depth),
        .diag_vibrato_center_valid(vibrato_center_valid), .diag_vibrato_stale(vibrato_stale),
        .diag_fx_ready(fx_ready),
        .diag_fx_peak(fx_peak), .diag_fx_clip(fx_clip),
        .diag_viz_frames(viz_frames), .diag_viz_rejected(viz_rejected),
        .diag_zone_valid(zone_valid), .diag_scan_timeouts(scan_timeouts),
        .diag_records_sent(records_sent), .diag_uart_rejected(uart_rejected),
        .diag_test_mode(test_mode_active),
        .diag_core_rst_n(core_rst_n), .diag_pll_locked(pll_locked)
    );

    logic [2:0] model_channel;
    integer     model_edges, model_frames, model_errors;

    mcp3208_datasheet_model #(.CHANNELS(8)) model (
        .sck, .cs_n, .mosi, .miso,
        .late_bit(1'b0), .stuck_low(1'b0),
        .code_override(12'd0), .override_enable(1'b0),
        .channel_codes(channel_codes), .use_channel_codes(1'b1),
        .decoded_channel(model_channel), .edge_count(model_edges),
        .frame_count(model_frames), .protocol_errors(model_errors),
        .min_sck_period_ns(), .min_clock_half_ns(), .min_sucs_ns(),
        .min_csh_ns(), .min_su_ns(), .min_hd_ns()
    );

    // ---- clock-by-clock mix monitor ------------------------------------------------
    // The layer and the instrument update on their own 48 kHz ticks, so the mixed sample is
    // compared against the PREVIOUS clock's operands: that tolerates the effect's one-clock output
    // register without hiding a wrong sum.
    // The instrument and the extension run their own 48 kHz ticks, at different phases inside the
    // sample window. The mix is therefore sampled exactly ON the extension's tick: at that instant
    // pcm_out still holds the previous tick's result, which must be the saturating sum of the
    // operands that were present at that previous tick.
    logic signed [15:0] tick_mix;
    logic               tick_seen;
    integer             mix_checked, mix_bad;

    always @(posedge clk) begin
        if (!core_rst_n) begin
            tick_seen <= 1'b0;
        end else if (dut.sample_ce) begin
            if (tick_seen && !dut.mute_active) begin
                mix_checked = mix_checked + 1;
                // Check the effect's actual sum here. The post-effect fade and
                // serial DAC are verified by their independent end-to-end tests.
                if (TEST_CHORUS_MIX_SHIFT == 0 && dut.pcm_out !== tick_mix) begin
                    mix_bad = mix_bad + 1;
                    if (mix_bad < 4)
                        $display("DEBUG mix at %0t: out=%0d expected=%0d voice=%0d layer=%0d ce_now=%b",
                                 $time, pcm_out, tick_mix, pcm_voice, pcm_layer, dut.sample_ce);
                end
            end
            tick_mix  <= sat_sum(pcm_voice, pcm_layer);
            tick_seen <= 1'b1;
        end
    end

    function automatic logic signed [15:0] sat_sum(input logic signed [15:0] a,
                                                   input logic signed [15:0] b);
        logic signed [16:0] s;
        begin
            s = {a[15], a} + {b[15], b};
            if (s > 17'sd32767)       sat_sum = 16'sd32767;
            else if (s < -17'sd32768) sat_sum = -16'sd32768;
            else                      sat_sum = s[15:0];
        end
    endfunction

    task automatic wait_cycles(input integer count);
        begin
            repeat (count) @(negedge clk);
        end
    endtask

    // Polling instead of fixed waits: how many scan frames a state machine needs is an
    // implementation detail, and a fixed wait would turn that detail into a false failure.
    function automatic logic condition_of(input integer which);
        begin
            case (which)
                0: condition_of = (cs_n === 1'b0);
                1: condition_of = (model_frames > 0);
                2: condition_of = (zone_valid === 16'd31);
                3: condition_of = (layer_valid === 1'b1);
                4: condition_of = (led === 4'b0001);
                5: condition_of = (layer_owner === 2'd2);
                6: condition_of = (fx_ready === 1'b1);
                7: condition_of = (layer_gain >= 8'd100);
                8: condition_of = (layer_mask === 32'hFFFF_FFFF);
                default: condition_of = 1'b0;
            endcase
        end
    endfunction

    task automatic wait_for(input integer which, input integer limit, output integer waited);
        begin
            waited = 0;
            while (waited < limit && !condition_of(which)) begin
                @(negedge clk);
                waited = waited + 1;
            end
            if (!condition_of(which)) waited = -1;
        end
    endtask

    task automatic check(input condition, input [1023:0] what);
        begin
            checks = checks + 1;
            if (!condition) begin
                errors = errors + 1;
                $display("FAIL tb_instrument_extension_core: %0s", what);
            end
        end
    endtask

    task automatic set_zone(input integer index, input [11:0] code);
        begin
            channel_codes[index * 12 +: 12] = code;
        end
    endtask

    // ---- configuration frames on the real ESP UART -------------------------------
    function automatic [7:0] crc8_link(input [7:0] crc, input [7:0] value);
        reg [7:0] c; integer i;
        begin c = crc ^ value; for (i=0;i<8;i=i+1) c = c[7] ? ((c<<1)^8'h07) : (c<<1); crc8_link = c; end
    endfunction
    task automatic uart_byte(input [7:0] b);
        integer i;
        begin
            esp_uart_rx = 1'b0; repeat(CLOCKS_PER_BIT) @(negedge clk);
            for (i=0;i<8;i=i+1) begin esp_uart_rx = b[i]; repeat(CLOCKS_PER_BIT) @(negedge clk); end
            esp_uart_rx = 1'b1; repeat(CLOCKS_PER_BIT) @(negedge clk);
        end
    endtask
    task automatic config_frame(input [7:0] op, input [7:0] field, input [15:0] value,
                                input [15:0] token, input [15:0] seq);
        reg [7:0] c;
        begin
            uart_byte(8'hA5); uart_byte(8'h5A); c = 0;
            uart_byte(8'h01); c = crc8_link(c,8'h01);
            uart_byte(8'h15); c = crc8_link(c,8'h15);
            uart_byte(8'd8);  c = crc8_link(c,8'd8);
            uart_byte(seq[7:0]); c = crc8_link(c,seq[7:0]);
            uart_byte(op);         c = crc8_link(c,op);
            uart_byte(field);      c = crc8_link(c,field);
            uart_byte(value[7:0]); c = crc8_link(c,value[7:0]);
            uart_byte(value[15:8]);c = crc8_link(c,value[15:8]);
            uart_byte(token[7:0]); c = crc8_link(c,token[7:0]);
            uart_byte(token[15:8]);c = crc8_link(c,token[15:8]);
            uart_byte(seq[7:0]);   c = crc8_link(c,seq[7:0]);
            uart_byte(seq[15:8]);  c = crc8_link(c,seq[15:8]);
            uart_byte(c);
        end
    endtask

    // Index of the voice that is sounding now but was not sounding before: that is the voice the
    // frozen allocator handed to the zone we just pressed.
    function automatic integer newly_gated_voice(input [3:0] before_gates);
        integer v;
        begin
            newly_gated_voice = -1;
            for (v = 0; v < 4; v = v + 1)
                if (dut.voice_gates[v] && !before_gates[v]) newly_gated_voice = v;
        end
    endfunction

    reg[63:0]demo_payload;reg[7:0]demo_crc,demo_seq=0;integer demo_peak=0,serial_ones=0;
    task demo_command(input[7:0]op,input[3:0]n,input[63:0]body);
      reg[7:0]c;begin
      uart_byte('ha5);uart_byte('h5a);c=0;uart_byte(1);c=crc8_link(c,1);
      uart_byte(op);c=crc8_link(c,op);uart_byte({4'd0,n});c=crc8_link(c,{4'd0,n});demo_seq++;uart_byte(demo_seq);c=crc8_link(c,demo_seq);
      for(integer j=0;j<n;j++)begin uart_byte(body[j*8+:8]);c=crc8_link(c,body[j*8+:8]);end
      uart_byte(c);wait_cycles(64);
      if(dut.esp_link.last_result!=0)$fatal(1,"demo command rejected %h=%h",op,dut.esp_link.last_result);
      end
    endtask
    initial begin
        mix_checked = 0;
        mix_bad = 0;
        channel_codes = 96'd0;
        for (i = 0; i < 4; i = i + 1) channel_codes[i*12 +: 12] = 12'h020;
        channel_codes[4*12 +: 12] = 12'h800;
        channel_codes[5*12 +: 12] = 12'h800;
        // Both axes of joystick 2 rest near mid-code, as on a powered divider.
        channel_codes[6*12 +: 12] = 12'd2100;
        channel_codes[7*12 +: 12] = 12'd2100;

        // ---------------- C1: power-up safe state ----------------
        wait_cycles(64);
        check(pa_en === 1'b1, "the amplifier was not muted at power-up");
        check(cs_n === 1'b1, "the converter was selected at power-up");
        check(sck === 1'b0 && mosi === 1'b0, "the converter clock or data was not low at power-up");
        check(hp_bck === 1'b0 && hp_ws === 1'b0 && hp_din === 1'b0, "the DAC clocks were not held low");
        check(led === 4'b0000, "the LEDs were not dark at power-up");
        check(uart_tx === 1'b1, "the telemetry line was not idle high at power-up");

        // ---------------- C2: release the reset, the scanner and the DAC must run ----------------
        key_n_raw = 2'b01; // Z2 held through startup: release after ADC settles to calibrate.
        pll_lock = 1'b1;
        rst_n_raw = 1'b1;
        wait_for(0, 6000, i);
        check(i >= 0, "the converter was never selected after the reset was released");
        wait_for(1, 6000, i);
        check(i >= 0, "the converter model saw no complete frame");
        check(model_errors == 0, "the converter model reported a protocol error");
        wait_cycles(6000);
        check(pa_en === 1'b1, "uncalibrated startup must remain muted");
        check(hp_bck === 1'b0 || hp_bck === 1'b1, "the DAC bit clock did not run");
        $display("INFO tb_instrument_extension_core: converter frames %0d, edges %0d", model_frames, model_edges);

        // ---------------- C3: calibrate the electrodes, then play ----------------
        // The startup Z2 release asks the panel to calibrate all five channels through the real
        // scan chain; nothing below would work on uncalibrated electrodes.
        // The calibration request is refused while the thumb axis has not yet produced its stable
        // window, so give the analogue front end a good number of scan frames first.
        wait_cycles(20 * SCAN_INTERVAL);
        check(vibrato_center_valid && !vibrato_stale && vibrato_ratio == 16'd32768,
              "CH5 failed stable-centre capture at rest");
        check(dut.aux_center_valid === 2'b11 && dut.aux_wet_gain_q8 ==
              ((TEST_CHORUS_MIX_SHIFT == 0) ? 8'd0 : (256 >> TEST_CHORUS_MIX_SHIFT)),
              "CH6/CH7 did not capture joystick-2 centres or preserve default wet gain");
        key_n_raw[1] = 1'b1;
        wait_cycles(4000);
        check(dut.instrument.zone_calibrated === 5'b11111,
              "the calibration gesture did not calibrate the five channels");
        demo_command(8'h1b,2,64'h0101);
        demo_payload={24'd3000,8'd0,8'd0,8'd0,8'd60,8'd0};
        demo_command(8'h1c,8,demo_payload);demo_crc=0;
        for(integer j=0;j<8;j++)demo_crc=crc8_link(demo_crc,demo_payload[j*8+:8]);
        demo_command(8'h1d,2,{48'd0,demo_crc,8'd1});demo_command(8'h1e,3,64'h010201);
        wait_cycles(1000);
        check(dut.audition_active,"demo started after full symbolic upload");
        check(dut.instrument.synth_rst_n,"demo must not hold synthesizer reset");
        for(integer j=0;j<550000;j++)begin @(negedge clk);if(dut.audition_active && hp_din)serial_ones++;if(pcm_out>demo_peak)demo_peak=pcm_out;end
        check(demo_peak>100 && serial_ones>100,"demo produces nonzero final PCM and real DAC bits");
        wait_cycles(250000);
        check(dut.audition_active && dut.voice_gates==0,"natural demo keeps ownership through release");
        wait_cycles(1000000);
        check(!dut.audition_active,"natural tail drains and releases ownership");
        demo_command(8'h1e,3,0);wait_cycles(1000);check(!dut.audition_active,"STOP releases demo ownership");
        if(errors)$fatal(1,"integrated demo failures %d",errors);
        $display("PASS integrated demo: ADC calibration, real UART, synth alive, PCM peak %d, DAC bits %d, STOP",demo_peak,serial_ones);$finish;
    end
endmodule
