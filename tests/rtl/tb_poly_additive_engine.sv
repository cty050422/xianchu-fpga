// GREEN bench T1.2/T1.3/T1.8: poly_additive_engine against the independent integer
// reference (09_最终优化/model/poly_reference.py, no shared code with the RTL).
//
// Protocol (mirrors the reference exactly):
//   * line[n] of stimulus_poly.mem is what the engine sees at the sample_ce of sample n.
//     The bench loads line[n] into its stimulus registers at the update point of window
//     n-1 (tick 8) and pulses accepted_on for exactly one clock there.
//   * At tick 240 of window n (after the ~196-clock schedule, before the next ce) the bench
//     compares lane_pcm against expected_poly.mem line n for ALL FOUR voices.
//
// Structural gates (T1.4/T1.8): no lane_overrun ever (196-clock schedule fits 256),
// commit latency <= 224 clocks, 55 Hz note reports 32/32 partials, silent windows are
// exactly zero, grant_count matches the scripted note-ons.
`timescale 1ns/1ps
module tb_poly_additive_engine;
    localparam realtime CLK_PERIOD = 81.380208333;
    localparam integer NSAMPLES   = 1100;

    logic clk = 0, rst_n = 0;
    always #(CLK_PERIOD/2.0) clk = ~clk;

    logic        sample_ce;
    logic [7:0]  tick_cnt = 0;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) tick_cnt <= 0;
        else begin
            if (tick_cnt == 255) tick_cnt <= 0; else tick_cnt <= tick_cnt + 1;
            sample_ce <= (tick_cnt == 254);
        end
    end

    // ---- stimulus playback -----------------------------------------------------
    logic [279:0] stim_line [0:NSAMPLES-1];
    logic [63:0]  exp_line  [0:NSAMPLES-1];
    logic [63:0]  exp_word;
    initial begin
        $readmemh("stimulus_poly.mem", stim_line);
        $readmemh("expected_poly.mem", exp_line);
    end

    // field extraction: [0]=force, [6:1]=ptarget, [10:7]=accept, voice v at 11+67*v
    logic [3:0]  s_gates;
    logic [63:0] s_env, s_expr;
    logic [127:0] s_inc;
    logic [7:0]  s_presets;
    logic [3:0]  s_accept;
    logic [5:0]  s_ptarget;
    logic        s_force;
    logic [279:0] held;
    integer play_idx = 0;
    always_comb begin
        held      = stim_line[play_idx];
        s_force   = held[0];
        s_ptarget = held[6:1];
        s_accept  = held[10:7];
        for (integer v = 0; v < 4; v = v + 1) begin
            s_gates[v]           = held[11 + 67*v + 66];
            s_env[16*v +: 16]    = held[11 + 67*v + 65 -: 16];
            s_expr[16*v +: 16]   = held[11 + 67*v + 49 -: 16];
            s_inc[32*v +: 32]    = held[11 + 67*v + 33 -: 32];
            s_presets[2*v +: 2]  = held[11 + 67*v + 1 -: 2];
        end
    end

    logic [3:0]  accept_pulse = 0;
    logic [3:0]  voice_gates = 0;
    logic [63:0] voice_envelopes = 0, voice_expression = 0;
    logic [127:0] voice_phase_incs = 0;
    logic [7:0]  voice_presets = 0;
    logic [5:0]  partial_target = 6'd32;
    logic        force_free = 0;

    // update point: tick 8 of window n loads line[n+1]; accepted_on pulses one clock
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            play_idx        <= 0;
            accept_pulse    <= 0;
            voice_gates     <= 0;
            voice_envelopes <= 0;
            voice_expression<= 0;
            voice_phase_incs<= 0;
            voice_presets   <= 0;
            partial_target  <= 6'd32;
            force_free      <= 0;
        end else begin
            accept_pulse <= 1'b0; // default: single-clock pulse
            if (tick_cnt == 8'd210) begin
                voice_gates      <= s_gates;
                voice_envelopes  <= s_env;
                voice_expression <= s_expr;
                voice_phase_incs <= s_inc;
                voice_presets    <= s_presets;
                partial_target   <= s_ptarget;
                force_free       <= s_force;
                accept_pulse     <= s_accept;
                if (play_idx < NSAMPLES - 1) play_idx <= play_idx + 1;
            end
        end
    end

    // ---- DUT -------------------------------------------------------------------
    logic [63:0] lane_pcm;
    logic [23:0] voice_partials;
    logic [31:0] voice_gains, voice_generation;
    logic [3:0]  voice_note_active;
    logic [15:0] grant_count;
    logic        budget_violation;
    logic [255:0] diag_lane0, diag_lane1;

    poly_additive_engine dut (
        .clk(clk), .rst_n(rst_n), .sample_ce(sample_ce),
        .voice_gates(voice_gates), .voice_expression(voice_expression),
        .voice_envelopes(voice_envelopes), .voice_phase_incs(voice_phase_incs),
        .voice_presets(voice_presets),
        .accepted_on(accept_pulse), .event_accepted(4'd0), .stolen(4'd0),
        .force_free(force_free), .partial_target(partial_target),
        .lane_pcm(lane_pcm), .voice_partials(voice_partials),
        .voice_gains(voice_gains), .voice_generation(voice_generation),
        .voice_note_active(voice_note_active), .grant_count(grant_count),
        .budget_violation(budget_violation),
        .diag_lane0(diag_lane0), .diag_lane1(diag_lane1)
    );

    // ---- checks ----------------------------------------------------------------
    integer errors = 0;
    integer sample_n = -1; // index of the window currently being checked
    integer worst_latency = 0;
    integer latency_start = 0;
    integer measured_cycles=0;
    always @(posedge clk) measured_cycles<=measured_cycles+1;
    logic   lane0_busy_last = 0;

    // probe: what the engine actually sees at each ce edge (the DUT samples these
    // registers with their pre-edge values at the same posedge)
    always @(posedge clk) begin
        if (rst_n && tick_cnt == 8'd210 && sample_n >= 5 && sample_n <= 11)
            $display("LOAD sn=%0d play=%0d loads_env=%h", sample_n, play_idx, s_env[15:0]);
        if (rst_n && sample_ce && sample_n >= 6 && sample_n <= 12)
            $display("CE sn=%0d env0=%h expr0=%h acc0=%b pt=%0d inc0=%h", sample_n,
                     voice_envelopes[15:0], voice_expression[15:0], accept_pulse,
                     partial_target, voice_phase_incs[31:0]);
    end

    always @(posedge clk) begin
        if (rst_n) begin
            if (sample_ce) begin
                sample_n <= sample_n + 1;
                latency_start <= measured_cycles;
            end
            // lane0 idle edge: measure schedule length
            if (lane0_busy_last && !diag_lane0[3]) begin
                if (measured_cycles-latency_start > worst_latency)
                    worst_latency = measured_cycles-latency_start;
            end
            lane0_busy_last <= diag_lane0[3];
            if (budget_violation) begin
                errors = errors + 1;
                $fatal(1, "T1.8 budget: lane_overrun pulsed at sample %0d", sample_n);
            end
        end
    end

    // golden compare at tick 240
    always @(posedge clk) begin
        if (rst_n && tick_cnt == 8'd240 && sample_n >= 0 && sample_n < NSAMPLES) begin
            if (sample_n >= 58 && sample_n <= 62)
                $display("DBG n=%0d lane0: inc_latch=%h acc=%h wsel=%h phase=%h used=%0d pcm=%h_%h",
                         sample_n, diag_lane0[131:100], diag_lane0[67:44], diag_lane0[187:180],
                         diag_lane0[163:132], diag_lane0[19:14], lane_pcm[15:0], lane_pcm[31:16]);
            if (sample_n >= 8 && sample_n <= 14)
                $display("DBG n=%0d stim_seen=%h dut_pcm=%h_%h_%h_%h dut_gain=%h dut_partials=%h ref=%h",
                         sample_n, stim_line[sample_n][67 +: 67], lane_pcm[15:0], lane_pcm[31:16],
                         lane_pcm[47:32], lane_pcm[63:48], voice_gains[7:0], voice_partials[5:0],
                         exp_line[sample_n]);
            // copy the word first and compare with CONSTANT part-selects: Icarus
            // mis-elaborates variable part-selects on words inside process loops
            // Icarus mis-elaborates part-selects on words inside this process (they can
            // read stale/zero slices); compare with whole-word masks only.
            exp_word = exp_line[sample_n];
            if (lane_pcm !== exp_word) begin
                if      ((lane_pcm & 64'h000000000000FFFF) !== (exp_word & 64'h000000000000FFFF))
                    $fatal(1, "T1.3 golden mismatch voice 0 sample %0d: dut_word=%h ref_word=%h", sample_n, lane_pcm, exp_word);
                else if ((lane_pcm & 64'h00000000FFFF0000) !== (exp_word & 64'h00000000FFFF0000))
                    $fatal(1, "T1.3 golden mismatch voice 1 sample %0d: dut_word=%h ref_word=%h", sample_n, lane_pcm, exp_word);
                else if ((lane_pcm & 64'h0000FFFF00000000) !== (exp_word & 64'h0000FFFF00000000))
                    $fatal(1, "T1.3 golden mismatch voice 2 sample %0d: dut_word=%h ref_word=%h", sample_n, lane_pcm, exp_word);
                else
                    $fatal(1, "T1.3 golden mismatch voice 3 sample %0d: dut_word=%h ref_word=%h", sample_n, lane_pcm, exp_word);
            end
        end
    end

    // exact zero while nothing sounds (before the first note-on at sample 10)
    always @(posedge clk) begin
        if (rst_n && tick_cnt == 8'd240 && sample_n >= 4 && sample_n <= 8) begin
            if (lane_pcm !== 64'd0)
                $fatal(1, "T1.8 exact-zero: silent window sample %0d shows %h", sample_n, lane_pcm);
        end
    end

    // 55 Hz sustained voice0 must report all 32 partials (windows 40..200, ptarget=32)
    always @(posedge clk) begin
        if (rst_n && tick_cnt == 8'd240 && sample_n >= 40 && sample_n <= 200) begin
            if (voice_partials[5:0] !== 6'd32)
                $fatal(1, "T1.2 partials: voice0 55 Hz reports %0d at sample %0d (expected 32)",
                       voice_partials[5:0], sample_n);
        end
    end

    initial begin
        rst_n = 0;
        repeat (10) @(posedge clk);
        // line[0] is loaded by the first tick-8 event, which occurs in the lead-in
        // before the first sample_ce; the engine therefore sees line[n] at ce n.
        rst_n = 1;
    end

    // watchdog + summary
    initial begin
        #2_500_000_000;
        $fatal(1, "tb_poly_additive_engine: watchdog timeout");
    end

    always @(posedge clk) begin
        if (rst_n && sample_n == NSAMPLES - 1 && tick_cnt == 8'd250) begin
            if (grant_count !== 16'd6)
                $fatal(1, "T1.2 grants: grant_count=%0d (expected 6 scripted note-ons)", grant_count);
            if (worst_latency > 224)
                $fatal(1, "T1.4 schedule: worst lane latency %0d clocks exceeds 224", worst_latency);
            $display("PASS tb_poly_additive_engine: %0d samples x 4 voices golden-compared, grants=%0d, worst lane latency=%0d clocks, no overrun",
                     NSAMPLES, grant_count, worst_latency);
            $finish;
        end
    end
endmodule
