// Integrated instrument audio/control core, clocked at approximately 12.288 MHz.
// Eight ADC channels -> pressure/gesture events -> four independent voice contexts.
// Each voice has a base synth and its own up-to-32-partial additive layer.
// Mixed PCM -> chorus/delay or FDN space -> bounded output -> PT8211 serial DAC.
// Reset/PLL-unlock mutes the active-low amplifier enable and holds interfaces idle.
// Source/build/test identities and physical validation are recorded separately.
module instrument_extension_core #(
    parameter integer      CLK_HZ                 = 12_288_000,
    parameter integer      BLINK_MILLIHZ          = 2_000,
    parameter integer      CLOCKS_PER_BIT         = 107,
    // Frozen instrument parameters (identical defaults to rtl/instrument_board_core.sv)
    parameter integer      SCAN_INTERVAL          = 12_288,
    parameter integer      FRAME_TIMEOUT          = 4_096,
    parameter integer      ADC_CLK_DIV            = 8,
    parameter integer      ADC_SETTLE             = 64,
    parameter integer      ADC_CS_HIGH            = 16,
    parameter integer      FILTER_SHIFT           = 3,
    parameter logic [15:0] SLEW_STEP              = 16'd4096,
    parameter integer      STALE_FRAMES           = 5,
    parameter integer      CONFIRM_FRAMES         = 1,
    parameter integer      DEBOUNCE_CYCLES        = 61_440,
    parameter integer      KEY_LONG_CYCLES        = 9_216_000,
    parameter integer      KEY_CLEAR_CYCLES       = 36_864_000,
    parameter integer      KEY_COMBO_WINDOW       = 2_088_960,
    parameter integer      KEY_DOUBLE_CYCLES      = CLK_HZ / 5,
    parameter integer      KEY_MAX_PRESS_CYCLES   = CLK_HZ / 2,
    parameter integer      KEY_BOOT_CYCLES        = CLK_HZ / 10,
    parameter integer      GUIDE_STEP_SAMPLES     = 48_000,
    parameter integer      PA_ENABLE_DELAY        = 122_880,
    parameter integer      OUTPUT_FADE_SAMPLES    = 512,
    parameter logic        AUX_ENVELOPE_ENABLE    = 1'b1,
    parameter logic        EXPRESSIVE_ADSR        = 1'b0,
    parameter logic        ADSR_ERROR_FEEDBACK    = 1'b0,
    parameter logic MUSICAL_PRESETS = 1'b0,
    parameter logic        FOUR_PRESETS           = 1'b0,
    parameter logic [11:0] DEFAULT_ON_THRESHOLD   = 12'h200,
    parameter logic [11:0] DEFAULT_OFF_THRESHOLD  = 12'h100,
    parameter logic [11:0] DEFAULT_BEND_DEAD_ZONE = 12'd40,
    parameter logic [11:0] DEFAULT_BEND_SPAN      = 12'd1000,
    parameter logic        EXTERNAL_CENTER_MODE   = 1'b0,
    parameter logic [7:0]  THUMB_STABLE_FRAMES    = 8'd4,
    parameter logic [12:0] THUMB_STABLE_SPREAD    = 13'd32,
    parameter logic [12:0] THUMB_ACCEPT_WINDOW    = 13'd400,
    parameter logic [23:0] THUMB_FRESH_TIMEOUT    = 24'd98_304,
    // Extension parameters
    parameter integer      LAYER_GAIN_STEP        = 4,       // layer gain units per sample
    parameter integer      LAYER_MASK_FADE_STEP   = 4,       // 64 samples ~= 1.33 ms at 48 kHz
    parameter logic        LAYER_SINE_INTERPOLATION = 1'b0,
    parameter logic [3:0]  LAYER_LEVEL_SHIFT      = 4'd4,    // additive bank output scaling
    parameter integer      CHORUS_DEPTH           = 2048,    // delay line in samples (~43 ms)
    parameter integer      CHORUS_MIX_SHIFT       = 3,       // wet gain 1/8
    parameter logic        CHORUS_FRACTIONAL      = 1'b0,
    parameter logic [1:0]  CHORUS_MODE            = 2'd2,    // 2 = chorus, 0 = bypass (dry)
    parameter integer      VIZ_DECIM              = 32,      // capture one point every 32 samples
    parameter integer      VIZ_POINTS             = 32,      // points per telemetry frame
    // Retained parameter names for older testbench elaboration. Holds no longer start test mode.
    parameter integer      TEST_MODE_HOLD_CYCLES  = (CLK_HZ * 6) / 5,
    // 55 Hz exactly: round(55 * 2^32 / 48000) = 4921317 = 0x004B17E5. (An earlier constant,
    // 0x004B1A25 = 4921893, is 55.0064 Hz - 0.2 cent sharp, and its comment claimed the rounded
    // value, so the two disagreed. Keep the literal and the comment in step.)
    parameter logic [31:0] TEST_MODE_PHASE_INC    = 32'h004B_17E5,
    parameter integer      TEST_MODE_COMBO_WINDOW = (CLK_HZ * 17) / 100
) (
    input  logic        clk_audio_12m288,
    input  logic        pll_lock,
    input  logic        rst_n_raw,
    input  logic [1:0]  key_n_raw, // [0]=joystick 1 Z, [1]=joystick 2 Z in config D
    output logic        SENSOR_SCK,
    output logic        SENSOR_MOSI,
    output logic        SENSOR_CS_N,
    input  logic        SENSOR_MISO,
    output logic        HP_BCK,
    output logic        HP_WS,
    output logic        HP_DIN,
    output logic        PA_EN,
    output logic [3:0]  LED,
    output logic        UART_TX,
    input  logic        ESP_UART_RX,
    output logic        ESP_UART_TX,
    // Observability for simulation, the netlist report and the telemetry stream. These are core
    // outputs, not pins: config D has no logic analyser attached.
    output logic signed [15:0] diag_pcm_voice,     // the frozen instrument's own mix
    output logic signed [15:0] diag_pcm_layer,     // the additive layer
    output logic signed [15:0] diag_pcm_out,       // what the DAC receives
    output logic        diag_mix_clipped,
    // T3: the qualified digital latency probe output from display_capture, for the
    // 0x86 statistics frame. Defaults keep legacy callers compiling unchanged.
    input  logic        lat_valid_in = 1'b0,
    input  logic [15:0] lat_us_in = 16'd0,
    output logic        diag_layer_valid,
    output logic [1:0]  diag_layer_owner,
    output logic [31:0] diag_layer_mask,
    output logic [7:0]  diag_layer_gain,
    output logic        diag_layer_switching,
    output logic [5:0]  diag_layer_partials,
    output logic [15:0] diag_vibrato_ratio,
    output logic [11:0] diag_vibrato_depth,
    output logic        diag_vibrato_center_valid,
    output logic        diag_vibrato_stale,
    output logic        diag_fx_ready,
    output logic [15:0] diag_fx_peak,
    output logic [15:0] diag_fx_clip,
    output logic [15:0] diag_viz_frames,
    output logic [15:0] diag_viz_rejected,
    output logic [15:0] diag_zone_valid,
    output logic [15:0] diag_scan_timeouts,
    output logic [15:0] diag_records_sent,
    output logic [15:0] diag_uart_rejected,
    output logic        diag_test_mode,        // the deterministic 32-partial test tone is active
    output logic        diag_core_rst_n,
    output logic        diag_pll_locked,
    output logic signed [15:0] diag_chorus_actual,
    output logic [255:0] diag_chorus_snapshot,
    output logic [37:0]  diag_chorus_control,
    output logic [255:0] diag_additive_snapshot,
    output logic [31:0]  diag_additive_mask,
    output logic [15:0]  diag_adsr_attack_count,
    output logic [15:0]  diag_adsr_decay_count,
    output logic [15:0]  diag_adsr_release_count,
    output logic [2:0]   diag_adsr_stage_valid,
    output logic [2:0]   diag_adsr_stage_overflow,
    output logic        diag_adsr_stage_done,
    output logic [1:0]  diag_adsr_captured_preset,
    output logic        diag_adsr_sample_ce,
    output logic        diag_adsr_gate,
    output logic [15:0] diag_adsr_level,
    output logic [1:0]  diag_adsr_preset
    ,output logic [15:0] diag_adsr_start
    ,output logic [15:0] diag_adsr_256
    ,output logic [15:0] diag_adsr_768
    ,output logic [15:0] diag_adsr_1024
    ,output logic        diag_adsr_done
    ,output logic [7:0]  diag_adsr_event_count,
    output logic display_sample_ce,
    output logic [63:0] display_voice_levels,
    output logic [2:0] display_transport,output logic display_score_valid,display_octave,
    output logic [1:0] display_mode, display_preset, display_expression,
    output logic [5:0] display_step,
    output logic [3:0] display_target,
    output logic [15:0] display_wrong,
    output logic display_calibrated,
    output logic display_mapping_ready,
    output logic [19:0] display_pairing_code,
    output logic [3:0] display_note_on,display_voice_gates,
    output logic [7:0] display_voice_regions,output logic display_group
);
    localparam integer BLINK_TOGGLE_CYCLES = (CLK_HZ / (2 * BLINK_MILLIHZ)) * 1000;

    logic core_rst_n;

    reset_release_sync reset_sync (
        .clk(clk_audio_12m288), .async_rst_n(rst_n_raw & pll_lock), .rst_n(core_rst_n)
    );

    // ---- indicators (same policy as the frozen shell) ------------------------------
    logic [31:0] blink_count;
    logic        blink_phase;
    always_ff @(posedge clk_audio_12m288 or negedge core_rst_n) begin
        if (!core_rst_n) begin
            blink_count <= 32'd0;
            blink_phase <= 1'b0;
        end else if (blink_count >= BLINK_TOGGLE_CYCLES - 1) begin
            blink_count <= 32'd0;
            blink_phase <= ~blink_phase;
        end else begin
            blink_count <= blink_count + 32'd1;
        end
    end

    // ---- the frozen instrument -----------------------------------------------------
    logic [3:0]   led_zones;
    logic         led_fault;
    logic [79:0]  zone_pressure_all;
    logic [4:0]   zone_valid_all, zone_stale_all, zone_calibrated_all;
    logic [3:0]   voice_gates;
    logic [127:0] voice_phase_incs;
    logic [63:0]  voice_expression;
    logic [63:0]  voice_envelopes;
    logic [11:0]  voice_envelope_states;
    logic         voice_sample_ce;
    logic [7:0]   voice_presets;
    logic [1:0] current_preset;
    logic [3:0]   accepted_events, accepted_note_on, stolen_voices;
    logic         fault_latched, instrument_cal_busy, instrument_cal_done;
    logic[7:0]audition_song;logic[6:0]audition_length;
    logic audition_active,audition_event_valid,audition_event_on;logic[5:0]audition_step;
    // T2 event telemetry link between the instrument's recorder and esp_score_link.
    logic rec_ready,rec_take;logic[5:0]rec_length;logic[63:0]rec_body;
    logic[7:0]rec_dropped,rec_seq;
    logic[1:0]audition_region,audition_preset;logic[6:0]audition_note;logic[7:0]audition_generation;
    logic[31:0]audition_inc;logic[63:0]audition_pressure;
    logic audition_previous;
    always_ff@(posedge clk_audio_12m288 or negedge core_rst_n)begin
      if(!core_rst_n)audition_previous<=0;else audition_previous<=audition_active;
    end
    wire audition_transition=audition_active^audition_previous;
    logic signed [15:0] pcm_voice;
    logic         voice_clipped;
    logic [5:0]   panel_cmd;
    logic [15:0]  bend_ratio;
    logic[11:0]mobile_axis[0:3];logic[11:0]mobile_bend_center,mobile_vib_center,mobile_aux_x;
    logic mobile_bend_valid;
    wire mobile_bend_stale=zone_stale_all[4];
    wire signed[15:0] mobile_dx;
    wire signed[15:0] mobile_dy;
    wire signed[15:0] mobile_j2x;
    wire signed[15:0] mobile_j2y;
    wire [3:0] mobile_voices;
    wire [7:0] mobile_health;
    wire [247:0] mobile_state;
    logic signed[15:0]dac_pcm,dac_left,dac_right;
    logic [2:0]   diag_channel_id;
    logic [11:0]  diag_code;
    logic         diag_code_valid;
    logic [7:0]   diag_frame_id;
    logic [15:0]  frame_clocks;
    logic [15:0]  scan_timeouts;
    logic         sensor_sck, sensor_mosi, sensor_cs_n;
    logic [15:0]  vibrato_ratio;
    logic [11:0]  vibrato_depth;
    logic         vibrato_center_valid, vibrato_stale;
    logic [5:0]   aux_partial_target;
    // Configuration consumers (see rtl/config_session.sv). The committed partial
    // count is an upper BOUND that clamps the joystick gesture; the joystick still
    // modulates below it, and audio/expression/ADSR are untouched by a config write.
    logic [5:0]   esp_partial_limit;
    logic [5:0]   partial_effective;
    logic [47:0]  esp_on_thresholds;
    logic              esp_on_threshold_valid;
    logic [6:0]   esp_atten;
    logic [6:0]   esp_atten_gain;
    logic         esp_atten_valid;
    // S02 next-note configuration consumers (see zone_note_map / instrument_top).
    logic [21:0]  esp_commit_mask;
    logic [27:0]  esp_notes;
    logic [3:0]   esp_note_valid;
    logic esp_group_b, esp_octave_up;
    logic [1:0] esp_preset_1;
    logic         esp_apply_strobe;
    logic [7:0]   aux_wet_gain_q8;
    logic [7:0]   wet_gain_active_q8;
    logic [1:0]   fx_mode;            // runtime effect select via 0x19 (S08)
    // Committed effect family (config field 19): 0 = legacy chorus/delay, 1 = space FDN.
    // Defaults to space when no commit has selected a family.
    logic        cfg_effect_family, cfg_effect_family_valid;
    wire         effect_family_pre = cfg_effect_family_valid ? cfg_effect_family : 1'b1;
    logic [63:0]  voice_levels;       // post-gain per-voice samples (S10)
    logic [6:0]   esp_wet_max;        // committed chorus_wet_max ceiling (field 17)
    logic [1:0]   aux_center_valid, aux_axis_stale;
    logic [11:0]  chorus_center_y, chorus_filtered_y;
    logic [11:0]  scope_adc6, scope_adc7;
    logic sample_ce, test_mode;
    logic [5:0] performance_cmd;
    logic guide_toggle, test_start, practice_toggle;
    logic practice_run,practice_reset,practice_done,practice_request,practice_interrupted;
    logic[2:0]practice_transport,practice_action;
    logic[1:0]practice_req_mode;
    logic[15:0]practice_session,practice_last_request,practice_request_id;
    logic[7:0]practice_result;
    logic practice_was_running;
    always_ff@(posedge clk_audio_12m288 or negedge core_rst_n)
      if(!core_rst_n)practice_was_running<=0;else practice_was_running<=practice_run;
    wire practice_release=practice_reset || (practice_was_running && !practice_run);
    logic [1:0] z_pressed, note_layout;
    logic guide_active, panic_mute;
    logic [3:0] guide_led, guide_target, previous_zones;
    logic [1:0] guide_mode;          // 0 free, 1 guided practice, 2 challenge
    logic       guide_expression_ok; // live joystick satisfies the hinted gesture
    logic [3:0] guide_block_mask;    // zones whose NEW notes are muted in guide
    logic [5:0] guide_step;
    logic [1:0] guide_expression;
    logic [15:0] guide_hits, guide_wrong, guide_miss;
    logic score_loaded, remote_guide_pulse,score_mapping_ready;
    logic [1:0] remote_guide_mode;
    logic [7:0] score_song_id;
    logic [6:0] score_length;
    logic [3:0] score_target_mask;
    logic score_rest;
    logic [7:0] score_segment_index, score_segment_count;
    logic [1:0] score_target_zone, score_expression;
    logic guide_expression_dev;
    logic [15:0] guide_early, guide_late;
    logic [23:0] score_duration_samples;
    logic [15:0] esp_crc_errors, esp_framing_errors;
    logic cal_refused_now, cal_refused_latched;
    always_ff @(posedge clk_audio_12m288 or negedge core_rst_n) begin
        if(!core_rst_n) cal_refused_latched<=0;
        else if(cal_refused_now) cal_refused_latched<=1;
        else if(&zone_calibrated_all) cal_refused_latched<=0;
    end

    // ---- T3 four-frequency mode (Z1+Z2 across reset) ---------------------------------
    // Enters after the boot double-key release, ONLY when nothing else owns the
    // engine. J2X is sampled at the ENTRY edge alone: deflected -> the additive
    // layer joins the four real voices (32 partials), centre -> plain four base
    // voices with the layer silent, which keeps the spectral peaks unambiguous.
    logic test4_start, test4_mode, test4_additive, test4_j2x_fresh;
    logic [11:0] test4_j2x_code;
    always_ff @(posedge clk_audio_12m288 or negedge core_rst_n) begin
        if (!core_rst_n) begin
            test4_j2x_code <= 12'h800; test4_j2x_fresh <= 1'b0;
        end else begin
            if (diag_code_valid && (diag_channel_id == 3'd6)) begin
                test4_j2x_code <= diag_code; test4_j2x_fresh <= 1'b1;
            end
        end
    end
    always_ff @(posedge clk_audio_12m288 or negedge core_rst_n) begin
        if (!core_rst_n) begin
            test4_mode <= 1'b0; test4_additive <= 1'b0;
        end else begin
            if (performance_cmd[1] || fault_latched) begin
                test4_mode <= 1'b0;                       // double-Z panic exits
            end else if (test4_start && !test_mode && !audition_active && !instrument_cal_busy) begin
                test4_mode <= 1'b1;
                // J2X sampled exactly once, at entry
                test4_additive <= test4_j2x_fresh &&
                                  (test4_j2x_code > 12'h880 || test4_j2x_code < 12'h780);
            end
        end
    end
    wire test4_stop_pulse = test4_mode && (performance_cmd[1] || fault_latched);

    performance_gesture #(.DEBOUNCE_CYCLES(DEBOUNCE_CYCLES),
        .DOUBLE_CYCLES(KEY_DOUBLE_CYCLES), .MAX_PRESS_CYCLES(KEY_MAX_PRESS_CYCLES),
        .BOOT_CYCLES(KEY_BOOT_CYCLES)) performance_panel (
        .clk(clk_audio_12m288), .rst_n(core_rst_n), .key_n(key_n_raw),
        .command(performance_cmd), .guide_toggle(guide_toggle),.practice_toggle(practice_toggle),
        .test_start(test_start), .test4_start(test4_start), .pressed(z_pressed));

    always_ff @(posedge clk_audio_12m288 or negedge core_rst_n) begin
      if(!core_rst_n)begin previous_zones<=0;panic_mute<=0;end
      else begin previous_zones<=led_zones;
        if(performance_cmd[1])panic_mute<=1;
        else if(|accepted_note_on && z_pressed==0)panic_mute<=0;
      end
    end
    practice_controller practice(
      .clk(clk_audio_12m288),.rst_n(core_rst_n),.sample_ce,.interrupted(practice_interrupted),.score_valid(score_loaded && score_mapping_ready && score_length!=0),
      .safe(!test_mode && !led_fault && (&zone_calibrated_all)),.demo_active(audition_active),.held(led_zones),
      .cycle_mode(guide_toggle),.toggle_run(practice_toggle),.stop(performance_cmd[1]),.phrase_done(practice_done),
      .legacy_start(remote_guide_pulse),.legacy_mode(remote_guide_mode),
      .request(practice_request),.request_mode(practice_req_mode),.action(practice_action),.request_id(practice_request_id),
      .mode(guide_mode),.transport(practice_transport),.run(practice_run),.reset_engine(practice_reset),
      .session(practice_session),.last_request(practice_last_request),.result(practice_result));
    assign guide_active=practice_run;
    led_score_guide #(.ALLOW_BUILTIN(1'b0),.STEP_SAMPLES(GUIDE_STEP_SAMPLES), .EXPRESSION_HINTS(1'b1)) score (
        .clk(clk_audio_12m288), .rst_n(core_rst_n), .sample_ce(sample_ce),
        .mode(guide_mode),.enable(practice_run),.reset_session(practice_reset), .hit_pulse(led_zones & ~previous_zones), .held_mask(led_zones),
        .external_score_enable(score_loaded), .external_score_length(score_length),
        .external_target_mask(score_target_mask),
        .external_expression_hint(score_expression),
        .external_expression_ok(guide_expression_ok),
        .external_step_samples(score_duration_samples),
        .led(guide_led), .target_led(guide_target), .step_index(guide_step),
        .expression_hint(guide_expression), .expression_dev(guide_expression_dev),
        .hit_event(), .wrong_event(),
        .miss_event(), .phrase_done(practice_done), .hit_count(guide_hits),
        .wrong_count(guide_wrong), .miss_count(guide_miss),
        .early_count(guide_early), .late_count(guide_late));
    // Expression gate: hint 1 asks for bend on J1-X, hint 2 for vibrato on J1-Y.
    // Both are LIVE conditions - the deviation never
    // mutes or locks anything, it only withholds the step advance.
    assign guide_expression_ok = (guide_expression == 2'd1) ? (bend_ratio != 16'h8000) :
                                 (guide_expression == 2'd2) ? (vibrato_depth > 12'd32) :
                                 1'b1;

    // Four-voice engine outputs. Declared ahead of the link so the 0x84 status frame
    // can carry them; the engine itself sits below with the audio path.
    logic [63:0]  eng_lane_pcm;
    logic[31:0] voice_notes;
    logic[7:0] voice_regions;
    logic [23:0]  eng_voice_partials;
    logic [31:0]  eng_voice_gains, eng_voice_generation;
    logic [3:0]   eng_note_active;
    logic [15:0]  eng_grant_count;
    logic         eng_budget_violation;
    logic [255:0] eng_diag_lane0, eng_diag_lane1;

    // T3 0x86 statistics frame producer
    wire [1:0]  test_kind_now = test_mode ? 2'b01 : (test4_mode ? 2'b10 : 2'b00);
    wire        stats_ready_w; wire [5:0] stats_length_w; wire [111:0] stats_body_w; wire stats_take_w;
    test_stats_frame stats_frame (
        .clk(clk_audio_12m288), .rst_n(core_rst_n), .sample_ce(sample_ce),
        .test_kind(test_kind_now),
        .voice_gates(voice_gates), .voice_envelopes(voice_envelopes),
        .voice_partials(eng_voice_partials), .voice_gains(eng_voice_gains),
        .lat_valid(lat_valid_in), .lat_us(lat_us_in), .lat_invalid(16'd0),
        .ready(stats_ready_w), .length(stats_length_w), .body(stats_body_w), .take(stats_take_w),
        .seq()
    );

    esp_score_link #(.AUDITION_TAIL_MAX_SAMPLES(MUSICAL_PRESETS ? 192000 : 48000),
        .AUDITION_TAIL_QUIET_SAMPLES(MUSICAL_PRESETS ? 2048 : 16),
        .ENABLE_AUDITION(1'b1),.ENABLE_MOBILE(1'b1),.CLOCKS_PER_BIT(CLOCKS_PER_BIT), .EXTENDED_STATUS(1'b1),
                     .CFG_DEFAULT_ON_THRESHOLD(DEFAULT_ON_THRESHOLD)) esp_link (
        .clk(clk_audio_12m288), .rst_n(core_rst_n),
        .audition_tail_quiet(mobile_voices==0 && dac_left<16'sd16 && dac_left> -16'sd16 && dac_right<16'sd16 && dac_right> -16'sd16),.audition_sample_ce(sample_ce),.audition_abort(performance_cmd[1] || fault_latched || instrument_cal_busy),
        .audition_blocked((|led_zones) && !audition_active),.audition_song,.audition_length,.audition_active,.audition_step,.audition_event_valid,.audition_event_on,
        .audition_region,.audition_preset,.audition_note,.audition_generation,.audition_inc,.audition_pressure,
        .uart_rx_i(ESP_UART_RX), .uart_tx_o(ESP_UART_TX),
        .event_ready(rec_ready), .event_length(rec_length), .event_body(rec_body),
        .event_take(rec_take),
        .stats_ready(stats_ready_w), .stats_length(stats_length_w), .stats_body(stats_body_w),
        .stats_take(stats_take_w),
        .mobile_pcm(dac_pcm),.mobile_state,.practice_request,.practice_request_mode(practice_req_mode),.practice_action,.practice_request_id,.practice_result,
        .current_step(guide_step), .guide_active(guide_active), .panel_mode(guide_mode),.panel_target(guide_target),.panel_expression(guide_expression),.panel_preset(current_preset),.panel_pairing_code(display_pairing_code),
        // external_panel_cmd = {group,preset,octave,calibrate,panic,clear}.
        // Only physical mapping changes invalidate an already-published score.
        .mapping_changed(performance_cmd[5]|performance_cmd[3]),.score_mapping_ready,
        .test_mode(test_mode), .panic_mute(panic_mute),
        .calibrated(&zone_calibrated_all),
        .hit_count(guide_hits), .wrong_count(guide_wrong), .miss_count(guide_miss),
        .note_layout(note_layout), .partial_target(partial_effective),
        .wet_target(aux_wet_gain_q8), .score_loaded(score_loaded),
        .song_id(score_song_id), .score_length(score_length),
        .score_target_zone(score_target_zone), .score_target_mask(score_target_mask),
        .score_rest(score_rest),
        .score_segment_index(score_segment_index), .score_segment_count(score_segment_count),
        .score_expression(score_expression),
        .score_duration_samples(score_duration_samples),
        .remote_guide_pulse(remote_guide_pulse),
        .remote_guide_mode(remote_guide_mode),
        .crc_error_count(esp_crc_errors), .framing_error_count(esp_framing_errors),
        .cfg_on_thresholds(esp_on_thresholds),
        .cfg_partial_target(esp_partial_limit),
        .cfg_attenuation(esp_atten), .cfg_atten_valid(esp_atten_valid),
        .cfg_lease_held(), .cfg_epoch(), .cfg_reply_seen(),
        .cfg_wet_max(esp_wet_max),
        .cfg_commit_mask(esp_commit_mask), .cfg_notes(esp_notes),
        .cfg_note_valid(esp_note_valid), .cfg_group_b(esp_group_b),
        .cfg_preset_1(esp_preset_1), .cfg_octave_up(esp_octave_up),
        .cfg_apply_strobe(esp_apply_strobe),
        .fx_mode_out(fx_mode),
        .cfg_effect_family(cfg_effect_family),
        .cfg_effect_family_valid(cfg_effect_family_valid),
        .eng_lane_pcm(eng_lane_pcm), .eng_voice_partials(eng_voice_partials),
        .eng_voice_gains(eng_voice_gains), .eng_voice_generation(eng_voice_generation),
        .eng_voice_gates(voice_gates), .eng_note_active(eng_note_active),
        .eng_voice_presets(voice_presets), .eng_phase_incs(voice_phase_incs),
        .eng_grant_count(eng_grant_count), .eng_effect_family(effect_family_pre),
        .eng_voice_notes(voice_notes),.eng_voice_regions(voice_regions),.eng_voice_envelopes(voice_envelopes),
        .eng_budget_violation(eng_budget_violation));

    // A configuration commit is the ceiling, not a second modulation source: the
    // gesture may ask for fewer components, never more than the committed limit.
    assign partial_effective = (esp_partial_limit < aux_partial_target)
                               ? esp_partial_limit : aux_partial_target;
    // Field 18 arrives as `user_attenuation` (0 = unity, 64 = silence) but
    // pcm_output_stage takes a Q6 GAIN (64 = unity, 0 = silence). Convert once, here,
    // exactly as candidates/productized_instrument/rtl/config_apply.sv does. Skipping the
    // complement made the factory value 0 silence the whole instrument: every
    // register-level check stayed green and only the final serial audio went to zero.
    assign esp_atten_gain = (esp_atten >= 7'd64) ? 7'd0 : (7'd64 - esp_atten);
    // The committed thresholds always drive the playing zones, so the compile-time
    // constant is only the value the engine starts from (and it is the same value).
    assign esp_on_threshold_valid = 1'b1;

    always_ff @(posedge clk_audio_12m288 or negedge core_rst_n) begin
        if (!core_rst_n) begin
            scope_adc6 <= 12'd0;
            scope_adc7 <= 12'd0;
        end else if (diag_code_valid) begin
            if (diag_channel_id == 3'd6) scope_adc6 <= diag_code;
            if (diag_channel_id == 3'd7) scope_adc7 <= diag_code;
        end
    end

    instrument_top #(
        .SCAN_INTERVAL(SCAN_INTERVAL), .FRAME_TIMEOUT(FRAME_TIMEOUT),
        .ADC_CHANNELS(8), .ENABLE_EXTERNAL_VIBRATO(1'b1),
        .ENABLE_EXTERNAL_PRESET(1'b1),
        .ENABLE_EXTERNAL_PANEL(1'b1),
        .ENABLE_FAULT_GUARD(1'b1),
        .EXPRESSIVE_ADSR(EXPRESSIVE_ADSR), .FOUR_PRESETS(FOUR_PRESETS),.MUSICAL_PRESETS(MUSICAL_PRESETS),
        .ADSR_ERROR_FEEDBACK(ADSR_ERROR_FEEDBACK),
        .ADC_CLK_DIV(ADC_CLK_DIV), .ADC_SETTLE(ADC_SETTLE), .ADC_CS_HIGH(ADC_CS_HIGH),
        .FILTER_SHIFT(FILTER_SHIFT), .SLEW_STEP(SLEW_STEP),
        .STALE_FRAMES(STALE_FRAMES), .CONFIRM_FRAMES(CONFIRM_FRAMES),
        .DEBOUNCE_CYCLES(DEBOUNCE_CYCLES), .KEY_LONG_CYCLES(KEY_LONG_CYCLES),
        .KEY_CLEAR_CYCLES(KEY_CLEAR_CYCLES), .KEY_COMBO_WINDOW(KEY_COMBO_WINDOW),
        .PA_ENABLE_DELAY(PA_ENABLE_DELAY),
        .DEFAULT_ON_THRESHOLD(DEFAULT_ON_THRESHOLD),
        .DEFAULT_OFF_THRESHOLD(DEFAULT_OFF_THRESHOLD),
        .DEFAULT_BEND_DEAD_ZONE(DEFAULT_BEND_DEAD_ZONE),
        .DEFAULT_BEND_SPAN(DEFAULT_BEND_SPAN),
        .EXTERNAL_CENTER_MODE(EXTERNAL_CENTER_MODE),
        .THUMB_STABLE_FRAMES(THUMB_STABLE_FRAMES),
        .THUMB_STABLE_SPREAD(THUMB_STABLE_SPREAD),
        .THUMB_ACCEPT_WINDOW(THUMB_ACCEPT_WINDOW),
        .THUMB_FRESH_TIMEOUT(THUMB_FRESH_TIMEOUT)
    ) instrument (
        .clk_audio_mclk(clk_audio_12m288),
        .rst_n(core_rst_n),
        .enable(core_rst_n),
        .SENSOR_SCK(sensor_sck), .SENSOR_MOSI(sensor_mosi),
        .SENSOR_CS_N(sensor_cs_n), .SENSOR_MISO(SENSOR_MISO),
        .key_n(key_n_raw),
        .external_panel_cmd(performance_cmd | (practice_release?6'b000010:6'b0)), .diag_note_layout(note_layout),
        .thumb_center_code(12'h800),
        .external_vibrato_ratio_q15(vibrato_ratio),
        .external_preset_valid(1'b0), .external_preset(1'b0),
        .bend_dead_zone(DEFAULT_BEND_DEAD_ZONE), .bend_span(DEFAULT_BEND_SPAN),
        .cal_request(1'b0), .cal_mask(5'b11111), .clear_calibration(1'b0),
        .cal_busy(instrument_cal_busy), .cal_done(instrument_cal_done),
        .cal_refused(cal_refused_now),
        // The frozen top's own transmitter is deliberately not used in config D: the effect sits
        // between the mix and the converter (see the header).
        .HP_BCK(), .HP_WS(), .HP_DIN(), .PA_EN(),
        .LED(led_zones), .LED_FAULT(led_fault),
        .diag_channel_id(diag_channel_id), .diag_code(diag_code), .diag_code_valid(diag_code_valid),
        .diag_frame_id(diag_frame_id), .diag_channel_seen(), .diag_frame_done(),
        .diag_frame_incomplete(),
        .diag_frame_clocks(frame_clocks), .diag_frame_skew(),
        .diag_refused_requests(), .diag_timeouts(scan_timeouts),
        .diag_zone_pressure(), .diag_zone_pressure_all(zone_pressure_all),
        .diag_zone_valid(zone_valid_all),
        .diag_zone_age(), .diag_zone_stale(zone_stale_all),
        .diag_zone_calibrated(zone_calibrated_all),
        .diag_voice_gates(voice_gates), .diag_voice_presets(voice_presets),
        .diag_voice_notes(voice_notes),.diag_voice_regions(voice_regions),
        .diag_voice_expression(voice_expression),
        .diag_voice_envelopes(voice_envelopes),
        .diag_voice_envelope_states(voice_envelope_states),
        .diag_synth_sample_ce(voice_sample_ce),
        .diag_voice_gain(), .diag_voice_phase_incs(voice_phase_incs),
        .diag_bend_ratio(bend_ratio), .diag_bend_center(mobile_bend_center), .diag_bend_center_valid(mobile_bend_valid),
        .diag_bend_bypass(), .diag_bend_candidate(), .diag_bend_stable_frames(),
        .diag_panel_cmd(panel_cmd),
        .diag_current_preset(current_preset),
        .diag_event_accepted(accepted_events), .diag_event_accepted_on(accepted_note_on),
        .diag_stolen(stolen_voices), .diag_fault_latched(fault_latched),
        .pcm_sample(pcm_voice), .clipped(voice_clipped),
        .diag_voice_levels(voice_levels),
        .on_threshold_override(esp_on_thresholds), .on_threshold_valid(esp_on_threshold_valid),
        .cfg_commit_mask(esp_commit_mask), .cfg_notes(esp_notes),
        .cfg_note_valid(esp_note_valid), .cfg_group_b(esp_group_b),
        .cfg_preset_1(esp_preset_1), .cfg_octave_up(esp_octave_up),
        .cfg_load(esp_apply_strobe),
        .guide_block_mask(guide_block_mask),
        .audition_active,.audition_event_valid,.audition_event_on,.audition_region,.audition_preset,.audition_note,.audition_generation,.audition_inc,.audition_pressure,
        .rec_ready(rec_ready),.rec_length(rec_length),.rec_body(rec_body),
        .rec_take(rec_take),.rec_dropped(rec_dropped),.rec_seq(rec_seq),
        .test4_start(test4_start),.test4_stop(test4_stop_pulse)
    );
    // Guided practice mutes the NEW notes of non-target zones (wrong FSR) while
    // the chord is being gathered; note-offs always pass. A rest step (mask 0)
    // mutes nothing extra because the player is not asked to press anything -
    // any press then reads as wrong and is recorded, not played.
    always_comb begin
        if (guide_mode == 2'd1 && practice_run && score_loaded && score_mapping_ready && score_length!=0 && !practice_done)
            guide_block_mask = ~guide_target;
        else
            guide_block_mask = 4'b0000;   // free and challenge: every zone sounds
    end

    // ---- sample enable for the extension blocks ------------------------------------
    // The frozen instrument has its own internal 48 kHz tick. The extension blocks run on their
    // OWN tick from the same module, so the layer and the effect are in the same clock domain and
    // in step with each other; the worst case offset against the instrument's tick is one sample
    // period (20.8 us at 48 kHz), which is documented in docs/testing.md.
    audio_sample_tick_div256 sample_tick (
        .clk(clk_audio_12m288), .rst_n(core_rst_n), .sample_ce(sample_ce)
    );

    // CH5 is the second, independent joystick axis.  Its own initial centre,
    // dead band, stale timeout and slew are inside this pure-HDL controller.
    // CH0..3 still set force/brightness; CH4 still sets manual pitch bend.
    // The ratio affects every frozen voice through instrument_top, and the
    // additive layer follows those same resulting voice phase increments.
    vibrato_control vibrato (
        .clk(clk_audio_12m288), .rst_n(core_rst_n), .sample_ce(sample_ce),
        .axis_code(diag_code),
        .axis_valid(diag_code_valid && (diag_channel_id == 3'd5)),
        .ratio_q15(vibrato_ratio), .center_valid(vibrato_center_valid),
        .center_code(mobile_vib_center), .depth_q8(vibrato_depth),
        .axis_stale(vibrato_stale), .lfo_phase()
    );

    // CH6 chooses harmonic count independently of pressure; CH7 sets chorus wet gain.
    // Z2 alone switches the stored next-note preset.
    aux_joystick_controls #(
        .DEFAULT_WET_GAIN_Q8((CHORUS_MIX_SHIFT == 0) ? 8'd0 : (256 >> CHORUS_MIX_SHIFT))
    ) aux_joystick (
        .clk(clk_audio_12m288), .rst_n(core_rst_n), .sample_ce(sample_ce),
        .channel_id(diag_channel_id), .code(diag_code), .code_valid(diag_code_valid),
        .partial_target(aux_partial_target),
        .wet_gain_target_q8(aux_wet_gain_q8),
        .center_valid(aux_center_valid), .axis_stale(aux_axis_stale),
        .diag_center_x(mobile_aux_x),.diag_center_y(chorus_center_y), .diag_filtered_y(chorus_filtered_y)
    );

    // ---- competition test mode --------------------------------------------------------
    // A deterministic stimulus for the judge: one low note (55 Hz) rebuilt from ALL 32 partials,
    // so the telemetry and the PC view can show "32/32 partials" live without electrodes. It is
    // entered only by holding Z1 across reset and releasing it. Both Z stops it.
    // The four-voice engine carries it on voice 0's own context: the test mux drives that
    // context's live inputs and one accepted-on pulse starts it, exactly like a real note.
    logic eng_test_grant;
    always_ff @(posedge clk_audio_12m288 or negedge core_rst_n) begin
        if (!core_rst_n)                       eng_test_grant <= 1'b0;
        else if (test_start && !test_mode)     eng_test_grant <= 1'b1; // pulse on entry
        else                                   eng_test_grant <= 1'b0;
    end
    always_ff @(posedge clk_audio_12m288 or negedge core_rst_n) begin
        if (!core_rst_n)                       test_mode <= 1'b0;
        else if (performance_cmd[1])           test_mode <= 1'b0;
        else if (test_start)                   test_mode <= 1'b1;
    end
    // Same safe-state gating the single-owner layer used: no additive sound during
    // demo takeover, faults, calibration, panic, or before calibration completes.
    wire layer_rst_n = core_rst_n && !audition_transition && !fault_latched && !instrument_cal_busy &&
                       !performance_cmd[1] &&
                       (test_mode || (test4_mode && test4_additive) || (&zone_calibrated_all));
    wire binder_force_free = performance_cmd[1] | performance_cmd[0] |
                             fault_latched | instrument_cal_busy;

    wire [3:0]   eng_gates = test_mode ? 4'b0001 : voice_gates;
    wire [63:0]  eng_envelopes = test_mode ? 64'hffff_ffff_ffff_ffff : voice_envelopes;
    wire [63:0]  eng_expression = test_mode ? {48'd0, 16'hFFFF} : voice_expression;
    wire [127:0] eng_phase_incs = test_mode ? {96'd0, TEST_MODE_PHASE_INC} : voice_phase_incs;
    wire [3:0]   eng_accepted_on = test_mode ? ((eng_test_grant) ? 4'b0001 : 4'b0000)
                                             : accepted_note_on;
    wire [5:0]   eng_partial_target = test_mode            ? 6'd32 :
                                      (test4_mode && test4_additive) ? 6'd32 :
                                      (test4_mode && !test4_additive) ? 6'd0 :
                                      partial_effective;
    wire         eng_force_free = binder_force_free;

    // ---- the four-voice additive engine ----------------------------------------------
    // Every sounding voice keeps its own 32-partial context; see rtl/poly_additive_engine.sv.
    // This replaces the single-owner pair (layer_owner_bind + zone_additive_layer): a second
    // held note is no longer refused the layer and a release tail is never muted by an
    // ownership handover.

    poly_additive_engine #(
        .PARTIALS(32), .GAIN_STEP(LAYER_GAIN_STEP), .LEVEL_SHIFT(LAYER_LEVEL_SHIFT),
        .MASK_FADE_STEP(LAYER_MASK_FADE_STEP), .ENERGY_COMPENSATION(1'b1),
        .MUSICAL_PRESSURE(1'b1)
    ) poly_engine (
        .clk(clk_audio_12m288), .rst_n(layer_rst_n), .sample_ce(sample_ce),
        .voice_gates(eng_gates), .voice_expression(eng_expression),
        .voice_envelopes(eng_envelopes), .voice_phase_incs(eng_phase_incs),
        .voice_presets(voice_presets),
        .accepted_on(eng_accepted_on), .event_accepted(accepted_events),
        .stolen(stolen_voices), .force_free(eng_force_free),
        .partial_target(eng_partial_target),
        .lane_pcm(eng_lane_pcm), .voice_partials(eng_voice_partials),
        .voice_gains(eng_voice_gains), .voice_generation(eng_voice_generation),
        .voice_note_active(eng_note_active), .grant_count(eng_grant_count),
        .budget_violation(eng_budget_violation),
        .diag_lane0(eng_diag_lane0), .diag_lane1(eng_diag_lane1)
    );

    // ---- four-voice mix ---------------------------------------------------------------
    // Mix contract: per voice, the frozen post-gain sample and the
    // voice's own layer output (which already carries that voice's envelope/pressure once)
    // are summed in 17 bits; the four per-voice sums are accumulated with two guard bits
    // (W + ceil(log2 N) = 16 + 2) and saturated once to 16. The layer can never double the
    // envelope and never bypasses release: both terms share the frozen voice envelope.
    // The frozen 4-voice mix is kept on diag_pcm_voice for telemetry/display.
    logic signed [16:0] voice_sum [0:3];
    logic signed [16:0] voice_sum_sat [0:3];
    logic signed [19:0] mix4_acc;
    logic signed[20:0]mix4_scaled;
    logic signed[19:0]brightness_layer_sum;
    logic signed[20:0]brightness_base,brightness_layer;
    logic signed [15:0] pcm_mix;
    logic               mix_clipped;

    always_comb begin
        for (integer v = 0; v < 4; v = v + 1) begin
            voice_sum[v] = {voice_levels[16*v + 15], voice_levels[16*v +: 16]}
                         + {eng_lane_pcm[16*v + 15], eng_lane_pcm[16*v +: 16]};
            voice_sum_sat[v] = voice_sum[v];
        end
        mix4_acc = $signed({voice_sum_sat[0][16], voice_sum_sat[0]})
                 + $signed({voice_sum_sat[1][16], voice_sum_sat[1]})
                 + $signed({voice_sum_sat[2][16], voice_sum_sat[2]})
                 + $signed({voice_sum_sat[3][16], voice_sum_sat[3]});
        // Narrow donor port (10.31.2): preserve its base/harmonic balance.
        // pcm_voice is already the four-base-voice average. The normal blend
        // makes J2X's harmonic count audible without altering the oscillator,
        // pressure law, envelope, phase scheduler, controls or effect family.
        brightness_layer_sum=$signed({{4{eng_lane_pcm[15]}},eng_lane_pcm[15:0]})
          +$signed({{4{eng_lane_pcm[31]}},eng_lane_pcm[31:16]})
          +$signed({{4{eng_lane_pcm[47]}},eng_lane_pcm[47:32]})
          +$signed({{4{eng_lane_pcm[63]}},eng_lane_pcm[63:48]});
        brightness_base=($signed({{5{pcm_voice[15]}},pcm_voice})*21'sd3)>>>3;
        brightness_layer=($signed({brightness_layer_sum[19],brightness_layer_sum})*21'sd3)>>>2;
        // Keep the existing deterministic 55Hz diagnostic gain unchanged.
        mix4_scaled=test_mode ? (($signed({mix4_acc[19],mix4_acc})*21'sd3)>>>4)
                              : brightness_base+brightness_layer;
        if (mix4_scaled > 21'sd32767) begin
            pcm_mix     = 16'sd32767;
            mix_clipped = 1'b1;
        end else if (mix4_scaled < -21'sd32768) begin
            pcm_mix     = -16'sd32768;
            mix_clipped = 1'b1;
        end else begin
            pcm_mix     = mix4_scaled[15:0];
            mix_clipped = 1'b0;
        end
    end

    // ---- effect: legacy chorus/delay family + space (FDN) family ----------------------
    // Effect-family contract: the old fx_mode 0..3 semantics are preserved and
    // always served by chorus_delay; a separate, readable `effect_family` config field
    // (field 19, 0=legacy 1=space) selects the FDN donor `spatial_reverb` instead. J2Y
    // stays the single intensity control in both families; the FDN interprets 0 as dry,
    // <=32 as the small room and above that as the gradient into the hall. The family is
    // committed through config field 19 and echoed in the 0x81 reply/capability mask.
    wire         effect_family = effect_family_pre;
    logic signed [15:0] pcm_out;       // legacy family output (mono)
    logic signed [15:0] fx_stereo_left, fx_stereo_right;
    logic signed [15:0] fx_out_left, fx_out_right, fx_out_mono;
    logic [15:0] fx_peak, fx_clip, fx_bypass, sp_clip, fx_peak_active, fx_clip_active;
    logic        fx_ready, fx_ready_active, sp_ready, sp_busy;
    logic [7:0]  fx_wet_legacy, sp_wet, fx_wet_active_q8;
    logic [15:0] sp_overruns, sp_state_clips;

    wire mute_active = panic_mute || performance_cmd[1] || fault_latched ||
                       (!test_mode && (instrument_cal_busy || !(&zone_calibrated_all)));
    wire effect_rst_n = core_rst_n && !mute_active && !audition_transition;

    // LFO: the module's defaults are LFO_W=26 / LFO_STEP=699, i.e. 0.5007 Hz at 48 kHz - a chorus
    // rate. The legacy LFO_SHIFT override is deliberately NOT passed: a positive value there would
    // select 2^LFO_SHIFT (1024) as the per-sample step and put the modulation back in the audio band.
    // The committed chorus_wet_max is a CEILING on the joystick wet gain,
    // exactly like partial_target ceilings the partial count.
    logic [7:0] wet_gain_ceiling_q8;
    always_comb begin
        wet_gain_ceiling_q8 = {1'b0, esp_wet_max} << 1;  // line 0..64 -> q8 0..128
        if (esp_wet_max >= 7'd64) wet_gain_ceiling_q8 = 8'd255; // 64 = uncapped
    end
    logic [7:0] wet_gain_eff_q8;
    always_comb wet_gain_eff_q8 = (aux_wet_gain_q8 > wet_gain_ceiling_q8)
                                ? wet_gain_ceiling_q8 : aux_wet_gain_q8;

    chorus_delay #(
        .DEPTH(CHORUS_DEPTH), .MIX_SHIFT(CHORUS_MIX_SHIFT), .MOD_DEPTH(64),
        .EXTERNAL_WET_GAIN(1'b1), .FRACTIONAL_TAP(CHORUS_FRACTIONAL)
    ) legacy_effect (
        .clk(clk_audio_12m288), .rst_n(effect_rst_n), .sample_ce(sample_ce),
        .pcm_in(pcm_mix), .mode(fx_mode), .wet_gain_target_q8(wet_gain_eff_q8),
        .pcm_out(pcm_out), .peak_abs(fx_peak), .clip_count(fx_clip),
        .bypass_count(fx_bypass), .ready(fx_ready),
        .wet_gain_active_q8(fx_wet_legacy),
        .diag_snapshot(diag_chorus_snapshot)
    );

    spatial_reverb space_effect (
        .clk(clk_audio_12m288), .rst_n(effect_rst_n && effect_family), .sample_ce(sample_ce),
        .pcm_in(pcm_mix), .wet_target_q8(wet_gain_eff_q8), .mode(fx_mode),
        .pcm_left(fx_out_left), .pcm_right(fx_out_right), .pcm_mono(fx_out_mono),
        .ready(sp_ready), .busy(sp_busy), .overrun_count(sp_overruns),
        .clip_count(sp_clip), .state_clip_count(sp_state_clips),
        .wet_actual(sp_wet)
    );
    // The FDN is the effect only when the committed family says so; legacy modes 0..3
    // keep their exact old processing and the FDN output is then never consumed.
    wire space_active = effect_family;
    logic [15:0] abs_l, abs_r;
    always_comb begin
        abs_l = fx_out_left[15] ? (~fx_out_left + 16'd1) : fx_out_left;
        abs_r = fx_out_right[15] ? (~fx_out_right + 16'd1) : fx_out_right;
        fx_stereo_left   = space_active ? fx_out_left  : pcm_out;
        fx_stereo_right  = space_active ? fx_out_right : pcm_out;
        fx_wet_active_q8 = space_active ? sp_wet : fx_wet_legacy;
        fx_peak_active   = space_active ? (abs_l > abs_r ? abs_l : abs_r) : fx_peak;
        fx_clip_active   = space_active ? sp_clip : fx_clip;
        fx_ready_active  = space_active ? sp_ready : fx_ready;
    end

    // ---- converter and amplifier (stereo PT8211 donor; L/R protected separately) ------
    logic hp_bck_core, hp_ws_core, hp_din_core, pa_en_core;
    logic signed [15:0] faded_pcm, faded_left, faded_right;
    logic signed [16:0] stereo_mono_sum;
    assign mobile_dx=$signed({4'd0,mobile_axis[0]})-$signed({4'd0,mobile_bend_center});
    assign mobile_dy=$signed({4'd0,mobile_axis[1]})-$signed({4'd0,mobile_vib_center});
    assign mobile_j2x=$signed({4'd0,mobile_axis[2]})-$signed({4'd0,mobile_aux_x});
    assign mobile_j2y=$signed({4'd0,mobile_axis[3]})-$signed({4'd0,chorus_center_y});
    assign mobile_voices={|voice_envelopes[63:48],|voice_envelopes[47:32],|voice_envelopes[31:16],|voice_envelopes[15:0]};
    assign mobile_health={2'd0,practice_interrupted,(&zone_calibrated_all),(aux_center_valid[1]&&!aux_axis_stale[1]),
      (aux_center_valid[0]&&!aux_axis_stale[0]),(vibrato_center_valid&&!vibrato_stale),(mobile_bend_valid&&!mobile_bend_stale)};
    always_ff@(posedge clk_audio_12m288 or negedge core_rst_n)begin
      if(!core_rst_n)begin for(integer mi=0;mi<4;mi=mi+1)mobile_axis[mi]<=0;end
      else if(diag_code_valid && diag_channel_id>=4)mobile_axis[diag_channel_id-4]<=diag_code;
    end
    assign mobile_state={6'd0,fx_mode,mobile_j2y,mobile_j2x,mobile_health,wet_gain_eff_q8,{2'd0,partial_effective},
      mobile_dy,mobile_dx,{4'd0,(audition_active?12'd0:vibrato_depth)},(audition_active?16'h8000:bend_ratio),{4'd0,guide_target},{2'd0,(audition_active?audition_step:guide_step)},
      {6'd0,guide_expression},{4'd0,led_zones},{4'd0,mobile_voices},{6'd0,note_layout},
      {6'd0,(audition_active?audition_preset:current_preset)},practice_last_request,(audition_active?{8'd0,audition_song}:practice_session),
      {1'd0,(audition_active?audition_length:score_length)},{5'd0,practice_transport},{6'd0,(audition_active?2'd3:guide_mode)},8'd1};

    pcm_output_stage #(.GAIN_Q15(32768), .LIMIT_LSB(32767),
                       .FADE_SAMPLES(OUTPUT_FADE_SAMPLES)) left_stage (
        .clk(clk_audio_12m288), .rst_n(core_rst_n && !audition_transition), .sample_ce(sample_ce),
        .pcm_in({{2{fx_stereo_left[15]}}, fx_stereo_left}),
        .atten_valid(esp_atten_valid), .atten_gain(esp_atten_gain), .mute_request(mute_active),
        .pcm_out(faded_left), .limited(), .muted(), .fade_active(), .limit_count()
    );
    pcm_output_stage #(.GAIN_Q15(32768), .LIMIT_LSB(32767),
                       .FADE_SAMPLES(OUTPUT_FADE_SAMPLES)) right_stage (
        .clk(clk_audio_12m288), .rst_n(core_rst_n && !audition_transition), .sample_ce(sample_ce),
        .pcm_in({{2{fx_stereo_right[15]}}, fx_stereo_right}),
        .atten_valid(esp_atten_valid), .atten_gain(esp_atten_gain), .mute_request(mute_active),
        .pcm_out(faded_right), .limited(), .muted(), .fade_active(), .limit_count()
    );
    always_comb begin
        dac_left  = mute_active ? 16'sd0 : faded_left;
        dac_right = mute_active ? 16'sd0 : faded_right;
        // One mean signal drives telemetry and simulation observation; the mute is
        // per-channel above, so L and R are each provably silent (an antiphase pair
        // would cancel in a mean and must never be used as a silence criterion).
        stereo_mono_sum = $signed({faded_left[15], faded_left})
                        + $signed({faded_right[15], faded_right});
        faded_pcm = stereo_mono_sum[16:1];
    end
    assign dac_pcm = mute_active ? 16'sd0 : faded_pcm;

    pt8211_tx_stereo #(.PA_ENABLE_DELAY_CYCLES(PA_ENABLE_DELAY)) dac (
        .clk_12m288(clk_audio_12m288), .rst_n(core_rst_n),
        .pcm_left(dac_left), .pcm_right(dac_right),
        .hp_bck(hp_bck_core), .hp_ws(hp_ws_core), .hp_din(hp_din_core), .pa_en(pa_en_core)
    );

    // ---- FPGA-generated performance telemetry ------------------------------------------
    logic [31:0] viz_phase_inc;
    logic        viz_tx, viz_busy;
    logic [15:0] viz_frames, viz_rejected;

    // The telemetry must report the tone that is really playing: in the test mode the layer is
    // driven by TEST_MODE_PHASE_INC, and the frozen slots are silent (their phase increments are 0
    // or stale), so reporting voice_phase_incs[] there would show 0 Hz for a 55 Hz test tone.
    // The 0x22 record reports voice0's pitch (the engine has no single owner; the
    // four-voice schema frame 0x84 carries every voice's own increment).
    always_comb viz_phase_inc = test_mode ? TEST_MODE_PHASE_INC : voice_phase_incs[31:0];

    viz_stream #(
        .CLOCKS_PER_BIT(CLOCKS_PER_BIT), .DECIM(VIZ_DECIM), .POINTS(VIZ_POINTS),
        .SCOPE_DIAG(1'b1), .PANEL_DIAG(1'b1)
    ) telemetry (
        .clk(clk_audio_12m288), .rst_n(core_rst_n), .sample_ce(sample_ce),
        .pcm(dac_pcm),
        .zone_gates(led_zones),
        .zone_pressure_all(zone_pressure_all),
        .voice_phase_inc(viz_phase_inc),
        // Preserve the legacy PC packet's MASK meaning. Four separate gains
        // belong only to the explicitly versioned 0x84 voice snapshot.
        .partial_mask(eng_voice_gains[7:0]==0 ? 32'd0 :
            eng_voice_partials[5:0]>=32 ? 32'hffffffff : (32'd1<<eng_voice_partials[5:0])-32'd1),
        .level_shift(LAYER_LEVEL_SHIFT),
        .chorus_peak(fx_peak_active), .chorus_clip(fx_clip_active),
        .frame_clipped(mix_clipped | voice_clipped),
        // 0x22 performance record: how many partials voice0's layer actually ran, and the
        // runtime effect mode. The four-voice schema frame (0x84) carries every voice.
        .partials_active(eng_voice_gains[7:0]==0 ? 6'd0 : eng_voice_partials[5:0]),
        .owner_voice(2'd0),
        .chorus_mode(fx_mode),
        .scope_adc6(scope_adc6), .scope_adc7(scope_adc7),
        .scope_status({z_pressed, fx_ready, 1'b0,
                       aux_axis_stale[1:0], aux_center_valid[1:0]}),
        .scope_preset(audition_active?audition_preset:current_preset),
        .scope_mapping_v2(1'b1),
        .scope_wet_target(aux_wet_gain_q8),
        .scope_wet_actual(fx_wet_active_q8),
        .pcm_pre_effect(pcm_mix),
        .voice_levels(voice_levels),
        .layer_level(eng_lane_pcm[15:0]),
        .panel_info({6'd0,audition_active, cal_refused_latched, 2'd0, partial_effective,
                     guide_miss, guide_wrong, guide_hits,
                     4'd0, LED, 6'd0, guide_expression, 4'd0, guide_target,
                     2'd0, guide_step,
                     2'd0, (&zone_calibrated_all), test_mode, panic_mute, guide_active,
                     note_layout, 8'd1}),
        .tx(viz_tx), .busy(viz_busy),
        .frames_sent(viz_frames), .tx_rejected(viz_rejected)
    );

    // ---- safe-state output gating -------------------------------------------------------
    assign SENSOR_CS_N = core_rst_n ? sensor_cs_n : 1'b1;
    assign SENSOR_SCK  = core_rst_n ? sensor_sck  : 1'b0;
    assign SENSOR_MOSI = core_rst_n ? sensor_mosi : 1'b0;
    assign HP_BCK      = core_rst_n ? hp_bck_core : 1'b0;
    assign HP_WS       = core_rst_n ? hp_ws_core  : 1'b0;
    assign HP_DIN      = core_rst_n ? hp_din_core : 1'b0;
    assign UART_TX     = core_rst_n ? viz_tx      : 1'b1;
    assign PA_EN       = (!core_rst_n || !pll_lock || mute_active) ? 1'b1 : pa_en_core;
    assign LED         = (!core_rst_n || !pll_lock) ? 4'b0000
                       : (led_fault ? {4{blink_phase}} :
                          (test_mode ? 4'b1111 : (guide_active ? guide_led : led_zones)));

    // ---- observability --------------------------------------------------------------------
    assign diag_pcm_voice      = pcm_voice;
    assign diag_pcm_layer      = eng_lane_pcm[15:0]; // voice0 layer; per-voice via 0x84
    assign diag_pcm_out        = dac_pcm;
    assign diag_mix_clipped    = mix_clipped;
    assign diag_layer_valid    = |eng_note_active;
    assign diag_layer_owner    = 2'd0;          // no single owner any more (four-voice engine)
    assign diag_layer_mask     = eng_voice_gains;
    assign diag_layer_gain     = eng_voice_gains[7:0];
    assign diag_layer_switching = eng_budget_violation;
    assign diag_layer_partials  = eng_voice_partials[5:0];
    assign diag_vibrato_ratio = vibrato_ratio;
    assign diag_vibrato_depth = vibrato_depth;
    assign diag_vibrato_center_valid = vibrato_center_valid;
    assign diag_vibrato_stale = vibrato_stale;
    assign diag_fx_ready       = fx_ready;
    assign diag_fx_peak        = fx_peak;
    assign diag_fx_clip        = fx_clip;
    assign diag_viz_frames     = viz_frames;
    assign diag_viz_rejected   = viz_rejected;
    assign diag_zone_valid     = {11'd0, zone_valid_all};
    assign diag_scan_timeouts  = scan_timeouts;
    assign diag_records_sent   = {8'd0, diag_frame_id};
    assign diag_uart_rejected  = 16'd0;
    assign diag_test_mode      = test_mode;
    assign diag_core_rst_n     = core_rst_n;
    assign diag_pll_locked     = pll_lock;
    assign diag_chorus_actual = pcm_out;
    assign diag_chorus_control = {scope_adc7, chorus_center_y, chorus_filtered_y,
                                  aux_center_valid[1], aux_axis_stale[1]};
    assign diag_additive_mask = eng_voice_gains;
    assign diag_additive_snapshot = eng_diag_lane0[132] ? eng_diag_lane1 : eng_diag_lane0; // lane0 GAO taps (schema in engine header)
    // Passive GAO taps. Voice 0 is allocated first after reset.
    assign diag_adsr_sample_ce = sample_ce;
    assign diag_adsr_gate      = voice_gates[0];
    assign diag_adsr_level     = voice_envelopes[15:0];
    assign diag_adsr_preset    = voice_presets[1:0];
    // Count actual ADSR state updates in the original audio clock domain.
    // These counts describe envelope segments, not physical input latency.
    adsr_stage_observer stage_observer (
        .clk(clk_audio_12m288), .rst_n(core_rst_n), .sample_ce(voice_sample_ce),
        .state(voice_envelope_states[2:0]), .gate(voice_gates[0]),
        .retrigger(accepted_note_on[0]), .preset(voice_presets[1:0]),
        .model(ADSR_ERROR_FEEDBACK ? 8'd2 : 8'd1),
        .attack_count(diag_adsr_attack_count), .decay_count(diag_adsr_decay_count),
        .release_count(diag_adsr_release_count), .valid(diag_adsr_stage_valid),
        .overflow(diag_adsr_stage_overflow), .event_count(),
        .done(diag_adsr_stage_done), .captured_preset(diag_adsr_captured_preset),
        .captured_model()
    );
    // Capture four release landmarks in the existing audio clock domain.
    // GAO reads the latched values with the PLL clock, avoiding a fabric clock.
    logic adsr_gate_d, adsr_collecting;
    logic [10:0] adsr_release_samples;
    always_ff @(posedge clk_audio_12m288 or negedge core_rst_n) begin
        if (!core_rst_n) begin
            adsr_gate_d <= 1'b0;
            adsr_collecting <= 1'b0;
            adsr_release_samples <= '0;
            diag_adsr_start <= '0;
            diag_adsr_256 <= '0;
            diag_adsr_768 <= '0;
            diag_adsr_1024 <= '0;
            diag_adsr_done <= 1'b0;
            diag_adsr_event_count <= '0;
        end else begin
            adsr_gate_d <= voice_gates[0];
            if (adsr_gate_d && !voice_gates[0]) begin
                diag_adsr_start <= voice_envelopes[15:0];
                diag_adsr_256 <= '0;
                diag_adsr_768 <= '0;
                diag_adsr_1024 <= '0;
                diag_adsr_done <= 1'b0;
                diag_adsr_event_count <= diag_adsr_event_count + 8'd1;
                adsr_release_samples <= '0;
                adsr_collecting <= 1'b1;
            end else if (sample_ce && adsr_collecting) begin
                if (adsr_release_samples == 11'd255)
                    diag_adsr_256 <= voice_envelopes[15:0];
                if (adsr_release_samples == 11'd767)
                    diag_adsr_768 <= voice_envelopes[15:0];
                if (adsr_release_samples == 11'd1023) begin
                    diag_adsr_1024 <= voice_envelopes[15:0];
                    diag_adsr_done <= 1'b1;
                    adsr_collecting <= 1'b0;
                end else
                    adsr_release_samples <= adsr_release_samples + 11'd1;
            end
        end
    end

    // Keep the unused frozen-instrument diagnostics visible to the netlist report instead of
    // letting an accidental optimisation hide a mis-wiring.
    logic unused_ok;
    always_comb unused_ok = ^{diag_channel_id, diag_code, diag_code_valid, panel_cmd, bend_ratio,
                              frame_clocks, voice_expression, voice_presets, fx_bypass,
                              viz_busy, zone_stale_all, zone_calibrated_all,
                              aux_center_valid, aux_axis_stale, score_song_id, score_length,
                              esp_crc_errors, esp_framing_errors};
    assign display_note_on=accepted_note_on;
    assign display_voice_gates=voice_gates;
    assign display_sample_ce=sample_ce;
    assign display_voice_levels=voice_levels;
    assign display_voice_regions=voice_regions;
    assign display_group=note_layout[0];
    assign display_mode=audition_active?2'd3:guide_mode;
    assign display_preset=audition_active?audition_preset:current_preset;
    assign display_expression=guide_expression;
    assign display_step=audition_active?audition_step:guide_step;
    assign display_target=practice_run?guide_target:4'd0;
    assign display_transport=practice_transport;
    assign display_score_valid=score_loaded && score_mapping_ready && score_length!=0;
    assign display_octave=note_layout[1];
    assign display_wrong=guide_wrong;
    assign display_calibrated=&zone_calibrated_all;
    assign display_mapping_ready=score_mapping_ready;
endmodule
