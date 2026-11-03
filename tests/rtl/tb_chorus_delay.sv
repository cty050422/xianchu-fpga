`timescale 1ns/1ps
// ============================================================================
// sim/tb_chorus_delay.sv -- self-checking testbench for the block-RAM version
// of rtl/chorus_delay.sv.
//
// Every expected number below is derived HERE, from the documented pointer
// arithmetic, the documented LFO counter and the documented fill window; the
// delay line of the DUT is never read back to build an expectation, and the DUT
// is never compared against a second copy of itself with the same stimulus
// unless that comparison is the point (chorus tap vs. fixed tap).
//
//   * wr_ptr holds the slot written on the current sample and advances once per
//     sample, so sample index k of a run is written at address k (mod DEPTH).
//   * The tap address is rd_addr = wr_ptr_nxt - delay - 1 with wr_ptr_nxt =
//     wr_ptr + 1, and the read data is REGISTERED, so the output of sample n
//     mixes the value written at index n - 1 - delay(n-1).  A sample written at
//     index k reappears at output index k + delay + 1: TAP_OFF = DEPTH/2 + 1 for
//     the fixed tap (the registered read is the '+1').  An impulse injected at
//     index INJ echoes at INJ + TAP_OFF and nowhere else.
//   * LFO (the P06 fix): phase(n+1) = (phase(n) + LFO_STEP) mod 2^LFO_W with
//     phase(0) = 0 and LFO_W = 26 by default.  The direction is the TOP bit of the
//     counter and the magnitude is the MOD_W bits directly below it, so one counter
//     wrap is one triangle cycle and
//         f_lfo = LFO_STEP * Fs / 2^LFO_W,   T = 2^LFO_W / LFO_STEP samples,
//     with Fs = 12.288 MHz / 256 = 48 kHz.  The offset always lies in
//     0 .. MOD_DEPTH-1, so delay(n) = DEPTH/2 + offset(n) is never below DEPTH/2
//     (the modulated tap can only lag the fixed tap, never lead it).
//   * The LFO rate is MEASURED three ways and every measurement is printed:
//       1. the phase register increment itself (legacy LFO_SHIFT = 10 -> 1024 and
//          the module default LFO_STEP = 699), converted to Hz with the formula;
//       2. the samples between two changes of the tap offset, which give the half
//          period MOD_DEPTH * step and therefore f_lfo (module defaults);
//       3. the sample indices of the tap maximum and of the next tap minimum, i.e.
//          half a triangle period counted directly from the tap movement, on an
//          instance whose LFO runs at 1.85988 Hz so a whole ramp fits in one run.
//     Every one of them must land inside 0.2 .. 2 Hz, which is exactly the defect
//     the P06 fix removes: the old LFO_W = clog2(MOD_DEPTH)+1 = 7 with LFO_STEP =
//     10 wrapped every 12.8 samples and ran at 1.875 kHz, inside the audio band.
//   * Fill window: FILL_TARGET = DEPTH + MAX_DELAY + 2 writes, with
//     MAX_DELAY = DEPTH/2 + MOD_DEPTH - 1.  ready is 0 for the first FILL_TARGET
//     samples of a run -- and the output is then exactly the dry input in every
//     mode, including the wet ones -- and 1 from sample FILL_TARGET on.
//   * Peak meter: a 256 sample window whose boundary restarts the maximum from
//     the current sample; this testbench runs its own counter/maximum model and
//     compares it with the DUT sample by sample.
//   * Saturation: dry and wet are added with one bit of headroom and clamped, so
//     +32767 plus a positive wet term must read +32767 (a wrapping adder would
//     read a negative number) and clip_count must advance exactly once per
//     saturated output sample.
//   * Feedback: what is written back is saturate(pcm_in + (wet >>> 1)), so the
//     value travelling in the loop is 32767 >>> m after m reads and the audible
//     echo is that value shifted down by MIX_SHIFT; mode 3 uses the moving tap,
//     so the echo TIMES have no closed form and the run is checked against a
//     TB-side software model of the same documented contract.
//
// All progress lines are printed with an INFO prefix; exactly one line starts
// with "PASS ", and it is printed only after every case has passed.  Failures stop
// the run with $fatal(1, ...).
//
// The RTL PCM this effect really produces is captured for the offline evidence
// chain by sim/tb_extension_pcm_capture.sv, which mirrors the config-D
// instantiation and is analysed by model/analyze_chorus_sidebands.py.
// STATUS: only RTL simulation is verified by this testbench; synthesis,
// place & route and hardware are NOT verified.
// ============================================================================
module tb_chorus_delay;
    // ---- small line: the same arithmetic, cheap to run to the fill window ---
    localparam integer DEPTH_S = 128;
    localparam integer MODS_S  = 16;
    localparam integer MIX_S   = 2;

    // ---- LFO parameters ----------------------------------------------------
    // Module defaults after the P06 fix: LFO_W = 26, LFO_STEP = 699
    // -> f_lfo = 699 * 48000 / 2^26 = 0.499964 Hz.
    localparam integer LFO_W_DEF    = 26;
    localparam integer LFO_STEP_DEF = 699;
    // The legacy knob config D passes: LFO_SHIFT = 10 -> LFO_STEP = 1024
    // -> f_lfo = 0.73242 Hz (still inside 0.2 .. 2 Hz).
    localparam integer LFO_SHIFT_LEGACY = 10;
    localparam integer LFO_STEP_LEGACY  = 1 << LFO_SHIFT_LEGACY;
    // A faster but still compliant LFO for the sweep instance:
    // 2600 * 48000 / 2^26 = 1.85988 Hz, half period 2^25/2600 = 12905.6 samples.
    localparam integer LFO_STEP_FAST = 2600;

    // ---- the module defaults, used for the reset and fill-window checks -----
    localparam integer DEPTH_D = 2048;
    localparam integer MODS_D  = 64;
    localparam integer MIX_D   = 2;

    localparam integer FIX_S    = DEPTH_S / 2;                              // 64
    localparam integer MAXD_S   = FIX_S + MODS_S - 1;                       // 79
    localparam integer FILL_S   = DEPTH_S + MAXD_S + 2;                     // 209
    localparam integer FILL_D   = DEPTH_D + (DEPTH_D / 2 + MODS_D - 1) + 2; // 3137
    localparam integer TAP_OFF  = FIX_S + 1;                                // 65
    localparam integer MODW_S   = $clog2(MODS_S);                           // 4
    localparam integer CE_CLOCKS = 256;      // 12.288 MHz / 256 = 48 kHz
    localparam integer PEAK_WIN  = 256;

    // ---- sweep instance: DEPTH = 256, MOD_DEPTH = 16, fast in-band LFO -----
    localparam integer DEPTH_W = 256;
    localparam integer MODS_W  = 16;
    localparam integer MIX_W   = 2;
    localparam integer FIX_W   = DEPTH_W / 2;              // 128
    localparam integer MAXD_W  = FIX_W + MODS_W - 1;       // 143
    localparam integer FILL_W  = DEPTH_W + MAXD_W + 2;     // 401
    localparam integer MODW_W  = $clog2(MODS_W);           // 4
    localparam integer SWEEP_PERIOD = 2048;   // bounded saw stimulus, no saturation
    // The first tap maximum of the fast instance is at sample 12099 and the first
    // tap minimum after it at 25005, so 25200 samples contain a full half period.
    localparam integer SWEEP_SAMPLES = 25200;

    // ---- module-default LFO instance (short line, real default parameters) --
    localparam integer DEPTH_L = 256;
    localparam integer MODS_L  = 64;
    localparam integer FILL_L  = DEPTH_L + (DEPTH_L / 2 + MODS_L - 1) + 2;  // 449
    // 8 tap-offset changes of the default LFO need 8 * 2^19/699 = 6001 samples.
    localparam integer LFO_SLOPE_SAMPLES = 7200;

    localparam logic [1:0] MODE_BYPASS   = 2'd0;
    localparam logic [1:0] MODE_FIXED    = 2'd1;
    localparam logic [1:0] MODE_CHORUS   = 2'd2;
    localparam logic [1:0] MODE_FEEDBACK = 2'd3;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic sample_ce;
    logic signed [15:0] pcm_in = 16'sd0;

    // 12.288 MHz: half a period is 40.69 ns, exact at the 1 ps timescale.
    always #40.69 clk = ~clk;

    // The same 256-clock sample enable the board design uses.
    audio_sample_tick_div256 tick (
        .clk(clk), .rst_n(rst_n), .sample_ce(sample_ce)
    );

    logic [1:0] mode_d = MODE_BYPASS;

    logic signed [15:0] out_byp, out_fix, out_mod, out_fb, out_dry, out_def;
    logic signed [15:0] out_sweep, out_sweep_fix, out_lfo;
    logic [15:0] peak_byp, peak_def;
    logic [15:0] clip_byp, clip_fix, clip_fb, clip_dry, clip_def;
    logic [15:0] bypc_byp, bypc_def;
    logic ready_byp, ready_fix, ready_mod, ready_fb, ready_dry, ready_def;
    logic ready_sweep, ready_sweep_fix, ready_lfo;

    // Short 128-sample line (fill window 209 samples): every wet-mode case can
    // be run past ready without a long simulation.  These instances use the LEGACY
    // LFO knob (LFO_SHIFT = 10 -> step 1024 -> 0.73242 Hz), which is what
    // rtl/instrument_extension_core.sv passes in config D, so the backward-
    // compatible path is elaborated and exercised here as well.
    chorus_delay #(.DEPTH(DEPTH_S), .MOD_DEPTH(MODS_S), .MIX_SHIFT(MIX_S),
                   .LFO_SHIFT(LFO_SHIFT_LEGACY)) dut_byp (
        .clk(clk), .rst_n(rst_n), .sample_ce(sample_ce), .pcm_in(pcm_in),
        .mode(MODE_BYPASS), .pcm_out(out_byp), .peak_abs(peak_byp),
        .clip_count(clip_byp), .bypass_count(bypc_byp), .ready(ready_byp)
    );
    chorus_delay #(.DEPTH(DEPTH_S), .MOD_DEPTH(MODS_S), .MIX_SHIFT(MIX_S),
                   .LFO_SHIFT(LFO_SHIFT_LEGACY)) dut_fix (
        .clk(clk), .rst_n(rst_n), .sample_ce(sample_ce), .pcm_in(pcm_in),
        .mode(MODE_FIXED), .pcm_out(out_fix), .peak_abs(),
        .clip_count(clip_fix), .bypass_count(), .ready(ready_fix)
    );
    chorus_delay #(.DEPTH(DEPTH_S), .MOD_DEPTH(MODS_S), .MIX_SHIFT(MIX_S),
                   .LFO_SHIFT(LFO_SHIFT_LEGACY)) dut_mod (
        .clk(clk), .rst_n(rst_n), .sample_ce(sample_ce), .pcm_in(pcm_in),
        .mode(MODE_CHORUS), .pcm_out(out_mod), .peak_abs(),
        .clip_count(), .bypass_count(), .ready(ready_mod)
    );
    chorus_delay #(.DEPTH(DEPTH_S), .MOD_DEPTH(MODS_S), .MIX_SHIFT(MIX_S),
                   .LFO_SHIFT(LFO_SHIFT_LEGACY)) dut_fb (
        .clk(clk), .rst_n(rst_n), .sample_ce(sample_ce), .pcm_in(pcm_in),
        .mode(MODE_FEEDBACK), .pcm_out(out_fb), .peak_abs(),
        .clip_count(clip_fb), .bypass_count(), .ready(ready_fb)
    );
    // MIX_SHIFT = 0 must be fully dry even in a wet mode.
    chorus_delay #(.DEPTH(DEPTH_S), .MOD_DEPTH(MODS_S), .MIX_SHIFT(0),
                   .LFO_SHIFT(LFO_SHIFT_LEGACY)) dut_dry (
        .clk(clk), .rst_n(rst_n), .sample_ce(sample_ce), .pcm_in(pcm_in),
        .mode(MODE_FIXED), .pcm_out(out_dry), .peak_abs(),
        .clip_count(clip_dry), .bypass_count(), .ready(ready_dry)
    );
    // Module defaults: reset behaviour, the DEPTH-dependent fill window and the
    // default LFO parameters (LFO_W = 26, LFO_STEP = 699, no legacy override).
    chorus_delay #(.DEPTH(DEPTH_D), .MOD_DEPTH(MODS_D), .MIX_SHIFT(MIX_D)) dut_default (
        .clk(clk), .rst_n(rst_n), .sample_ce(sample_ce), .pcm_in(pcm_in),
        .mode(mode_d), .pcm_out(out_def), .peak_abs(peak_def),
        .clip_count(clip_def), .bypass_count(bypc_def), .ready(ready_def)
    );
    // Moving-tap sweep, and a fixed-tap twin with the same parameters.
    chorus_delay #(.DEPTH(DEPTH_W), .MOD_DEPTH(MODS_W), .MIX_SHIFT(MIX_W),
                   .LFO_W(LFO_W_DEF), .LFO_STEP(LFO_STEP_FAST)) dut_sweep (
        .clk(clk), .rst_n(rst_n), .sample_ce(sample_ce), .pcm_in(pcm_in),
        .mode(MODE_CHORUS), .pcm_out(out_sweep), .peak_abs(),
        .clip_count(), .bypass_count(), .ready(ready_sweep)
    );
    chorus_delay #(.DEPTH(DEPTH_W), .MOD_DEPTH(MODS_W), .MIX_SHIFT(MIX_W),
                   .LFO_W(LFO_W_DEF), .LFO_STEP(LFO_STEP_FAST)) dut_sweep_fix (
        .clk(clk), .rst_n(rst_n), .sample_ce(sample_ce), .pcm_in(pcm_in),
        .mode(MODE_FIXED), .pcm_out(out_sweep_fix), .peak_abs(),
        .clip_count(), .bypass_count(), .ready(ready_sweep_fix)
    );
    // Module-default LFO on a short line: the rate of the DEFAULT parameters,
    // measured from the tap movement and from the phase register itself.
    chorus_delay #(.DEPTH(DEPTH_L), .MOD_DEPTH(MODS_L), .MIX_SHIFT(MIX_S)) dut_lfo (
        .clk(clk), .rst_n(rst_n), .sample_ce(sample_ce), .pcm_in(pcm_in),
        .mode(MODE_CHORUS), .pcm_out(out_lfo), .peak_abs(),
        .clip_count(), .bypass_count(), .ready(ready_lfo)
    );

    integer n, i, idx, gap;
    integer distinct_addr, distinct_delay, differ_mod, nonzero, sat_samples;
    integer inj, wet_idx, fix_idx, expected, expected_fix, expected_w, expected_w_fix;
    integer model_peak, model_cnt, abs_now, peak_max;
    integer ready_cnt, offset_w, t_max, t_min, half_period;
    integer phase_w, phase_w_prev, step_meas, slopes, slope_sum, prev_delay_lfo;
    integer zero_at;
    logic ready_small_now, ready_def_now, ready_w_now, ready_lfo_now;
    logic [7:0] delay_w_now, delay_lfo_now;
    logic [255:0] addr_seen, delay_seen;
    logic signed [15:0] drive;
    real f_meas, f_theory, gap_avg;

    // TB-side software reference for the mode-3 loop.  Mode 3 uses the MOVING
    // tap, so its echo positions have no closed form; the amplitude sequence is
    // checked against this model of the documented loop (registered tap read,
    // wet shifted by one into the write-back, saturating) instead.
    logic signed [15:0] ref_line [0:DEPTH_S-1];
    integer ref_wet, ref_write, ref_sum, ref_clip, first_echo;
    integer tri_phase, tri_phase_prev;

    task automatic do_reset();
        begin
            @(negedge clk);
            pcm_in = 16'sd0;
            rst_n  = 1'b0;
            repeat (6) @(negedge clk);
        end
    endtask

    // The sample enable comes from a register that reset clears, so after this
    // release the first enable is exactly 256 clocks away and the DUT sees no
    // sample before the testbench drives one: TB sample 0 == DUT sample 0.
    task automatic release_reset();
        begin
            @(negedge clk);
            rst_n = 1'b1;
        end
    endtask

    // Drive one sample and return with every DUT output settled for it.
    // The *_now values are captured just BEFORE the sampling edge, so they are the
    // ready flags and tap delays the DUT used for this very sample; the tap and read
    // address of the sweep instance are recorded for the coverage counters.
    task automatic sample(input logic signed [15:0] value);
        begin
            @(negedge clk);
            while (!sample_ce) @(negedge clk);
            pcm_in          = value;
            ready_small_now = ready_fix;
            ready_def_now   = ready_def;
            ready_w_now     = ready_sweep;
            delay_w_now     = dut_sweep.delay;
            ready_lfo_now   = ready_lfo;
            delay_lfo_now   = dut_lfo.delay;
            addr_seen[dut_sweep.rd_addr] = 1'b1;
            delay_seen[dut_sweep.delay]  = 1'b1;
            @(negedge clk);
        end
    endtask

    // Triangle offset of the documented wide LFO: direction = top bit of the phase
    // counter, magnitude = the $clog2(mod_depth) bits directly below it.  One counter
    // wrap is one triangle cycle, so f_lfo = LFO_STEP * Fs / 2^LFO_W.
    function automatic integer mod_offset_of(input integer phase, input integer mod_depth);
        integer p, mag, mw;
        begin
            mw  = $clog2(mod_depth);
            p   = phase % (1 << LFO_W_DEF);
            mag = (p >> (LFO_W_DEF - 1 - mw)) & (mod_depth - 1);
            if (p & (1 << (LFO_W_DEF - 1)))
                mod_offset_of = (mod_depth - 1) - mag;
            else
                mod_offset_of = mag;
        end
    endfunction

    function automatic integer popcount(input logic [255:0] value);
        integer k, total;
        begin
            total = 0;
            for (k = 0; k < 256; k = k + 1)
                if (value[k]) total = total + 1;
            popcount = total;
        end
    endfunction

    // A pattern with both rails, both extremes of the asymmetric 16-bit range
    // and small values, so bypass/dry are not proved with a trivial signal.
    function automatic logic signed [15:0] pattern(input integer k);
        begin
            case (k % 8)
                0:       pattern = 16'sd32767;
                1:       pattern = 16'sd1;
                2:       pattern = -16'sd1;
                3:       pattern = 16'sd12345;
                4:       pattern = -16'sd32768;
                5:       pattern = 16'sd0;
                6:       pattern = 16'sd23456;
                default: pattern = -16'sd23456;
            endcase
        end
    endfunction

    // 32767 >>> k for some k, i.e. one step of the halving feedback chain.
    function automatic integer is_halving(input logic signed [15:0] v);
        integer k, ok;
        begin
            ok = 0;
            for (k = 0; k < 16; k = k + 1)
                if (v === (32767 >>> k))
                    ok = 1;
            is_halving = ok;
        end
    endfunction

    initial begin
        addr_seen  = 256'd0;
        delay_seen = 256'd0;

        // ---------------- case 1: reset ------------------------------------
        do_reset();
        pcm_in = 16'sd12345;          // reset must dominate a non-zero input
        for (i = 0; i < 8; i = i + 1) begin
            @(negedge clk);
            if (out_byp !== 16'sd0 || out_fix !== 16'sd0 || out_mod !== 16'sd0 ||
                out_fb !== 16'sd0 || out_dry !== 16'sd0 || out_def !== 16'sd0)
                $fatal(1, "reset: pcm_out is not zero while rst_n is low (i=%0d)", i);
            if (ready_fix !== 1'b0 || ready_byp !== 1'b0 || ready_def !== 1'b0)
                $fatal(1, "reset: ready is not zero while rst_n is low (i=%0d)", i);
            if (peak_byp !== 16'd0 || clip_fix !== 16'd0 ||
                bypc_byp !== 16'd0 || bypc_def !== 16'd0)
                $fatal(1, "reset: peak_abs/clip_count/bypass_count not cleared (i=%0d)", i);
        end
        release_reset();
        sample(16'sd32767);
        if (out_fix !== 16'sd32767 || out_byp !== 16'sd32767 || out_dry !== 16'sd32767 ||
            out_mod !== 16'sd32767 || out_fb !== 16'sd32767 || out_def !== 16'sd32767)
            $fatal(1, "reset: the first sample after reset is not the dry input (fix=%0d byp=%0d def=%0d)",
                   out_fix, out_byp, out_def);
        if (ready_small_now !== 1'b0)
            $fatal(1, "reset: ready is already 1 on the first sample");
        if (clip_fix !== 16'd0 || bypc_byp !== 16'd1)
            $fatal(1, "reset: counters wrong after the first sample (clip=%0d bypass=%0d)",
                   clip_fix, bypc_byp);
        sample(-16'sd32768);          // wet modes are dry and unsaturated here
        if (out_fix !== -16'sd32768 || out_mod !== -16'sd32768 || out_fb !== -16'sd32768 ||
            out_dry !== -16'sd32768)
            $fatal(1, "reset: sample 1 is not the dry input (fix=%0d mod=%0d fb=%0d dry=%0d)",
                   out_fix, out_mod, out_fb, out_dry);
        if (ready_small_now !== 1'b0 || clip_fix !== 16'd0)
            $fatal(1, "reset: ready/clip wrong on sample 1 (ready=%b clip=%0d)",
                   ready_small_now, clip_fix);
        $display("INFO tb_chorus_delay reset: outputs and counters cleared, ready=0, wet modes bit-exactly dry at +32767/-32768");

        // ---------------- case 2: 48 kHz sample enable ---------------------
        do_reset();
        release_reset();
        @(negedge clk);
        while (!sample_ce) @(negedge clk);
        gap = 0;
        @(negedge clk);
        while (!sample_ce) begin
            @(negedge clk);
            gap = gap + 1;
        end
        if (gap != CE_CLOCKS - 1)
            $fatal(1, "sample_ce: %0d clocks between enables, expected %0d", gap + 1, CE_CLOCKS);
        $display("INFO tb_chorus_delay sample_ce: %0d clk per sample = 48 kHz at 12.288 MHz", gap + 1);

        // ---------------- case 3: the LFO rate is in the audio-safe band -----
        // Two independent readings of the phase register itself: the legacy
        // LFO_SHIFT = 10 instance and the module-default instance.
        do_reset();
        release_reset();
        phase_w      = dut_mod.lfo_phase;
        tri_phase    = dut_default.lfo_phase;
        for (i = 0; i < 8; i = i + 1) sample(16'sd0);
        step_meas = (dut_mod.lfo_phase - phase_w) % (1 << LFO_W_DEF);
        if (step_meas !== 8 * LFO_STEP_LEGACY)
            $fatal(1, "lfo: LFO_SHIFT=%0d advanced the phase by %0d in 8 samples, expected %0d",
                   LFO_SHIFT_LEGACY, step_meas, 8 * LFO_STEP_LEGACY);
        f_meas = (LFO_STEP_LEGACY * 48000.0) / (1 << LFO_W_DEF);
        if (f_meas < 0.2 || f_meas > 2.0)
            $fatal(1, "lfo: legacy LFO_SHIFT=%0d gives %f Hz, outside 0.2 .. 2 Hz", LFO_SHIFT_LEGACY, f_meas);
        step_meas = (dut_default.lfo_phase - tri_phase) % (1 << LFO_W_DEF);
        if (step_meas !== 8 * LFO_STEP_DEF)
            $fatal(1, "lfo: the default LFO advanced the phase by %0d in 8 samples, expected %0d",
                   step_meas, 8 * LFO_STEP_DEF);
        f_theory = (LFO_STEP_DEF * 48000.0) / (1 << LFO_W_DEF);
        if (f_theory < 0.2 || f_theory > 2.0)
            $fatal(1, "lfo: default LFO_STEP=%0d gives %f Hz, outside 0.2 .. 2 Hz", LFO_STEP_DEF, f_theory);
        $display("INFO tb_chorus_delay lfo_constants: LFO_W=%0d legacy LFO_SHIFT=%0d -> step %0d -> %f Hz; default LFO_STEP=%0d -> %f Hz (band 0.2 .. 2 Hz)",
                 LFO_W_DEF, LFO_SHIFT_LEGACY, LFO_STEP_LEGACY, f_meas, LFO_STEP_DEF, f_theory);

        // ---------------- case 4a: fill window on the small line ------------
        do_reset();
        release_reset();
        sat_samples = 0;
        for (n = 0; n < FILL_S + 20; n = n + 1) begin
            sample(16'sd32767);
            if (ready_small_now !== ((n >= FILL_S) ? 1'b1 : 1'b0))
                $fatal(1, "fill: sample %0d ready=%b, expected %b (FILL_TARGET=%0d)",
                       n, ready_small_now, (n >= FILL_S), FILL_S);
            if (ready_byp !== ready_fix || ready_mod !== ready_fix ||
                ready_fb !== ready_fix || ready_dry !== ready_fix)
                $fatal(1, "fill: the ready flags of identical instances disagree at sample %0d", n);
            // Full-scale dry input: before ready the output must simply repeat it,
            // from ready on the wet term makes the sum saturate at +32767.
            if (out_fix !== 16'sd32767)
                $fatal(1, "fill: sample %0d out_fix=%0d expected 32767 (dry, then clamped)", n, out_fix);
            if (out_byp !== 16'sd32767 || bypc_byp !== (n + 1))
                $fatal(1, "fill: bypass sample %0d out=%0d bypass_count=%0d expected %0d",
                       n, out_byp, bypc_byp, n + 1);
            if (ready_small_now)
                sat_samples = sat_samples + 1;
        end
        if (sat_samples !== 20)
            $fatal(1, "fill: %0d samples with ready=1, expected 20", sat_samples);
        if (clip_fix !== 16'd20)
            $fatal(1, "fill: clip_count=%0d expected exactly the 20 saturated samples", clip_fix);
        if (clip_byp !== 16'd0)
            $fatal(1, "fill: bypass mode counted %0d clips", clip_byp);
        $display("INFO tb_chorus_delay fill_window: ready=0 for %0d samples (dry, unclipped), ready=1 from sample %0d, clip_count=%0d",
                 FILL_S, FILL_S, clip_fix);

        // ---------------- case 4b: the same on the module defaults -----------
        do_reset();
        release_reset();
        for (n = 0; n < FILL_D + 8; n = n + 1) begin
            sample(16'sd0);
            if (ready_def_now !== ((n >= FILL_D) ? 1'b1 : 1'b0))
                $fatal(1, "fill(default): sample %0d ready=%b, expected %b (FILL_TARGET=%0d)",
                       n, ready_def_now, (n >= FILL_D), FILL_D);
            if (out_def !== 16'sd0)
                $fatal(1, "fill(default): sample %0d out=%0d expected 0", n, out_def);
        end
        $display("INFO tb_chorus_delay fill_window(default): DEPTH=%0d MOD_DEPTH=%0d -> ready at sample %0d, not before",
                 DEPTH_D, MODS_D, FILL_D);

        // ---------------- case 5: bypass is bit exact ------------------------
        do_reset();
        release_reset();
        for (n = 0; n < 300; n = n + 1) begin
            drive = pattern(n);
            sample(drive);
            if (out_byp !== drive)
                $fatal(1, "bypass: sample %0d out=%0d expected=%0d", n, out_byp, drive);
            if (bypc_byp !== (n + 1))
                $fatal(1, "bypass: bypass_count=%0d after %0d samples", bypc_byp, n + 1);
            if (ready_small_now !== ((n >= FILL_S) ? 1'b1 : 1'b0))
                $fatal(1, "bypass: ready=%b at sample %0d", ready_small_now, n);
        end
        if (clip_byp !== 16'd0)
            $fatal(1, "bypass: clip_count advanced to %0d", clip_byp);
        $display("INFO tb_chorus_delay bypass: 300 samples bit exact (incl. -32768), bypass_count=%0d over the fill boundary, clip_count=0",
                 bypc_byp);

        // ---------------- case 6: MIX_SHIFT = 0 is fully dry -----------------
        do_reset();
        release_reset();
        for (n = 0; n < 300; n = n + 1) begin
            drive = pattern(n + 3);
            sample(drive);
            if (out_dry !== drive)
                $fatal(1, "mix_shift=0: sample %0d out=%0d expected=%0d (wet leaked in)",
                       n, out_dry, drive);
        end
        if (clip_dry !== 16'd0)
            $fatal(1, "mix_shift=0: clip_count=%0d, the dry output cannot saturate", clip_dry);
        $display("INFO tb_chorus_delay mix_shift_0: 300 samples fully dry in a wet mode (%0d of them with ready=1)",
                 300 - FILL_S);

        // ---------------- case 7: impulse position, fixed delay --------------
        do_reset();
        release_reset();
        inj = FILL_S + 5;                 // after the fill window, so the echo is live
        nonzero = 0;
        for (n = 0; n < inj + TAP_OFF + 20; n = n + 1) begin
            sample((n == inj) ? 16'sd32767 : 16'sd0);
            if (n == inj)
                expected = 32767;                       // dry impulse
            else if (n == inj + TAP_OFF)
                expected = 32767 >>> MIX_S;             // 8191, the wet echo
            else
                expected = 0;
            if (out_fix !== expected)
                $fatal(1, "impulse: sample %0d out=%0d expected=%0d (echo predicted at %0d = INJ + DEPTH/2 + 1)",
                       n, out_fix, expected, inj + TAP_OFF);
            if (out_fix != 16'sd0)
                nonzero = nonzero + 1;
        end
        if (nonzero != 2)
            $fatal(1, "impulse: %0d non-zero samples, expected exactly 2", nonzero);
        if (clip_fix !== 16'd0)
            $fatal(1, "impulse: clip_count=%0d, nothing may saturate here", clip_fix);
        $display("INFO tb_chorus_delay impulse: dry at %0d, echo 8191 at sample %0d (= INJ + %0d), all others zero",
                 inj, inj + TAP_OFF, TAP_OFF);

        // ---------------- case 8: saturation and clip_count -----------------
        do_reset();
        release_reset();
        sat_samples = 0;
        for (n = 0; n < FILL_S + 150; n = n + 1) begin
            sample(16'sd32767);
            if (ready_small_now)
                sat_samples = sat_samples + 1;
            if (out_fix !== 16'sd32767)
                $fatal(1, "saturation(+): sample %0d out=%0d, a clamped sum must read 32767", n, out_fix);
            if (out_byp !== 16'sd32767)
                $fatal(1, "saturation(+): bypass sample %0d out=%0d", n, out_byp);
        end
        if (sat_samples !== 150)
            $fatal(1, "saturation(+): %0d saturated samples, expected 150", sat_samples);
        if (clip_fix !== 16'd150)
            $fatal(1, "saturation(+): clip_count=%0d expected exactly 150", clip_fix);
        if (clip_byp !== 16'd0)
            $fatal(1, "saturation(+): bypass mode counted %0d clips", clip_byp);
        do_reset();
        release_reset();
        for (n = 0; n < FILL_S + 150; n = n + 1) begin
            sample(-16'sd32768);
            if (out_fix !== -16'sd32768)
                $fatal(1, "saturation(-): sample %0d out=%0d expected -32768", n, out_fix);
        end
        if (clip_fix !== 16'd150)
            $fatal(1, "saturation(-): clip_count=%0d expected exactly 150", clip_fix);
        if (peak_byp !== 16'd32768)
            $fatal(1, "saturation(-): peak_abs=%0d, expected 0x8000 for -32768", peak_byp);
        $display("INFO tb_chorus_delay saturation: +32767 and -32768 stay at the rail from sample %0d on, clip_count=%0d exactly, peak_abs=0x8000",
                 FILL_S, clip_fix);

        // ---------------- case 9: 1/2 feedback amplitudes --------------------
        // What is written back is saturate(pcm_in + (wet >>> 1)), so every value
        // the loop produces is one step of the chain 32767 >>> k and the first
        // echo of a full-scale impulse is exactly 32767 >>> 2 = 8191.  Mode 3
        // has the MOVING tap, so the echo times are not equally spaced and the
        // whole run is checked against the TB reference model below.
        do_reset();
        release_reset();
        inj = FILL_S + 5;
        for (idx = 0; idx < DEPTH_S; idx = idx + 1)
            ref_line[idx] = 16'sd0;
        tri_phase      = 0;
        tri_phase_prev = 0;
        nonzero    = 0;
        ref_clip   = 0;
        first_echo = 0;
        // Phase 1: single full-scale impulse (the halving chain).  Phase 2: a
        // constant full-scale input, which drives the loop to the rail and
        // exercises the clamp of the feedback write-back as well as the output
        // clip counter in a wet mode.
        for (n = 0; n < inj + 900 + 220; n = n + 1) begin
            if (n < inj + 900)
                drive = (n == inj) ? 16'sd32767 : 16'sd0;
            else
                drive = 16'sd32767;
            // reference model: output(n) mixes the read registered at sample n-1
            if ((n >= FILL_S) && (n >= 1)) begin
                fix_idx = n - 1 - (FIX_S + mod_offset_of(tri_phase_prev, MODS_S));
                if (fix_idx < 0)
                    $fatal(1, "feedback: model read before the line was written (n=%0d)", n);
                ref_wet = ref_line[fix_idx % DEPTH_S];
            end else begin
                ref_wet = 0;                  // tap muted by the fill window
            end
            ref_sum = drive + (ref_wet >>> MIX_S);
            if (ref_sum > 32767) begin
                expected = 32767;
                ref_clip = ref_clip + 1;
            end else if (ref_sum < -32768) begin
                expected = -32768;
                ref_clip = ref_clip + 1;
            end else begin
                expected = ref_sum;
            end
            sample(drive);
            if (out_fb !== expected)
                $fatal(1, "feedback: sample %0d out=%0d, reference model says %0d",
                       n, out_fb, expected);
            if (out_fb != 16'sd0) begin
                nonzero = nonzero + 1;
                if (!is_halving(out_fb))
                    $fatal(1, "feedback: sample %0d out=%0d is not 32767 >>> k", n, out_fb);
                if ((n > inj) && (first_echo == 0)) begin
                    first_echo = n;
                    if (out_fb !== (32767 >>> MIX_S))
                        $fatal(1, "feedback: first echo at sample %0d is %0d, expected %0d",
                               n, out_fb, 32767 >>> MIX_S);
                end
            end
            // model write-back of this sample: address n (mod DEPTH)
            if (n >= FILL_S) begin
                ref_write = drive + (ref_wet >>> 1);
                if (ref_write > 32767)
                    ref_write = 32767;
                else if (ref_write < -32768)
                    ref_write = -32768;
            end else begin
                ref_write = drive;            // fill window: wet term forced to zero
            end
            ref_line[n % DEPTH_S] = ref_write[15:0];
            tri_phase_prev = tri_phase;
            tri_phase      = (tri_phase + LFO_STEP_LEGACY) % (1 << LFO_W_DEF);
        end
        if (first_echo === 0)
            $fatal(1, "feedback: the impulse produced no echo at all");
        if (nonzero < 8)
            $fatal(1, "feedback: only %0d non-zero samples", nonzero);
        if (clip_fb !== ref_clip[15:0])
            $fatal(1, "feedback: clip_count=%0d, the loop model says %0d saturated outputs",
                   clip_fb, ref_clip);
        if (ref_clip < 100)
            $fatal(1, "feedback: only %0d saturated outputs, the rail phase did not saturate", ref_clip);
        $display("INFO tb_chorus_delay feedback: %0d non-zero samples, first echo 8191 at sample %0d, every value a 32767 >>> k step, %0d saturated outputs, matched the TB loop model sample by sample",
                 nonzero, first_echo, clip_fb);

        // ---------------- case 10: peak meter ------------------------------
        do_reset();
        release_reset();
        model_peak = 0;
        model_cnt  = 0;
        peak_max   = 0;
        for (n = 0; n < 64; n = n + 1) begin
            drive   = ((n % 2) == 0) ? 16'sd32767 : -16'sd32768;
            abs_now = ((n % 2) == 0) ? 32767 : 32768;
            sample(drive);
            if (model_cnt == PEAK_WIN - 1) begin
                model_cnt  = 0;
                model_peak = abs_now;
            end else begin
                model_cnt = model_cnt + 1;
                if (abs_now > model_peak)
                    model_peak = abs_now;
            end
            if (peak_byp !== model_peak[15:0])
                $fatal(1, "peak: sample %0d peak_abs=%0d, window model says %0d",
                       n, peak_byp, model_peak);
            if (model_peak > peak_max)
                peak_max = model_peak;
        end
        if (peak_max !== 32768)
            $fatal(1, "peak: maximum %0d, expected 32768 (0x8000) for -32768", peak_max);
        for (n = 64; n < 64 + 300; n = n + 1) begin
            sample(16'sd0);
            if (model_cnt == PEAK_WIN - 1) begin
                model_cnt  = 0;
                model_peak = 0;
            end else begin
                model_cnt = model_cnt + 1;
            end
            if (peak_byp !== model_peak[15:0])
                $fatal(1, "peak: sample %0d peak_abs=%0d, window model says %0d",
                       n, peak_byp, model_peak);
        end
        if (peak_byp !== 16'd0)
            $fatal(1, "peak: %0d after 300 silent samples, the window did not self-reset", peak_byp);
        do_reset();
        if (peak_byp !== 16'd0)
            $fatal(1, "peak: %0d after reset", peak_byp);
        $display("INFO tb_chorus_delay peak: reached 0x8000, matched the %0d-sample window model sample by sample, self-reset to 0 on silence, cleared by reset",
                 PEAK_WIN);

        // ---------------- case 11: the chorus tap sweeps + LFO RATE MEASURED ---
        // One run of the fast (but still compliant) LFO instance covers the whole
        // tap range, is checked against the documented per-sample model, and gives
        // the modulation half period straight from the tap movement: the first
        // sample whose tap reaches DEPTH/2 + MOD_DEPTH - 1 and the first sample
        // after it whose tap falls back to DEPTH/2 are half a triangle apart.
        do_reset();
        release_reset();
        addr_seen  = 256'd0;
        delay_seen = 256'd0;
        differ_mod = 0;
        ready_cnt  = 0;
        t_max      = -1;
        t_min      = -1;
        phase_w       = 0;
        phase_w_prev  = 0;
        for (n = 0; n < SWEEP_SAMPLES; n = n + 1) begin
            // Independent expectation: output(n) mixes the read registered at
            // sample n-1, and sample m used delay(m) = FIX_W + offset(phase(m)).
            if (n == 0)
                wet_idx = -1;
            else
                wet_idx = n - 1 - (FIX_W + mod_offset_of(phase_w_prev, MODS_W));
            drive = n % SWEEP_PERIOD;      // 0 .. 2047: bounded, never saturates
            sample(drive);
            if (ready_w_now) begin
                if (wet_idx < 0)
                    $fatal(1, "sweep: ready at sample %0d with an unwritten tap (%0d)", n, wet_idx);
                expected_w     = drive + ((wet_idx % SWEEP_PERIOD) >>> MIX_W);
                expected_w_fix = drive + (((n - 1 - FIX_W) % SWEEP_PERIOD) >>> MIX_W);
                ready_cnt = ready_cnt + 1;
            end else begin
                expected_w     = drive;         // wet muted: pure dry
                expected_w_fix = drive;
            end
            if (out_sweep !== expected_w)
                $fatal(1, "sweep: sample %0d out=%0d expected=%0d (tap index %0d, delay %0d)",
                       n, out_sweep, expected_w, wet_idx, FIX_W + mod_offset_of(phase_w_prev, MODS_W));
            if (out_sweep_fix !== expected_w_fix)
                $fatal(1, "sweep(reference): sample %0d out=%0d expected=%0d",
                       n, out_sweep_fix, expected_w_fix);
            if (out_sweep != out_sweep_fix)
                differ_mod = differ_mod + 1;
            // tap observation: it must never lead the fixed tap, and its extremes
            // give the modulation half period directly.
            if (delay_w_now < FIX_W)
                $fatal(1, "sweep: the modulated tap led the fixed tap at sample %0d (%0d < %0d)",
                       n, delay_w_now, FIX_W);
            offset_w = delay_w_now - FIX_W;
            if (t_max < 0) begin
                if (offset_w == MODS_W - 1) t_max = n;
            end else if (t_min < 0) begin
                if (offset_w == 0) t_min = n;
            end
            phase_w_prev = phase_w;
            phase_w      = (phase_w + LFO_STEP_FAST) % (1 << LFO_W_DEF);
        end
        distinct_addr  = popcount(addr_seen);
        distinct_delay = popcount(delay_seen);
        if (t_max < 0 || t_min <= t_max)
            $fatal(1, "sweep: no LFO half period in the run (t_max=%0d t_min=%0d)", t_max, t_min);
        half_period = t_min - t_max;
        f_meas   = 48000.0 / (2.0 * half_period);
        f_theory = (LFO_STEP_FAST * 48000.0) / (1 << LFO_W_DEF);
        if (distinct_delay !== MODS_W)
            $fatal(1, "sweep: %0d distinct tap delays, expected %0d", distinct_delay, MODS_W);
        if (ready_cnt < MODS_W)
            $fatal(1, "sweep: only %0d ready samples", ready_cnt);
        if (differ_mod < (ready_cnt * 60) / 100)
            $fatal(1, "sweep: only %0d of %0d ready samples differ from the fixed tap",
                   differ_mod, ready_cnt);
        if (f_meas < 0.2 || f_meas > 2.0)
            $fatal(1, "sweep: measured f_lfo = %f Hz (half period %0d samples) is outside 0.2 .. 2 Hz",
                   f_meas, half_period);
        if ((f_meas - f_theory) > 0.03 * f_theory || (f_theory - f_meas) > 0.03 * f_theory)
            $fatal(1, "sweep: measured f_lfo = %f Hz from %0d samples is more than 3%% from the theoretical %f Hz",
                   f_meas, half_period, f_theory);
        $display("INFO tb_chorus_delay lfo_sweep: tap maximum at sample %0d, next minimum at sample %0d -> half period %0d samples -> measured f_lfo = %f Hz (theory %f Hz), %0d distinct delays of %0d, %0d read addresses, %0d/%0d ready samples differ from the fixed tap, never leads it",
                 t_max, t_min, half_period, f_meas, f_theory, distinct_delay, MODS_W,
                 distinct_addr, differ_mod, ready_cnt);

        // ---------------- case 12: the DEFAULT LFO rate, measured from the tap --
        // The module-default parameters (LFO_W = 26, LFO_STEP = 699 -> 0.499964 Hz).
        // The tap offset changes once every 2^(LFO_W-1-MOD_W)/LFO_STEP samples, so
        // MOD_DEPTH such steps are exactly one half period.
        do_reset();
        release_reset();
        slopes     = 0;
        slope_sum  = 0;
        prev_delay_lfo = -1;
        gap        = 0;
        for (n = 0; n < LFO_SLOPE_SAMPLES; n = n + 1) begin
            sample(16'sd1000);
            if (ready_lfo_now && out_lfo !== 16'sd1250)
                $fatal(1, "lfo_rate: sample %0d out=%0d, the filled line of 1000s must give 1000 + (1000 >>> %0d) = 1250",
                       n, out_lfo, MIX_S);
            if (prev_delay_lfo >= 0 && delay_lfo_now != prev_delay_lfo) begin
                if (n >= FILL_L && slopes < 8) begin
                    slope_sum = slope_sum + (n - gap);
                    slopes    = slopes + 1;
                end
                gap = n;
            end
            prev_delay_lfo = delay_lfo_now;
        end
        if (slopes < 8)
            $fatal(1, "lfo_rate: only %0d tap steps observed, expected 8", slopes);
        gap_avg  = slope_sum / (slopes * 1.0);
        f_meas   = 48000.0 / (2.0 * MODS_L * gap_avg);
        f_theory = (LFO_STEP_DEF * 48000.0) / (1 << LFO_W_DEF);
        if (f_meas < 0.2 || f_meas > 2.0)
            $fatal(1, "lfo_rate: measured f_lfo = %f Hz (tap step %f samples) is outside 0.2 .. 2 Hz",
                   f_meas, gap_avg);
        if ((f_meas - f_theory) > 0.03 * f_theory || (f_theory - f_meas) > 0.03 * f_theory)
            $fatal(1, "lfo_rate: measured f_lfo = %f Hz (tap step %f samples) is more than 3%% from the theoretical %f Hz",
                   f_meas, gap_avg, f_theory);
        $display("INFO tb_chorus_delay lfo_rate(default): the tap moves one offset step every %f samples over %0d steps -> half period %f samples -> measured f_lfo = %f Hz (theory %f Hz), ready at sample %0d",
                 gap_avg, slopes, MODS_L * gap_avg, f_meas, f_theory, FILL_L);

        $display("PASS tb_chorus_delay: 12 cases (reset, 48 kHz ce, LFO rate constants, fill window small+default, bypass, mix_shift_0, impulse position, saturation/clip_count, feedback amplitudes, peak meter, moving tap sweep with measured LFO rate, default LFO rate from the tap)");
        $finish;
    end

    initial begin
        #2_000_000_000;
        $fatal(1, "tb_chorus_delay: watchdog timeout");
    end
endmodule
