// Board-independent instrument core: ADC scan, conditioned zone events,
// note/group/octave mapping, four-voice allocation and per-voice synthesis.
// Extensions select eight ADC channels and external vibrato; see module parameters.
// Hardware PLLs, pin assignments and the processed release output live in wrappers.
module instrument_top #(
    parameter integer      SCAN_INTERVAL  = 12_288,   // 1 ms scan frame
    parameter integer      FRAME_TIMEOUT  = 4_096,
    parameter integer      ADC_CLK_DIV    = 8,
    parameter integer      ADC_SETTLE     = 64,
    parameter integer      ADC_CS_HIGH    = 16,
    parameter integer      FILTER_SHIFT   = 3,
    parameter logic [15:0] SLEW_STEP      = 16'd4096,
    parameter integer      STALE_FRAMES   = 5,
    parameter integer      CONFIRM_FRAMES = 1,
    parameter integer      DEBOUNCE_CYCLES = 61_440,
    parameter integer      KEY_LONG_CYCLES = 9_216_000,
    parameter integer      KEY_CLEAR_CYCLES = 36_864_000,
    parameter integer      KEY_COMBO_WINDOW = 2_088_960,
    parameter integer      PA_ENABLE_DELAY = 122_880,
    parameter logic [11:0] DEFAULT_ON_THRESHOLD  = 12'h200,
    parameter logic [11:0] DEFAULT_OFF_THRESHOLD = 12'h100,
    parameter logic [11:0] DEFAULT_BEND_DEAD_ZONE = 12'd40,
    parameter logic [11:0] DEFAULT_BEND_SPAN      = 12'd1000,
    // Thumb-centre capture. The bend centre is MEASURED from the stick; EXTERNAL_CENTER_MODE
    // is a compatibility switch for callers that genuinely have a fixed centre, and the
    // product default is the measured one.
    parameter logic        EXTERNAL_CENTER_MODE  = 1'b0,
    parameter logic [7:0]  THUMB_STABLE_FRAMES   = 8'd4,
    parameter logic [12:0] THUMB_STABLE_SPREAD   = 13'd32,
    parameter logic [12:0] THUMB_ACCEPT_WINDOW   = 13'd400,
    parameter logic [23:0] THUMB_FRESH_TIMEOUT   = 24'd98_304,
    parameter integer      ADC_CHANNELS         = 5, // D extension opts into CH5 raw stream
    parameter logic        ENABLE_EXTERNAL_VIBRATO = 1'b0,
    parameter logic        ENABLE_EXTERNAL_PRESET = 1'b0,
    parameter logic        ENABLE_EXTERNAL_PANEL = 1'b0,
    parameter logic        ENABLE_FAULT_GUARD = 1'b0,
    parameter logic        EXPRESSIVE_ADSR = 1'b0,
    parameter logic        ADSR_ERROR_FEEDBACK = 1'b0,
    parameter logic MUSICAL_PRESETS = 1'b0,
    parameter logic        FOUR_PRESETS = 1'b0
) (
    input  logic                clk_audio_mclk,   // 12.288 MHz audio domain
    input  logic                rst_n,
    input  logic                enable,           // 0 = scanner silent (diagnostic idle state)
    // Converter wires (no pin assigned here)
    output logic                SENSOR_SCK,
    output logic                SENSOR_MOSI,
    output logic                SENSOR_CS_N,
    input  logic                SENSOR_MISO,
    // The physical panel has two asynchronous, active-low keys. Gesture decoding is
    // centralised here so the board shell must not synchronise or debounce them again.
    input  logic [1:0]          key_n,
    input  logic [5:0]          external_panel_cmd,
    output logic [1:0]          diag_note_layout,
    // Calibration of the electrodes and of the thumb axis centre
    input  logic [11:0]         thumb_center_code,
    input  logic [11:0]         bend_dead_zone,
    input  logic [11:0]         bend_span,
    // Optional independent modulation ratio (Q1.15, unity=32768). Ignored unless enabled.
    input  logic [15:0]         external_vibrato_ratio_q15,
    // An absolute preset choice while the second joystick is deflected.
    // At its centre the panel KEY1 retains control.
    input  logic                external_preset_valid,
    input  logic                external_preset,
    input  logic                cal_request,
    input  logic [4:0]          cal_mask,
    input  logic                clear_calibration,
    output logic                cal_busy,
    output logic                cal_done,
    output logic                cal_refused,
    // Audio output
    output logic                HP_BCK,
    output logic                HP_WS,
    output logic                HP_DIN,
    output logic                PA_EN,
    // Indicators
    output logic [3:0]          LED,              // one per pressure zone, lit while held
    output logic                LED_FAULT,        // a channel stopped delivering samples
    // Diagnostics (what a logic analyser or a debug image would show)
    output logic [2:0]          diag_channel_id,
    output logic [11:0]         diag_code,
    output logic                diag_code_valid,
    output logic [7:0]          diag_frame_id,
    output logic [7:0]          diag_channel_seen,
    output logic                diag_frame_done,
    output logic                diag_frame_incomplete,
    output logic [15:0]         diag_frame_clocks,
    output logic [15:0]         diag_frame_skew,
    output logic [15:0]         diag_refused_requests,
    output logic [15:0]         diag_timeouts,
    output logic [63:0]         diag_zone_pressure,
    output logic [79:0]         diag_zone_pressure_all,  // all five channels, CH4 included
    output logic [4:0]          diag_zone_valid,         // channel converted in this frame
    output logic [39:0]         diag_zone_age,
    output logic [4:0]          diag_zone_stale,
    output logic [4:0]          diag_zone_calibrated,
    output logic [3:0]          diag_voice_gates,
    output logic [7:0]          diag_voice_presets,   // preset each voice latched at its note-on
    output logic [31:0]         diag_voice_notes,
    output logic [7:0]          diag_voice_regions,
    output logic [63:0]         diag_voice_expression,
    output logic [63:0]         diag_voice_envelopes,
    output logic [11:0]         diag_voice_envelope_states,
    output logic                diag_synth_sample_ce,
    output logic [63:0]         diag_voice_gain,
    output logic [127:0]        diag_voice_phase_incs,
    output logic [15:0]         diag_bend_ratio,
    output logic [11:0]         diag_bend_center,        // the centre the bend actually uses
    output logic                diag_bend_center_valid,  // the captured centre is valid
    output logic                diag_bend_bypass,        // 1 = the bend is bypassed at unity
    output logic [11:0]         diag_bend_candidate,     // code a grant would capture now
    output logic [7:0]          diag_bend_stable_frames, // length of the stable frame run
    output logic [5:0]          diag_panel_cmd,          // the six two-key gesture pulses
    output logic [1:0] diag_current_preset,     // preset selected for the next note
    output logic [63:0]         diag_voice_levels, // post-gain voice samples (S10)
    output logic [3:0]          diag_event_accepted,
    output logic [3:0]          diag_event_accepted_on,
    output logic [3:0]          diag_stolen,
    output logic                diag_fault_latched,
    output logic signed [15:0]  pcm_sample,
    output logic                clipped,
    // Dynamic trigger thresholds. A configuration commit may replace the per-zone
    // on-threshold at run time; with valid low the compile-time constants are used,
    // so every existing caller keeps the exact behaviour it had before.
    input  logic [47:0]         on_threshold_override,  // {zone3,zone2,zone1,zone0}
    input  logic                on_threshold_valid,
    // S02 configuration consumers for the note map. All optional in the same style
    // as on_threshold_override: a caller that leaves them unconnected never sees a
    // load, because the map only acts on cfg_load === 1'b1 (an undriven input is
    // neither 1'b1 in simulation nor in synthesis).
    input  logic [21:0]         cfg_commit_mask,
    input  logic [27:0]         cfg_notes,
    input  logic [3:0]          cfg_note_valid,
    input  logic                cfg_group_b,
    input  logic [1:0] cfg_preset_1,
    input  logic                cfg_octave_up,
    input  logic                cfg_load,
    // S05 guide gate: suppress new note-ons of the masked zones (wrong FSR).
    input logic [3:0] guide_block_mask,
    input logic audition_active=1'b0,audition_event_valid=1'b0,audition_event_on=1'b0,
    input logic[1:0]audition_region=2'd0,audition_preset=2'd0,
    input logic[6:0]audition_note=7'd0,input logic[7:0]audition_generation=8'd0,
    input logic[31:0]audition_inc=32'd0,input logic[63:0]audition_pressure=64'd0,
    // T2 event telemetry from rtl/event_recorder.sv: manual accepted events as 0x85
    // bodies. take is pulsed by the link's TX mux; a caller that leaves it unconnected
    // (=== guard below) simply never drains and every push reports as dropped.
    output logic        rec_ready,
    output logic [5:0]  rec_length,
    output logic [63:0] rec_body,
    input  logic        rec_take,
    output logic [7:0]  rec_dropped,
    output logic [7:0]  rec_seq,
    // T3 four-frequency test entry: inject four REAL note-ons through the normal
    // event path (allocator/generations/voice cores/DAC) and retire them with
    // matching note-offs. One event per clock; the injector wins over manual
    // events only during its 4-clock dispatch windows.
    input  logic        test4_start = 1'b0,
    input  logic        test4_stop  = 1'b0
);
    localparam integer ZONES = 5;   // CH0..CH3 pressure zones, CH4 thumb axis

    // ---- two-key panel gestures -------------------------------------------------
    logic group_toggle, preset_toggle, octave_toggle, panic_press;
    logic calibrate_press, clear_calibration_press;
    logic key_long_active, key_combo_active, keys_armed;

    generate if (ENABLE_EXTERNAL_PANEL) begin : g_external_panel
        assign {group_toggle, preset_toggle, octave_toggle,
                calibrate_press, panic_press, clear_calibration_press} = external_panel_cmd;
        assign key_long_active = 1'b0;
        assign key_combo_active = 1'b0;
        assign keys_armed = 1'b1;
    end else begin : g_legacy_panel
    two_key_gesture #(
        .DEBOUNCE_CYCLES(DEBOUNCE_CYCLES),
        .LONG_CYCLES(KEY_LONG_CYCLES),
        .CLEAR_CYCLES(KEY_CLEAR_CYCLES),
        .COMBO_WINDOW(KEY_COMBO_WINDOW)
    ) panel (
        .clk(clk_audio_mclk), .rst_n, .key_n,
        .cmd_group(group_toggle), .cmd_preset(preset_toggle),
        .cmd_octave(octave_toggle), .cmd_calibrate(calibrate_press),
        .cmd_panic(panic_press), .cmd_clear_calibration(clear_calibration_press),
        .long_active(key_long_active), .combo_active(key_combo_active), .armed(keys_armed)
    );
    end endgenerate

    // ---- M1: scan and per-zone conditioning -------------------------------------
    logic [63:0] zone_pressure;
    logic [79:0] all_zone_pressure;
    logic [4:0]  zone_gate, zone_trigger_on, zone_trigger_off;
    logic [4:0]  zone_stale, zone_calibrated, zone_valid, zone_has_sample;
    logic [39:0] zone_age;
    logic [2:0]  code_channel;
    logic [11:0] code;
    logic        code_valid;

    logic [59:0] on_thresholds;
    logic [59:0] off_thresholds;

    // The thumb channel never triggers a note, so its thresholds are zero. The four
    // playing zones use the compile-time constant unless a configuration commit has
    // taken over, in which case each zone gets its own committed value.
    // `===` and not `if`: an instance that leaves these ports unconnected must fall
    // back to the compile-time constants, not to an undefined threshold. A plain
    // truth test on an undriven input would make every zone's trigger point x.
    assign on_thresholds  = {12'h000,
                             (on_threshold_valid === 1'b1) ? on_threshold_override[47:36] : DEFAULT_ON_THRESHOLD,
                             (on_threshold_valid === 1'b1) ? on_threshold_override[35:24] : DEFAULT_ON_THRESHOLD,
                             (on_threshold_valid === 1'b1) ? on_threshold_override[23:12] : DEFAULT_ON_THRESHOLD,
                             (on_threshold_valid === 1'b1) ? on_threshold_override[11:0]  : DEFAULT_ON_THRESHOLD};
    assign off_thresholds = {12'h000, DEFAULT_OFF_THRESHOLD, DEFAULT_OFF_THRESHOLD,
                             DEFAULT_OFF_THRESHOLD, DEFAULT_OFF_THRESHOLD};

    // ---- calibration arbitration: five channels, all-or-nothing -------------------
    // The request path is arbitrated here rather than inside the bank, because a calibration
    // that is refused must not touch ANY selected channel: if the thumb axis is not at rest,
    // the four pressure zones keep their old baselines instead of being re-zeroed on a stick
    // that is still moving. cal_start is only ever asserted when every selected channel is
    // released with a fresh sample AND the thumb capture would accept.
    logic [4:0]  cal_mask_eff;
    logic        cal_wants;
    logic        request_seen;
    logic        request_edge;
    logic        zones_ready;
    logic        cal_all_ready;
    logic        cal_start;
    logic        thumb_cal_start;
    logic        thumb_ready;
    logic        cal_refuse_r;
    logic        bank_refused;
    logic        cal_busy_int, cal_done_int;
    logic        clear_calibration_all;
    logic [11:0] thumb_center_auto;
    logic        thumb_center_valid;
    logic [11:0] thumb_candidate;
    logic [7:0]  thumb_stable_frames;
    logic [11:0] bend_center_eff;
    logic        bend_bypass;

    zone_input_top #(
        .ZONES(ZONES), .ADC_CHANNELS(ADC_CHANNELS),
        .SCAN_INTERVAL(SCAN_INTERVAL), .FRAME_TIMEOUT(FRAME_TIMEOUT),
        .ADC_CLK_DIV(ADC_CLK_DIV), .ADC_SETTLE(ADC_SETTLE), .ADC_CS_HIGH(ADC_CS_HIGH),
        .FILTER_SHIFT(FILTER_SHIFT), .SLEW_STEP(SLEW_STEP),
        .STALE_FRAMES(STALE_FRAMES), .CONFIRM_FRAMES(CONFIRM_FRAMES),
        // CH0..CH3 are the four trigger zones; CH4 is the thumb axis, which shapes the bend
        // and is never a trigger, so its gate can never block a calibration.
        .TRIGGER_ENABLE_MASK(5'b01111)
    ) surface (
        .clk(clk_audio_mclk), .rst_n, .enable,
        .SENSOR_SCK(SENSOR_SCK), .SENSOR_MOSI(SENSOR_MOSI),
        .SENSOR_CS_N(SENSOR_CS_N), .SENSOR_MISO(SENSOR_MISO),
        .on_thresholds(on_thresholds), .off_thresholds(off_thresholds),
        .cal_request(cal_start), .cal_mask(cal_mask_eff),
        .clear_calibration(clear_calibration_all),
        .cal_busy(cal_busy_int), .cal_done(cal_done_int), .cal_refused(bank_refused),
        .pressure(all_zone_pressure),
        .gate(zone_gate), .trigger_on(zone_trigger_on), .trigger_off(zone_trigger_off),
        .stale(zone_stale), .calibrated(zone_calibrated),
        .has_sample(zone_has_sample), .zone_valid(zone_valid),
        .age(zone_age),
        .channel_id(code_channel), .code(code), .code_valid(code_valid),
        .frame_id(diag_frame_id), .channel_seen(diag_channel_seen),
        .frame_done(diag_frame_done), .frame_incomplete(diag_frame_incomplete),
        .frame_clocks(diag_frame_clocks), .frame_skew_clocks(diag_frame_skew),
        .refused_requests(diag_refused_requests), .timeouts(diag_timeouts)
    );

    assign zone_pressure = all_zone_pressure[63:0];

    // ---- calibration request arbitration ------------------------------------------
    // The long KEY1 gesture calibrates ALL FIVE channels; the external input may select a
    // subset (for example a single electrode after it has been repositioned).
    assign cal_mask_eff          = calibrate_press ? 5'b11111 : cal_mask;
    assign cal_wants             = cal_request | calibrate_press;
    assign clear_calibration_all = clear_calibration | clear_calibration_press;

    always_comb begin
        zones_ready = 1'b1;
        for (integer i = 0; i < 4; i = i + 1) begin
            if (cal_mask_eff[i] && (zone_gate[i] || !zone_has_sample[i] || zone_stale[i]))
                zones_ready = 1'b0;
        end
    end
    assign cal_all_ready   = zones_ready && (!cal_mask_eff[4] || thumb_ready);
    assign request_edge    = cal_wants && !request_seen;
    assign cal_start       = request_edge && cal_all_ready && !cal_busy_int;
    assign thumb_cal_start = cal_start && cal_mask_eff[4];

    always_ff @(posedge clk_audio_mclk or negedge rst_n) begin
        if (!rst_n) begin
            request_seen <= 1'b0;
            cal_refuse_r <= 1'b0;
        end else begin
            // One calibration per request edge, so a held input cannot loop the procedure,
            // and a request that cannot be served is REPORTED rather than silently dropped.
            if (!cal_wants) request_seen <= 1'b0;
            else if (request_edge) request_seen <= 1'b1;
            cal_refuse_r <= request_edge && (!cal_all_ready || cal_busy_int);
        end
    end

    assign cal_busy    = cal_busy_int;
    assign cal_done    = cal_done_int;
    assign cal_refused = bank_refused | cal_refuse_r;

    // ---- M4: the thumb axis is a raw code, so bending uses the code, not the expression --
    logic [11:0] thumb_code;
    logic [15:0] bend_ratio;
    logic signed [15:0] bend_semitone_q8;
    logic signed [6:0]  bend_step;
    logic               bend_at_center;

    always_ff @(posedge clk_audio_mclk or negedge rst_n) begin
        if (!rst_n) thumb_code <= 12'd0;
        else if (code_valid && (code_channel == 3'd4)) thumb_code <= code;
    end

    // The centre the bend uses is the MEASURED one. thumb_center_code is the plausibility
    // reference for a first capture (and the centre in the explicit external-fixed-centre
    // compatibility mode) and can never override a valid captured centre.
    thumb_center_calibrator #(
        .STABLE_FRAMES(THUMB_STABLE_FRAMES),
        .STABLE_SPREAD(THUMB_STABLE_SPREAD),
        .ACCEPT_WINDOW(THUMB_ACCEPT_WINDOW),
        .FRESH_TIMEOUT(THUMB_FRESH_TIMEOUT)
    ) thumb_centre (
        .clk(clk_audio_mclk), .rst_n,
        .sample_valid(code_valid && (code_channel == 3'd4)), .sample_code(code),
        .frame_done(diag_frame_done),
        .start(thumb_cal_start), .commit(cal_done_int),
        .clear_calibration(clear_calibration_all),
        .reference_center(thumb_center_code),
        .center_code(thumb_center_auto), .center_valid(thumb_center_valid),
        .ready(thumb_ready), .candidate_code(thumb_candidate),
        .stable_frames(thumb_stable_frames)
    );

    assign bend_center_eff = EXTERNAL_CENTER_MODE ? thumb_center_code : thumb_center_auto;
    assign bend_bypass     = EXTERNAL_CENTER_MODE ? 1'b0 : !thumb_center_valid;

    pitch_bend bend (
        .axis_code(thumb_code), .center_code(bend_center_eff),
        .dead_zone_code(bend_dead_zone), .span_code(bend_span), .bypass(bend_bypass),
        .semitone_q8(bend_semitone_q8), .ratio_q15(bend_ratio),
        .step_index(bend_step), .at_center(bend_at_center)
    );

    logic [15:0] synth_bend_ratio;
    generate
        if (ENABLE_EXTERNAL_VIBRATO) begin : g_external_vibrato
            logic [31:0] ratio_product;
            logic [16:0] ratio_rounded;
            assign ratio_product = bend_ratio * external_vibrato_ratio_q15;
            assign ratio_rounded = (ratio_product + 32'd16384) >> 15;
            assign synth_bend_ratio = (ratio_rounded > 17'd65535)
                                    ? 16'hffff : ratio_rounded[15:0];
        end else begin : g_no_external_vibrato
            assign synth_bend_ratio = bend_ratio;
        end
    endgenerate

    // ---- M2: zone triggers become note events with latched identity --------------
    logic signed [15:0] voice_lvl0, voice_lvl1, voice_lvl2, voice_lvl3;
    logic        event_valid, event_on;
    logic [1:0]  event_region, event_preset;
    logic [6:0]  event_note;
    logic [31:0] event_phase_inc;
    logic [7:0]  event_generation;
    // T1 live retune stream from the note map; frozen while a demo owns the synth
    // (the retune_arm gate at the source keeps the manual shadow bookkeeping
    // consistent, the mux here is defence in depth).
    logic        retune_valid;
    logic [1:0]  retune_region;
    logic [6:0]  retune_old_note, retune_new_note;
    logic [31:0] retune_phase_inc;
    logic [7:0]  retune_generation;
    logic group_b, octave_up;
    logic [1:0] preset_1;
    logic        preset_toggle_effective;

    assign preset_toggle_effective = ENABLE_EXTERNAL_PRESET
                                   ? (external_preset_valid
                                      ? (preset_1 != external_preset) : preset_toggle)
                                   : preset_toggle;

    // Port the detected-anomaly policy from 9c4b9bd. Legacy B/C keeps its
    // original behaviour; the fused configuration D explicitly enables it.
    logic fault_latched, force_release;
    logic panic_interlock;
    generate if (ENABLE_FAULT_GUARD) begin : g_guard
        fault_guard guard (
            .clk(clk_audio_mclk), .rst_n,
            .zone_stale(zone_stale), .frame_done(diag_frame_done),
            .frame_incomplete(diag_frame_incomplete), .zone_valid(zone_valid),
            .zone_gate(zone_gate[3:0]), .scan_timeout_count(diag_timeouts),
            .cal_done(cal_done_int), .fault_latched(fault_latched),
            .force_release(force_release), .fresh_run(), .cal_seen(), .timeout_detected()
        );
    end else begin : g_no_guard
        assign fault_latched = 1'b0;
        assign force_release = 1'b0;
    end endgenerate
    always_ff @(posedge clk_audio_mclk or negedge rst_n) begin
        if (!rst_n) panic_interlock <= 1'b0;
        else if (panic_press) panic_interlock <= 1'b1;
        else if (zone_gate[3:0] == 0) panic_interlock <= 1'b0;
    end
    assign diag_fault_latched = fault_latched;
    assign diag_voice_levels = {voice_lvl3, voice_lvl2, voice_lvl1, voice_lvl0};
    zone_note_map #(.ENABLE_PROTECTION(ENABLE_FAULT_GUARD)) notes (
        .clk(clk_audio_mclk), .rst_n,
        .group_toggle(group_toggle), .preset_toggle(preset_toggle_effective), .octave_toggle(octave_toggle),
        .panic(panic_press),
        .clear_all(force_release | clear_calibration_all),
        .block_on(fault_latched | panic_interlock | panic_press),
        .trigger_on(zone_trigger_on[3:0]), .trigger_off(zone_trigger_off[3:0]),
        .zone_gate(zone_gate[3:0]),
        // Any stale channel blinks the four LEDs, the thumb axis included.
        .zone_stale(zone_stale[3:0] | {4{zone_stale[4] | fault_latched}}),
        .event_valid(event_valid), .event_on(event_on), .event_region(event_region),
        .event_note(event_note), .event_phase_inc(event_phase_inc),
        .event_preset(event_preset), .event_generation(event_generation),
        .retune_valid(retune_valid), .retune_region(retune_region),
        .retune_old_note(retune_old_note), .retune_new_note(retune_new_note),
        .retune_phase_inc(retune_phase_inc), .retune_generation(retune_generation),
        .retune_arm(!audition_active),
        .group_b(group_b), .preset_1(preset_1), .octave_up(octave_up),
        .leds(LED), .led_fault(LED_FAULT),
        .cfg_commit_mask(cfg_commit_mask), .cfg_notes(cfg_notes),
        .cfg_note_valid(cfg_note_valid), .cfg_group_b(cfg_group_b),
        .cfg_preset_1(cfg_preset_1), .cfg_octave_up(cfg_octave_up),
        .cfg_load(cfg_load), .block_mask(guide_block_mask)
    );

    // The audio sample tick: one enable every 256 audio clocks, i.e. 48000.53 Hz.
    logic sample_ce;
    audio_sample_tick_div256 tick (.clk(clk_audio_mclk), .rst_n, .sample_ce);
    assign diag_synth_sample_ce = sample_ce;

    // ---- T3: four-frequency injector ---------------------------------------------
    // 220 / 277.18 / 369.99 / 523.25 Hz at 48000.529661 Hz: inc = round(2^32*f/fs),
    // the same formula and rounding as rtl/zone_note_map.sv inc_for_note.
    localparam logic [31:0] T4_INC0 = 32'h012C5EBA;
    localparam logic [31:0] T4_INC1 = 32'h017A7146;
    localparam logic [31:0] T4_INC2 = 32'h01F928FD;
    localparam logic [31:0] T4_INC3 = 32'h02CA677F;
    logic [3:0]  t4_dispatch;      // 1..4 note-ons, 5..8 note-offs, 0 idle
    logic [7:0]  t4_gen_base;
    logic        t4_ev_valid, t4_ev_on;
    logic [1:0]  t4_region;
    logic [6:0]  t4_note;
    logic [31:0] t4_inc;
    logic [7:0]  t4_gen;
    wire [2:0]   t4_idx = (t4_dispatch <= 4'd4) ? t4_dispatch[2:0] - 3'd1
                                                : t4_dispatch[2:0] - 3'd5; // ons 1..4, offs 5..8 -> 0..3
    always_comb begin
        t4_ev_valid = (t4_dispatch != 4'd0);
        t4_ev_on    = (t4_dispatch <= 4'd4);
        t4_region   = t4_idx[1:0];
        case (t4_idx)
            2'd0: begin t4_inc = T4_INC0; t4_note = 7'd57; end // A3 220 Hz
            2'd1: begin t4_inc = T4_INC1; t4_note = 7'd61; end // C#4
            2'd2: begin t4_inc = T4_INC2; t4_note = 7'd66; end // F#4
            default: begin t4_inc = T4_INC3; t4_note = 7'd72; end // C5
        endcase
        t4_gen = t4_gen_base + {5'd0, t4_idx};
    end
    always_ff @(posedge clk_audio_mclk or negedge rst_n) begin
        if (!rst_n) begin
            t4_dispatch <= 4'd0; t4_gen_base <= 8'd0;
        end else begin
            // ons walk 1..4 then the injector goes idle; the offs (5..8) only run
            // when the stop arrives, so the chord actually sustains.
            if (t4_dispatch != 4'd0) begin
                if (t4_dispatch < 4'd4)      t4_dispatch <= t4_dispatch + 4'd1;
                else if (t4_dispatch == 4'd4) t4_dispatch <= 4'd0;
                else                          t4_dispatch <= (t4_dispatch == 4'd8) ? 4'd0 : t4_dispatch + 4'd1;
            end
            if (test4_start && t4_dispatch == 4'd0) begin
                t4_dispatch  <= 4'd1;
                t4_gen_base  <= t4_gen_base + 8'd4;
            end
            // guard against a held stop re-triggering the same off slot
            if (test4_stop && t4_dispatch < 4'd5) t4_dispatch <= 4'd5;
        end
    end
    // The stop half reuses t4_gen_base (unchanged since the start), so the
    // note-offs carry the same generations as their note-ons.
    // synth event mux (below) prefers: audition > injector > manual.

    // ---- T2: manual accepted-event telemetry (see rtl/event_recorder.sv) ----------
    logic rec_ready_r, rec_full_take;
    logic [5:0] rec_length_r;
    logic [63:0] rec_body_r;
    logic [7:0] rec_dropped_r, rec_seq_r;
    assign rec_full_take = (rec_take === 1'b1);
    event_recorder #(.QUEUE_DEPTH(8)) recorder (
        .clk(clk_audio_mclk), .rst_n, .sample_ce(sample_ce),
        .arm(!audition_active),
        .event_valid(event_valid), .event_on(event_on), .event_region(event_region),
        .event_preset(event_preset), .event_note(event_note),
        .event_generation(event_generation),
        .ready(rec_ready_r), .length(rec_length_r), .body(rec_body_r),
        .take(rec_full_take), .dropped(rec_dropped_r), .seq(rec_seq_r)
    );
    assign rec_ready   = rec_ready_r;
    assign rec_length  = rec_length_r;
    assign rec_body    = rec_body_r;
    assign rec_dropped = rec_dropped_r;
    assign rec_seq     = rec_seq_r;

    // ---- M2/M3: ownership, per-voice expression and presets ----------------------
    // During an explicit mute, discard the old voices as well as their gates.
    // Otherwise a long release can become audible again when calibration clears
    // the fault. Normal note-off still completes its ADSR release unchanged.
    reg audition_owned_d;
    always_ff@(posedge clk_audio_mclk or negedge rst_n)begin
      if(!rst_n)audition_owned_d<=0;else audition_owned_d<=audition_active;
    end
    wire ownership_stable=audition_active==audition_owned_d;
    wire synth_rst_n = ownership_stable && rst_n && !(ENABLE_FAULT_GUARD &&
        (fault_latched || panic_interlock || panic_press || cal_busy_int || clear_calibration_all));
    // Event source priority: demo takeover > four-frequency injector > manual play.
    wire synth_ev_valid   = audition_active ? audition_event_valid :
                            (t4_dispatch != 4'd0 ? t4_ev_valid : event_valid);
    wire synth_ev_on      = audition_active ? audition_event_on :
                            (t4_dispatch != 4'd0 ? t4_ev_on : event_on);
    wire [1:0]  synth_ev_region  = audition_active ? audition_region :
                            (t4_dispatch != 4'd0 ? t4_region : event_region);
    wire [6:0]  synth_ev_note    = audition_active ? audition_note :
                            (t4_dispatch != 4'd0 ? t4_note : event_note);
    wire [31:0] synth_ev_inc     = audition_active ? audition_inc :
                            (t4_dispatch != 4'd0 ? t4_inc : event_phase_inc);
    wire [1:0]  synth_ev_preset  = audition_active ? audition_preset :
                            (t4_dispatch != 4'd0 ? 2'd0 : event_preset);
    wire [7:0]  synth_ev_gen     = audition_active ? audition_generation :
                            (t4_dispatch != 4'd0 ? t4_gen : event_generation);

    poly_synth_regions #(.EXPRESSIVE_ADSR(EXPRESSIVE_ADSR),
                        .ADSR_ERROR_FEEDBACK(ADSR_ERROR_FEEDBACK),
                         .BALANCED_PRESETS(FOUR_PRESETS),.MUSICAL_PRESETS(MUSICAL_PRESETS)) synth (
        .clk(clk_audio_mclk), .rst_n(synth_rst_n), .sample_ce(sample_ce),
        .event_valid(synth_ev_valid), .event_on(synth_ev_on), .event_region(synth_ev_region),
        .event_note(synth_ev_note), .event_phase_inc(synth_ev_inc),
        .event_preset(synth_ev_preset), .event_generation(synth_ev_gen),
        .retune_valid(audition_active?1'b0:retune_valid),
        .retune_region(audition_active?2'd0:retune_region),
        .retune_old_note(audition_active?7'd0:retune_old_note),
        .retune_new_note(audition_active?7'd0:retune_new_note),
        .retune_phase_inc(audition_active?32'd0:retune_phase_inc),
        .retune_generation(audition_active?8'd0:retune_generation),
        .region_pressure(audition_active?audition_pressure:zone_pressure), .bend_ratio_q15(audition_active?16'h8000:synth_bend_ratio),
        .pcm_sample(pcm_sample), .clipped(clipped),
        .voice_sample0(voice_lvl0), .voice_sample1(voice_lvl1),
        .voice_sample2(voice_lvl2), .voice_sample3(voice_lvl3),
        .voice_expression(diag_voice_expression), .voice_gain(diag_voice_gain),
        .voice_envelopes(diag_voice_envelopes),
        .voice_envelope_states(diag_voice_envelope_states),
        .voice_presets(diag_voice_presets), .voice_gates(diag_voice_gates),
        .voice_notes(diag_voice_notes),.owner_regions(diag_voice_regions),
        .active_voices(), .allocated_voices(),
        .event_accepted(diag_event_accepted), .stolen(diag_stolen),
        .selected_voice(), .event_overflow(), .voice_phase_incs(diag_voice_phase_incs)
    );

    // The allocator's acceptance is registered. Delay the event type with it,
    // so accepted note-offs cannot claim the auxiliary layer.
    logic event_on_d;
    always_ff @(posedge clk_audio_mclk or negedge rst_n) begin
        if (!rst_n) event_on_d <= 1'b0;
        else event_on_d <= audition_active?audition_event_on:event_on;
    end
    assign diag_event_accepted_on = diag_event_accepted & {4{event_on_d}};

    // ---- PT8211 transmitter with its start-up mute -------------------------------
    pt8211_tx_mono #(.PA_ENABLE_DELAY_CYCLES(PA_ENABLE_DELAY)) dac (
        .clk_12m288(clk_audio_mclk), .rst_n, .pcm_sample(pcm_sample),
        .hp_bck(HP_BCK), .hp_ws(HP_WS), .hp_din(HP_DIN), .pa_en(PA_EN)
    );

    // ---- diagnostics -------------------------------------------------------------
    assign diag_channel_id  = code_channel;
    assign diag_code        = code;
    assign diag_code_valid  = code_valid;
    assign diag_zone_pressure = zone_pressure;
    assign diag_zone_pressure_all = all_zone_pressure;
    assign diag_zone_valid = zone_valid;
    assign diag_panel_cmd = {group_toggle, preset_toggle, octave_toggle,
                             calibrate_press, panic_press, clear_calibration_press};
    assign diag_current_preset = preset_1;
    assign diag_note_layout = {octave_up, group_b};
    assign diag_zone_age    = zone_age;
    assign diag_zone_stale  = zone_stale;
    assign diag_zone_calibrated = zone_calibrated;
    assign diag_bend_ratio  = bend_ratio;
    assign diag_bend_center = bend_center_eff;
    assign diag_bend_center_valid  = thumb_center_valid;
    assign diag_bend_bypass        = bend_bypass;
    assign diag_bend_candidate     = thumb_candidate;
    assign diag_bend_stable_frames = thumb_stable_frames;
endmodule
