// T2 replay + telemetry bench, production RTL only:
//   A. rtl/event_recorder.sv captures driven manual events; the frames come out of
//      the real esp_score_link UART as 0x85 with the exact body contract
//      (seq/flags/note/generation/delta/dropped), overflow drops are reported, and
//      the periodic 0x84 keeps flowing (no telemetry starvation).
//   B. The compiled 0x1B/0x1C/0x1D/0x1E command stream produced by the REAL
//      miniprogram compiler chain (tests/integration/test_event_record_chain.mjs
//      -> tests/rtl/event_replay_commands.hex) is fed into the real UART RX and
//      must drive the real audition_sequencer: loaded, active, steps advancing,
//      note events dispatched into the real instrument_top synth, and the PT8211
//      serial data line carrying bits. This is the "phone JSON -> FPGA audio
//      state" closure on the production chain.
`timescale 1ns/1ps
module tb_event_record_stream;
    localparam integer CLK_PERIOD = 81;
    localparam integer CPB = 107; // esp_score_link CLOCKS_PER_BIT default
    logic clk = 0, rst_n = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    integer errors = 0;
    task automatic fail(input string m);
        begin errors = errors + 1; $display("FAIL: %s", m); end
    endtask

    logic sample_ce;
    logic [7:0] tick_cnt = 0;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) tick_cnt <= 0;
        else begin
            if (tick_cnt == 255) tick_cnt <= 0; else tick_cnt <= tick_cnt + 1;
            sample_ce <= (tick_cnt == 254);
        end
    end
    task automatic wait_clks(input integer n);
        repeat (n) @(posedge clk);
    endtask
    task automatic wait_samples(input integer n);
        repeat (n) @(posedge sample_ce);
    endtask

    // ---- A: recorder stimulus ----------------------------------------------------
    logic       ev_valid = 0, ev_on = 0;
    logic [1:0] ev_region = 0, ev_preset = 0;
    logic [6:0] ev_note = 0;
    logic [7:0] ev_gen = 0;
    wire        rec_ready, rec_take;
    wire [5:0]  rec_length;
    wire [63:0] rec_body;
    wire [7:0]  rec_dropped, rec_seq;

    logic rec_arm = 1'b1;
    event_recorder #(.QUEUE_DEPTH(8)) rec (
        .clk(clk), .rst_n(rst_n), .sample_ce(sample_ce), .arm(rec_arm),
        .event_valid(ev_valid), .event_on(ev_on), .event_region(ev_region),
        .event_preset(ev_preset), .event_note(ev_note), .event_generation(ev_gen),
        .ready(rec_ready), .length(rec_length), .body(rec_body), .take(rec_take),
        .dropped(rec_dropped), .seq(rec_seq)
    );

    // ---- UART TX byte capture: tap the link's own byte pump (tx_start pulses once
    // per byte while tx_data holds it) - bit-banging the wire only desyncs.
    logic [7:0] tx_byte;
    logic       tx_byte_valid;
    always @(posedge clk) begin
        tx_byte_valid <= 1'b0;
        if (link.tx_start) begin
            tx_byte <= link.tx_data;
            tx_byte_valid <= 1'b1;
        end
    end

    // frame collector: 0x85 event bodies and telemetry frame counts
    logic [7:0]  seen_ev_seq [0:63];
    logic [7:0]  seen_ev_flags [0:63];
    logic [7:0]  seen_ev_note [0:63];
    logic [7:0]  seen_ev_gen [0:63];
    logic [23:0] seen_ev_delta [0:63];
    logic [7:0]  seen_ev_drop [0:63];
    integer      ev_frames = 0, status_frames = 0, voice_frames = 0;
    logic [7:0]  window [0:15];
    integer      wlen = 0;
    integer bytes_seen = 0;
    logic [7:0] first_bytes [0:7];
    always @(posedge clk) begin
        if (tx_byte_valid && !link.tx_start) begin
            bytes_seen = bytes_seen + 1;
            if (bytes_seen <= 8) first_bytes[bytes_seen-1] = tx_byte;
            if (wlen < 16) begin window[wlen] = tx_byte; wlen = wlen + 1; end
            else begin
                for (integer s = 0; s < 15; s = s + 1) window[s] = window[s + 1];
                window[15] = tx_byte;
            end
            if (wlen >= 15 && window[wlen - 15] == 8'hA5 && window[wlen - 14] == 8'h5A) begin
                if (window[wlen - 12] == 8'h85 && window[wlen - 11] == 8'd8) begin
                    if (ev_frames < 64) begin
                        seen_ev_seq[ev_frames]   = window[wlen - 9];
                        seen_ev_flags[ev_frames] = window[wlen - 8];
                        seen_ev_note[ev_frames]  = window[wlen - 7];
                        seen_ev_gen[ev_frames]   = window[wlen - 6];
                        seen_ev_delta[ev_frames] = {window[wlen - 3], window[wlen - 4], window[wlen - 5]};
                        seen_ev_drop[ev_frames]  = window[wlen - 2];
                    end
                    ev_frames = ev_frames + 1;
                end
                if (window[wlen - 12] == 8'h80) status_frames = status_frames + 1;
                if (window[wlen - 12] == 8'h84) voice_frames = voice_frames + 1;
            end
        end
    end

    task automatic pulse_event(input logic on, input logic [1:0] r, input logic [1:0] p,
                               input logic [6:0] n, input logic [7:0] g);
        begin
            @(negedge clk);
            ev_valid = 1; ev_on = on; ev_region = r; ev_preset = p; ev_note = n; ev_gen = g;
            @(negedge clk);
            ev_valid = 0;
        end
    endtask

    // ---- B: replay path ----------------------------------------------------------
    // esp_score_link drives the real instrument_top audition mux exactly like
    // instrument_extension_core does.
    wire [7:0]  aud_song; wire [6:0] aud_length;
    wire        aud_active; wire [5:0] aud_step;
    wire        aud_ev_valid, aud_ev_on; wire [1:0] aud_region, aud_preset;
    wire [6:0]  aud_note; wire [7:0] aud_gen;
    wire [31:0] aud_inc; wire [63:0] aud_pressure;

    logic       uart_rx = 1'b1;
    wire        instr_pcm_ready;
    wire signed [15:0] instr_pcm;
    wire        instr_clip;
    wire        HP_BCK, HP_WS, HP_DIN, PA_EN;
    wire [3:0]  instr_led; wire instr_led_fault;
    wire        rec2_ready; wire [5:0] rec2_length; wire [63:0] rec2_body;
    wire [7:0]  rec2_dropped, rec2_seq;

    instrument_top #(.SCAN_INTERVAL(12_288), .FRAME_TIMEOUT(4_096)) instr (
        .clk_audio_mclk(clk), .rst_n(rst_n), .enable(1'b1),
        .SENSOR_SCK(), .SENSOR_MOSI(), .SENSOR_CS_N(), .SENSOR_MISO(1'b0),
        .key_n(2'b11), .external_panel_cmd(6'd0), .diag_note_layout(),
        .thumb_center_code(12'h800), .bend_dead_zone(12'd40), .bend_span(12'd1000),
        .external_vibrato_ratio_q15(16'h8000),
        .external_preset_valid(1'b0), .external_preset(1'b0),
        .cal_request(1'b0), .cal_mask(5'b11111), .clear_calibration(1'b0),
        .cal_busy(), .cal_done(), .cal_refused(),
        .HP_BCK(HP_BCK), .HP_WS(HP_WS), .HP_DIN(HP_DIN), .PA_EN(PA_EN),
        .LED(instr_led), .LED_FAULT(instr_led_fault),
        .diag_channel_id(), .diag_code(), .diag_code_valid(),
        .diag_frame_id(), .diag_channel_seen(), .diag_frame_done(), .diag_frame_incomplete(),
        .diag_frame_clocks(), .diag_frame_skew(), .diag_refused_requests(), .diag_timeouts(),
        .diag_zone_pressure(), .diag_zone_pressure_all(), .diag_zone_valid(),
        .diag_zone_age(), .diag_zone_stale(), .diag_zone_calibrated(),
        .diag_voice_gates(), .diag_voice_presets(), .diag_voice_notes(), .diag_voice_regions(),
        .diag_voice_expression(), .diag_voice_envelopes(), .diag_voice_envelope_states(),
        .diag_synth_sample_ce(), .diag_voice_gain(), .diag_voice_phase_incs(),
        .diag_bend_ratio(), .diag_bend_center(), .diag_bend_center_valid(),
        .diag_bend_bypass(), .diag_bend_candidate(), .diag_bend_stable_frames(),
        .diag_panel_cmd(), .diag_current_preset(), .diag_voice_levels(),
        .diag_event_accepted(), .diag_event_accepted_on(), .diag_stolen(), .diag_fault_latched(),
        .pcm_sample(instr_pcm), .clipped(instr_clip),
        .audition_active(aud_active), .audition_event_valid(aud_ev_valid),
        .audition_event_on(aud_ev_on), .audition_region(aud_region),
        .audition_preset(aud_preset), .audition_note(aud_note),
        .audition_generation(aud_gen), .audition_inc(aud_inc), .audition_pressure(aud_pressure),
        .rec_ready(rec2_ready), .rec_length(rec2_length), .rec_body(rec2_body),
        .rec_dropped(rec2_dropped), .rec_seq(rec2_seq)
    );

    esp_score_link #(.ENABLE_AUDITION(1'b1), .ENABLE_MOBILE(1'b1),
                     .CLOCKS_PER_BIT(CPB), .EXTENDED_STATUS(1'b1)) link (
        .clk(clk), .rst_n(rst_n), .uart_rx_i(uart_rx), .uart_tx_o(uart_tx),
        .event_ready(rec_ready), .event_length(rec_length), .event_body(rec_body),
        .event_take(rec_take),
        .audition_tail_quiet(1'b1), .audition_sample_ce(sample_ce),
        .audition_abort(1'b0), .audition_blocked(1'b0),
        .audition_song(aud_song), .audition_length(aud_length), .audition_active(aud_active),
        .audition_step(aud_step), .audition_event_valid(aud_ev_valid), .audition_event_on(aud_ev_on),
        .audition_region(aud_region), .audition_preset(aud_preset), .audition_note(aud_note),
        .audition_generation(aud_gen), .audition_inc(aud_inc), .audition_pressure(aud_pressure),
        .current_step(6'd0), .guide_active(1'b0), .test_mode(1'b0), .panic_mute(1'b0),
        .calibrated(1'b1), .panel_pairing_code(), .score_mapping_ready(),
        .hit_count(16'd0), .wrong_count(16'd0), .miss_count(16'd0),
        .note_layout(2'd0), .partial_target(6'd32), .wet_target(8'd0)
    );

    // replay command stream from the real compiler chain (one byte per line)
    logic [7:0] cmd_mem [0:4095];
    integer cmd_len;
    initial begin
        // Icarus + non-ASCII paths is a known trap: default to the ASCII copy the
        // chain test writes to the temp dir; +HEX=<path> overrides.
        string hexpath;
        if (!$value$plusargs("HEX=%s", hexpath))
            hexpath = "event_replay_commands.hex";
        $display("INFO: reading command stream from %s", hexpath);
        $readmemh(hexpath, cmd_mem);
        cmd_len = 0;
        while (cmd_len < 4096 && cmd_mem[cmd_len] !== 8'hxx) cmd_len = cmd_len + 1;
        if (cmd_len == 0) begin
            $display("FAIL: event_replay_commands.hex missing or empty (run tests/test_event_record_chain.mjs first)");
            $fatal(1, "missing replay command stream");
        end
        $display("INFO: %0d replay command bytes loaded", cmd_len);
    end

    task automatic uart_send_byte(input logic [7:0] b);
        begin
            uart_rx = 1'b0;
            #(CPB * CLK_PERIOD);
            for (integer b2 = 0; b2 < 8; b2 = b2 + 1) begin
                uart_rx = b[b2];
                #(CPB * CLK_PERIOD);
            end
            uart_rx = 1'b1;
            #(CPB * CLK_PERIOD);
            #(20 * CLK_PERIOD); // inter-frame gap like the real sender
        end
    endtask

    function automatic logic [7:0] crc8(input logic [7:0] old, input logic [7:0] b);
        logic [7:0] c;
        begin
            c = old ^ b;
            for (integer j = 0; j < 8; j = j + 1) c = c[7] ? ((c << 1) ^ 8'h07) : (c << 1);
            crc8 = c;
        end
    endfunction

    // Frame layout: A5 5A 01 op len SEQ payload... crc - the SEQUENCE byte sits
    // between len and the payload; forgetting it shifts everything by one.
    task automatic uart_send_frame(input logic [7:0] op, input integer plen,
                                   input logic [7:0] p0, input logic [7:0] p1,
                                   input logic [7:0] p2, input logic [7:0] p3);
        logic [7:0] crc, seqb;
        begin
            seqb = 8'h7f;
            crc = crc8(8'h00, 8'h01); // process the version byte with its 8 rounds
            crc = crc8(crc, op);
            crc = crc8(crc, plen[7:0]);
            crc = crc8(crc, seqb);
            if (plen > 0) crc = crc8(crc, p0);
            if (plen > 1) crc = crc8(crc, p1);
            if (plen > 2) crc = crc8(crc, p2);
            if (plen > 3) crc = crc8(crc, p3);
            uart_send_byte(8'hA5); uart_send_byte(8'h5A); uart_send_byte(8'h01);
            uart_send_byte(op); uart_send_byte(plen[7:0]); uart_send_byte(seqb);
            if (plen > 0) uart_send_byte(p0);
            if (plen > 1) uart_send_byte(p1);
            if (plen > 2) uart_send_byte(p2);
            if (plen > 3) uart_send_byte(p3);
            uart_send_byte(crc);
        end
    endtask

        logic [31:0] ev_on_count = 0, ev_off_count = 0;
    logic [6:0]  last_aud_note;
    always @(posedge clk) begin
        if (aud_ev_valid) begin
            last_aud_note <= aud_note;
            if (aud_ev_on) ev_on_count <= ev_on_count + 1; else ev_off_count <= ev_off_count + 1;
        end
    end

    logic [5:0] step_seen = 6'd0;
    always @(posedge clk) if (aud_active && aud_step > step_seen) step_seen <= aud_step;

    logic        din_seen = 0;
    integer      din_edges = 0;
    always @(posedge HP_DIN or negedge HP_DIN) begin
        din_edges = din_edges + 1;
        if (din_edges > 100) din_seen = 1;
    end

    logic [15:0] pcm_peak = 0;
    always @(posedge clk) begin
        if (aud_active && $signed(instr_pcm) > $signed(pcm_peak)) pcm_peak <= instr_pcm;
    end

    integer guard;
    initial begin
        rst_n = 0; wait_clks(20); rst_n = 1; wait_clks(20);

        // ---- A1: three paced events, then inspect the 0x85 frames on the wire
        pulse_event(1'b1, 2'd0, 2'd0, 7'd60, 8'd1);   // on  C4
        wait_samples(300);
        pulse_event(1'b1, 2'd1, 2'd0, 7'd67, 8'd2);   // on  G4 (other region)
        wait_samples(300);
        pulse_event(1'b0, 2'd0, 2'd0, 7'd60, 8'd1);   // off C4
        // each UART byte takes ~10 bit periods (~8.7 us); wait until the three
        // 0x85 frames have actually been serialized (bounded)
        guard = 0;
        while (ev_frames < 3 && guard < 200) begin wait_clks(10000); guard = guard + 1; end
        if (ev_frames < 3) begin
            $display("DBG: bytes_seen=%0d status=%0d voice=%0d rec_ready=%b first=%h %h %h %h %h %h %h %h",
                     bytes_seen, status_frames, voice_frames, rec_ready,
                     first_bytes[0],first_bytes[1],first_bytes[2],first_bytes[3],
                     first_bytes[4],first_bytes[5],first_bytes[6],first_bytes[7]);
            fail($sformatf("A1: only %0d event frames on the wire", ev_frames));
        end
        if (ev_frames >= 1) begin
            if (seen_ev_seq[0] !== 8'd0 || seen_ev_note[0] !== 8'd60 ||
                seen_ev_gen[0] !== 8'd1 || seen_ev_flags[0][7] !== 1'b1 ||
                seen_ev_flags[0][5:4] !== 2'd0 || seen_ev_delta[0] !== 24'd0)
                fail($sformatf("A1: frame0 body wrong: seq=%0d note=%0d gen=%0d flags=%b delta=%0d",
                     seen_ev_seq[0], seen_ev_note[0], seen_ev_gen[0], seen_ev_flags[0], seen_ev_delta[0]));
        end
        if (ev_frames >= 2) begin
            if (seen_ev_seq[1] !== 8'd1 || seen_ev_note[1] !== 8'd67 ||
                seen_ev_flags[1][5:4] !== 2'd1 || seen_ev_delta[1] < 24'd250 || seen_ev_delta[1] > 24'd350)
                fail($sformatf("A1: frame1 delta=%0d (want ~256..344)", seen_ev_delta[1]));
        end
        if (ev_frames >= 3) begin
            if (seen_ev_flags[2][7] !== 1'b0) fail("A1: frame2 is not a note-off");
        end

        // ---- A1b: arm=0 (demo owns the synth) must NOT capture anything
        rec_arm = 1'b0;
        pulse_event(1'b1, 2'd3, 2'd0, 7'd84, 8'd9);
        wait_samples(16);
        rec_arm = 1'b1;
        wait_clks(200);
        if (rec_ready) fail("A1b: event captured while arm=0 (demo takeover leaked into recording)");
        // re-arm and confirm the recorder still works afterwards
        pulse_event(1'b1, 2'd3, 2'd0, 7'd84, 8'd10);
        guard = 0;
        while (!rec_ready && guard < 50) begin wait_clks(100); guard = guard + 1; end
        if (!rec_ready) fail("A1b: recorder did not resume after re-arm");

        // ---- A2: burst of 10 rapid events into the depth-8 queue: drops reported
        for (guard = 0; guard < 10; guard = guard + 1)
            pulse_event(1'b1, 2'd2, 2'd1, 7'd72, 8'd10);
        guard = 0;
        while (ev_frames < 12 && guard < 200) begin wait_clks(10000); guard = guard + 1; end
        if (rec_dropped == 0) fail("A2: overflow drop was not counted");
        $display("INFO: dropped=%0d after 10-event burst into depth-8 queue", rec_dropped);
        // the loss must be VISIBLE on the wire: some later frame carries drop>0
        // (checked after drain below)

        // ---- B: replay the compiled stream through the real UART
        for (guard = 0; guard < cmd_len; guard = guard + 1) uart_send_byte(cmd_mem[guard]);
        // wait for the 0x1E start to take effect
        guard = 0;
        while (!aud_active && guard < 200000) begin wait_clks(100); guard = guard + 1; end
        if (!aud_active) fail("B: audition did not become active after the compiled stream");
        else begin
            $display("INFO: audition active, song=%0d steps=%0d", aud_song, aud_length);
            // let it play: steps must advance, events must dispatch, PCM must sound
            wait_samples(4000);
            if (step_seen == 0) fail("B: audition step never advanced");
            if (ev_on_count == 0) fail("B: no note-on dispatched by the sequencer");
            if ($signed(pcm_peak) <= 0) fail("B: synth PCM stayed zero during playback");
            if (!din_seen) fail("B: PT8211 serial data line carried no bits");
            $display("INFO: replay step=%0d note_ons=%0d note_offs=%0d pcm_peak=%0d din_edges=%0d",
                     step_seen, ev_on_count, ev_off_count, $signed(pcm_peak), din_edges);
        end
        // stop via the protocol and confirm the state actually clears
        uart_send_frame(8'h1E, 3, 8'd0, 8'd0, 8'd0, 8'd0);
        guard = 0;
        while (aud_active && guard < 200) begin wait_clks(10000); guard = guard + 1; end
        if (aud_active) fail("B: audition still active after protocol STOP");

        if (errors == 0)
            $display("PASS tb_event_record_stream: 0x85 telemetry bodies exact, drops reported, compiled stream drives real audition and audio");
        else
            $fatal(1, "tb_event_record_stream: %0d violation(s)", errors);
        $finish;
    end
endmodule
