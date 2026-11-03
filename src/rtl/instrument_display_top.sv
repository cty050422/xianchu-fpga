// Integrated Tang Mega 60K wrapper: audio, external controls, telemetry and DVI/HDMI.
// Board assignments: src/gowin/narrative/narrative.cst; build instructions: docs/build.md.
// Audio generation is hardware-only; ESP32-S3 owns the OLED I2C bus by default.
module instrument_display_top #(
    // The assembled product uses S3 GPIO8/9 as the OLED's only I2C master.
    // Set explicitly to 1 only for the separately wired FPGA-master alternative.
    parameter bit FPGA_OLED_MASTER = 1'b0
) (
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
    output logic       UART_TX,
    output wire OLED_SCL,inout wire OLED_SDA,
    output wire [2:0] tmds_d_p_0,tmds_d_n_0,
    output wire tmds_clk_p_0,tmds_clk_n_0,
    output wire hpd_en
);
    wire [19:0] pairing_code;
    wire [3:0] on_mask,voice_gates;
    (* keep = "true" *) wire sample_ce;
    wire calibrated,mapping_ready;
    wire [63:0] levels;wire [7:0] voice_regions;wire group_b;
    wire signed [15:0] pcm_x,pcm_y;
    wire [1:0] mode,preset,expression;
    wire [5:0] step;
    wire [3:0] target;
    wire [15:0] wrong;
    wire[2:0]transport;wire score_valid,octave;
    (* keep = "true" *) wire gao_reset_n, gao_pll_locked;
    (* keep = "true" *) wire [31:0] gao_target_mask;
    wire core_reset;
    assign core_reset = gao_reset_n;
    logic audio_clk_12m288;
    logic pll_lock;

    // Registered observation clock: audio clock /256, sampled halfway between
    // audio sample updates. It drives GAO only, never the sound generator.
    (* keep = "true" *) logic [6:0] ch_clock_div;
    (* keep = "true" *) logic chorus_capture_clk;
    always_ff @(posedge audio_clk_12m288 or negedge rst_n_raw) begin
        if (!rst_n_raw) begin
            ch_clock_div <= '0;
            chorus_capture_clk <= 1'b0;
        end else begin
            ch_clock_div <= ch_clock_div + 1'b1;
            if (ch_clock_div == 7'd127) chorus_capture_clk <= ~chorus_capture_clk;
        end
    end
    wire [255:0] ch_packet, additive_packet;
    wire [37:0] ch_control;
    (* keep = "true" *) wire ch_test;
    (* keep = "true" *) wire [15:0] ch_tag = 16'hC726;
    (* keep = "true" *) wire signed [15:0] ch_output;
    (* keep = "true" *) wire [11:0] ch_adc7, ch_center, ch_filtered;
    (* keep = "true" *) wire ch_center_valid, ch_stale;
    assign {ch_adc7,ch_center,ch_filtered,ch_center_valid,ch_stale} = ch_control;
    (* keep = "true" *) wire [7:0] adsr_model = 8'd4;
    (* keep = "true" *) wire [15:0] adsr_attack_count, adsr_decay_count, adsr_release_count;
    (* keep = "true" *) wire [2:0] adsr_stage_valid, adsr_stage_overflow;
    (* keep = "true" *) wire adsr_stage_done;
    (* keep = "true" *) wire [1:0] adsr_captured_preset;
    (* keep = "true" *) logic adsr_gate;
    (* keep = "true" *) logic [15:0] adsr_level;
    (* keep = "true" *) logic [1:0] adsr_preset;
    (* keep = "true" *) logic [15:0] adsr_start, adsr_256, adsr_768, adsr_1024;
    (* keep = "true" *) logic adsr_done;
    (* keep = "true" *) wire adsr_capture_done;
    assign adsr_capture_done = adsr_done && adsr_stage_done;
    (* keep = "true" *) logic [7:0] adsr_event_count;

    audio_pll_50_to_12m288 pll (
        .clkin_50m(sys_clk_50m),
        .clkout_12m288(audio_clk_12m288),
        .lock(pll_lock)
    );

    // Enable the evaluated ADSR curve only in the current main board image.
    wire lat_probe_valid; wire [15:0] lat_probe_us; // driven by display_capture below
    instrument_extension_core #(.EXPRESSIVE_ADSR(1'b1), .FOUR_PRESETS(1'b1),.MUSICAL_PRESETS(1'b1),
        .ADSR_ERROR_FEEDBACK(1'b1), .LAYER_SINE_INTERPOLATION(1'b1),
        .CHORUS_FRACTIONAL(1'b1)) core (
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
        // GAO observes the same running main design through explicit passive ports.
        .diag_pcm_voice(pcm_x), .diag_pcm_layer(), .diag_pcm_out(pcm_y), .diag_mix_clipped(),
        .lat_valid_in(lat_probe_valid), .lat_us_in(lat_probe_us),
        .diag_layer_valid(), .diag_layer_owner(), .diag_layer_mask(), .diag_layer_gain(),
        .diag_layer_switching(), .diag_layer_partials(),
        .diag_vibrato_ratio(), .diag_vibrato_depth(),
        .diag_vibrato_center_valid(), .diag_vibrato_stale(),
        .diag_fx_ready(), .diag_fx_peak(), .diag_fx_clip(),
        .diag_viz_frames(), .diag_viz_rejected(), .diag_test_mode(ch_test),
        .diag_chorus_actual(ch_output), .diag_chorus_snapshot(ch_packet),
        .diag_chorus_control(ch_control), .diag_additive_snapshot(additive_packet),
        .diag_additive_mask(gao_target_mask),
        .diag_adsr_attack_count(adsr_attack_count), .diag_adsr_decay_count(adsr_decay_count),
        .diag_adsr_release_count(adsr_release_count), .diag_adsr_stage_valid(adsr_stage_valid),
        .diag_adsr_stage_overflow(adsr_stage_overflow), .diag_adsr_stage_done(adsr_stage_done),
        .diag_adsr_captured_preset(adsr_captured_preset),
        .diag_zone_valid(), .diag_scan_timeouts(), .diag_records_sent(), .diag_uart_rejected(),
        .diag_core_rst_n(gao_reset_n), .diag_pll_locked(gao_pll_locked),
        .diag_adsr_sample_ce(), .diag_adsr_gate(adsr_gate),
        .diag_adsr_level(adsr_level), .diag_adsr_preset(adsr_preset),
        .diag_adsr_start(adsr_start), .diag_adsr_256(adsr_256),
        .diag_adsr_768(adsr_768), .diag_adsr_1024(adsr_1024),
        .diag_adsr_done(adsr_done), .diag_adsr_event_count(adsr_event_count),
        .display_transport(transport),.display_score_valid(score_valid),.display_octave(octave),.display_note_on(on_mask),.display_voice_gates(voice_gates),
        .display_sample_ce(sample_ce),.display_voice_levels(levels),.display_mode(mode),
        .display_preset(preset),.display_expression(expression),.display_step(step),
        .display_target(target),.display_wrong(wrong),.display_calibrated(calibrated),
        .display_mapping_ready(mapping_ready),.display_pairing_code(pairing_code),
        .display_voice_regions(voice_regions),.display_group(group_b)
    );

    (* keep = "true" *) wire [31:0] ch_seq;
    (* keep = "true" *) wire [15:0] ch_dry, ch_newer, ch_older, ch_wet;
    (* keep = "true" *) wire [7:0] ch_frac, ch_gain, ch_target;
    (* keep = "true" *) wire [16:0] ch_wet_mix, ch_sum;
    (* keep = "true" *) wire [15:0] ch_expected;
    (* keep = "true" *) wire [25:0] ch_lfo;
    (* keep = "true" *) wire [10:0] ch_delay, ch_wr, ch_rd;
    (* keep = "true" *) wire ch_ready, ch_clip, ch_valid;
    (* keep = "true" *) wire [1:0] ch_mode;
    (* keep = "true" *) wire [15:0] ch_clips;
    assign {ch_valid,ch_seq,ch_dry,ch_newer,ch_older,ch_wet,ch_frac,ch_wet_mix,
        ch_sum,ch_expected,ch_gain,ch_target,ch_lfo,ch_delay,ch_wr,ch_rd,
        ch_ready,ch_mode,ch_clip,ch_clips} = ch_packet[249:0];
    (* keep = "true" *) wire ch_trigger = ch_valid && ch_ready && ch_dry != 0 && ch_seq[7];

    // Core2 model0x52, complete tagged arithmetic for the selected lane.
    (* keep="true" *)wire[7:0] gao_model=additive_packet[255:248];
    (* keep="true" *)wire gao_lane=additive_packet[241];
    (* keep="true" *)wire[1:0]gao_voice=additive_packet[240:239];
    (* keep="true" *)wire[7:0]gao_generation=additive_packet[155:148];
    (* keep="true" *)wire[15:0]gao_sample=additive_packet[147:132];
    (* keep="true" *)wire[5:0]gao_index=additive_packet[13:8]+6'd1;
    (* keep="true" *)wire busy=additive_packet[3];
    (* keep="true" *)wire gao_accept=busy && additive_packet[2:0]==2;
    (* keep="true" *)wire gao_done=additive_packet[247];
    (* keep="true" *)wire gao_overrun=additive_packet[7];
    (* keep="true" *)wire[8:0]gao_alpha=additive_packet[214:206];
    (* keep="true" *)wire gao_from=additive_packet[244],gao_to=additive_packet[245];
    (* keep="true" *)wire[17:0]gao_phase18=additive_packet[173:156];
    (* keep="true" *)wire[7:0]gao_weight=additive_packet[197:190];
    (* keep="true" *)wire[7:0]gao_gain=additive_packet[205:198];
    (* keep="true" *)wire[23:0]gao_term=additive_packet[43:20];
    (* keep="true" *)wire[23:0]gao_sum_before=additive_packet[67:44];
    (* keep="true" *)wire[31:0]base_latch=additive_packet[131:100];
    (* keep="true" *)wire[15:0]gao_pcm=additive_packet[230:215];
    (* keep="true" *)wire gao_trigger32=busy && additive_packet[2:0]==0 &&
       additive_packet[13:8]==0 && base_latch==32'h004b17e5 && ch_test;
    generate if (FPGA_OLED_MASTER) begin : fpga_oled
        oled_zh_panel oled(.clk(audio_clk_12m288),.rst_n(core_reset),.mode,.preset,.step,
          .target_mask(target),.wrong_count(wrong),.calibrated,.pairing_code(pairing_code),.expression(expression),.hold(1'b0),
          .mapping_ready,
          .scl(OLED_SCL),.sda(OLED_SDA));
    end else begin : s3_oled
        assign OLED_SCL = 1'b1;
        assign OLED_SDA = 1'bz;
    end endgenerate
    wire clk_pix,clk_serial,video_lock;wire video_rst;
    display_pll video_pll(.clkin(sys_clk_50m),.lock(video_lock),.clkout0(clk_serial),.clkout1(clk_pix));
    reset_release_sync video_reset(.clk(clk_pix),.async_rst_n(video_lock && rst_n_raw),.rst_n(video_rst));
    wire [9:0] x,y;wire visible,hs,vs,frame_start;
    hdmi_video_timing timing(.clk_pix,.rst_n(video_rst),.x,.y,.visible,.hsync(hs),.vsync(vs),.frame_start);
    wire [1:0] display_gain;
    wire trace_pixel;wire [1023:0] spectrum;wire [63:0] vlevels;
    wire[2:0]vtransport;wire vscore_valid,voctave;
    wire [1:0] vmode,vpreset;wire [5:0] vstep;wire [3:0] vtarget;wire [15:0] vwrong;wire lv;wire[15:0] lu;
    display_capture capture(.clk_audio(audio_clk_12m288),.rst_audio_n(core_reset),.sample_ce,
      .pcm_x,.pcm_y,.voice_samples(levels),.note_on(on_mask),.voice_gates,
      .voice_regions,.group_b,
      .measure_enable(calibrated && !PA_EN),.serial_bck(HP_BCK),.serial_ws(HP_WS),.serial_din(HP_DIN),.transport,.score_valid,.octave,.mode,.preset,.step,.target,.wrong,
      .clk_pix,.rst_pix_n(video_rst),.frame_start,.pixel_x(x),.pixel_y(y),.trace_pixel,
      .video_transport(vtransport),.video_score_valid(vscore_valid),.video_octave(voctave),.video_spectrum(spectrum),.video_gain(display_gain),.video_levels(vlevels),.video_mode(vmode),
      .video_latency_valid(lat_probe_valid),.video_latency_us(lat_probe_us),.video_preset(vpreset),.video_step(vstep),.video_target(vtarget),.video_wrong(vwrong));
    wire [7:0] vr,vg,vb;
    reg[9:0]x_d,y_d;reg visible_d;
    always_ff@(posedge clk_pix or negedge video_rst)begin
      if(!video_rst)begin x_d<=0;y_d<=0;visible_d<=0;end
      else begin x_d<=x;y_d<=y;visible_d<=visible;end
    end
    display_dashboard dashboard(.clk_pix,.rst_n(video_rst),.x(x_d),.y(y_d),.visible(visible_d),.trace_pixel,.spectrum,.voice_regions,.group_b,
      .transport(vtransport),.score_valid(vscore_valid),.octave(voctave),.levels(vlevels),.mode(vmode),.preset(vpreset),.step(vstep),.target(vtarget),.wrong(vwrong),
      .latency_valid(lv),.latency_us(lu),.display_gain,.r(vr),.g(vg),.b(vb));
    // One synchronous bitmap read + two RGB stages; sync/DE delay is three.
    reg[2:0] hs_d,vs_d,de_d;
    always_ff @(posedge clk_pix or negedge video_rst) begin
      if(!video_rst) begin hs_d<=1;vs_d<=1;de_d<=0;end
      else begin hs_d<={hs_d[1:0],hs};vs_d<={vs_d[1:0],vs};de_d<={de_d[1:0],visible};end
    end
    dvi_tx_ddr dvi(.rst_pix_n(video_rst),.clk_serial,.clk_pix,
      .vs(vs_d[2]),.hs(hs_d[2]),.de(de_d[2]),.r(vr),.g(vg),.b(vb),
      .clock_p(tmds_clk_p_0),.clock_n(tmds_clk_n_0),.data_p(tmds_d_p_0),.data_n(tmds_d_n_0));
    assign hpd_en=1'b1; // same 60K cam_dvi TX-enable binding, K13
endmodule
