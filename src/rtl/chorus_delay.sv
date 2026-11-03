// ============================================================================
// rtl/chorus_delay.sv -- synthesis-friendly chorus / delay for the frozen
// Tang Mega 60K instrument baseline.
//
// This module is an ADDITION to the frozen baseline: none of the frozen
// configurations (A/B/C), their bitstreams or their manifests instantiate it,
// so nothing in the frozen set changes.  It is a competition extension block.
//
// CONTRACT (one clock domain, one sample enable, no CPU, no memory other than
// the delay line itself):
//
//   * clk is the audio clock; sample_ce is one clk wide and marks one sample
//     (on the board 12.288 MHz / 256 = 48 kHz).  Every register in this module
//     updates only on a clk edge where sample_ce is high.
//   * Delay line: DEPTH signed 16-bit samples, written once per sample at
//     wr_ptr (modulo DEPTH) and read through a REGISTERED read port, so the
//     array maps onto block RAM instead of 16*DEPTH flip-flops plus one huge
//     LUT multiplexer.
//   * Tap address: rd_addr = wr_ptr_nxt - delay - 1, where wr_ptr_nxt =
//     wr_ptr + 1 is the write pointer of the NEXT sample.  Together with the
//     registered read this makes the round trip of a sample written at index k
//     appear at output index k + delay + 1 (see the derivation in
//     sim/tb_chorus_delay.sv).  delay is selected by mode:
//       MODE_BYPASS   (0): delay = DEPTH/2 but the tap is unused: pcm_out is
//                          EXACTLY pcm_in, bit for bit, sample for sample (no
//                          wet path, no saturation), and bypass_count advances
//                          once per sample.
//       MODE_FIXED    (1): delay = DEPTH/2 (2048 points ~ 42.7 ms at 48 kHz).
//       MODE_CHORUS   (2): delay = DEPTH/2 + triangle offset, offset sweeping
//                          0 .. MOD_DEPTH-1 and back once per LFO counter wrap
//                          (see the LFO section below), so the modulated tap
//                          never leads the fixed tap and never drops below 1.
//       MODE_FEEDBACK (3): as MODE_CHORUS, and what is written back into the
//                          line is saturate(pcm_in + (wet >>> 1)), i.e. a fixed
//                          1/2 feedback that is independent of MIX_SHIFT.
//   * Wet path and output: wet is the registered delay-line read data and
//       pcm_out = saturate(pcm_in + (wet >>> MIX_SHIFT)).
//     MIX_SHIFT = 0 means FULLY DRY: the wet term is forced to zero (the line is
//     still written, so switching to a wet mode later stays seamless).
//   * ready / fill window: ready is 0 from reset until the delay line has been
//     written FILL_TARGET = DEPTH + MAX_DELAY + 2 times, and stays 1 from then
//     on.  While ready is 0 the wet term is forced to zero, so pcm_out is
//     exactly the dry input and nothing can saturate.  The window therefore
//     covers the largest tap (MAX_DELAY = DEPTH/2 + MOD_DEPTH - 1) plus the
//     registered-read stage and one more sample, which is what makes the whole
//     post-reset behaviour independent of the delay-line contents.
//   * clip_count advances once per sample whose OUTPUT had to be saturated
//     (clamped to +32767 / -32768).  The mode-3 feedback write-back is clamped
//     as well but is never counted, and bypass samples are never counted.
//   * bypass_count advances once per sample whose mode is MODE_BYPASS; it stops
//     at 16'hFFFF.
//   * peak_abs is a self-resetting peak meter: the running maximum of |pcm_out|
//     inside a PEAK_WINDOW = 256 sample window.  The window boundary restarts
//     the maximum from the current sample, so silence drives peak_abs to 0 with
//     no host strobe and no extra port; rst_n clears it too.  The magnitude of
//     -32768 is 32768, so peak_abs may read 0x8000.
//
// NUMERICS AND SYNTHESIS CONVENTIONS
//   * All samples are signed 16-bit two's complement; internal sums carry one
//     extra bit of headroom and saturate to 16'sd32767 / -16'sd32768.
//   * No real, no $exp/$sin and no divider. The legacy wet path uses shifts;
//     the optional joystick wet-gain path uses one small DSP multiplier.
//     The LFO remains a counter folded into a triangle. (DEPTH >> 1, LFO_W'(...) and
//     $clog2(...) are parameter expressions folded once at elaboration; the Hz
//     band check of the LFO below is a multiplication-only comparison.)
//   * DEPTH and MOD_DEPTH must be powers of two, the largest tap plus one must
//     stay below DEPTH, LFO_W must be at least clog2(MOD_DEPTH)+1 and the LFO
//     rate must land inside 0.2 .. 2 Hz.  All of it is checked by an initial
//     $error, the same way rtl/parameter_slew_limiter.sv checks STEP.
//
// LFO (P06 fix 2026-09-15): WIDE PHASE ACCUMULATOR, RATE GIVEN IN Hz
//   * phase(n+1) = (phase(n) + LFO_STEP) mod 2^LFO_W with phase(0) = 0; one full
//     counter wrap is exactly one triangle cycle, therefore
//         triangle period  T     = 2^LFO_W / LFO_STEP   [samples]
//         f_lfo                  = 1 / T = LFO_STEP * Fs / 2^LFO_W   [Hz]
//     where Fs is the sample rate of sample_ce (FS_HZ, 48000 Hz on the board).
//   * Direction and magnitude are taken from the TOP of the counter:
//         phase[LFO_W-1]                 : 0 = rising half, 1 = falling half
//         mag  = phase[LFO_W-2 -: MOD_W] : the MOD_W bits directly under that bit
//         offset = mag                   while rising
//         offset = (MOD_DEPTH - 1) - mag while falling
//     Taking the bits DIRECTLY UNDER the direction bit (and not the lowest bits)
//     is what makes one counter wrap one slow triangle.  The offset always lies
//     in 0 .. MOD_DEPTH-1, so the modulated tap never leads the fixed tap and
//     never reaches address 0.
//   * DEFAULTS: LFO_W = 26, LFO_STEP = 699, FS_HZ = 48000
//         f_lfo = 699 * 48000 / 2^26 = 0.499964 Hz  (inside the required band)
//   * LFO_SHIFT is the LEGACY knob and is kept so existing instantiations keep
//     elaborating: LFO_SHIFT >= 0 overrides LFO_STEP with 2^LFO_SHIFT.
//     rtl/instrument_extension_core.sv (config D) does NOT pass LFO_SHIFT at all,
//     so the shipped chorus runs on LFO_STEP = 699 -> 0.499964 Hz, measured from
//     the RTL capture by model/analyze_chorus_sidebands.py (0.500000 Hz).
//     An earlier revision of that instantiation did pass LFO_SHIFT = 10 (step
//     1024 -> 0.73242 Hz); that line was removed in the configuration-D audit.
//     LFO_SHIFT = -1 (the default) means "use LFO_STEP".
//   * The 0.2 .. 2 Hz band is checked in the initial block with multiplications
//     only -- 5*LFO_STEP*Fs >= 2^LFO_W and LFO_STEP*Fs <= 2^(LFO_W+1) -- so this
//     file contains no divider at all.
//   * HISTORY (what this replaces): LFO_W was clog2(MOD_DEPTH)+1 = 7 and LFO_STEP
//     was LFO_SHIFT = 10, so the counter wrapped every 2^7/10 = 12.8 samples and
//     the triangle ran at 1.875 kHz -- inside the audio band, which turns the
//     "chorus" into noise/distortion.  The offset was also read from the LOW bits
//     of that narrow counter.  Both are fixed above.
//   * The read address and the write address of one sample are never equal
//     (1 <= delay <= MAX_DELAY < DEPTH), so the registered read and the write
//     share one single-port block RAM with no bypass network and no hazard.
//
// STATUS: 只验证到 RTL 仿真；综合/PnR/硬件未验证
//   (只验证到 RTL 仿真: sim/tb_chorus_delay.sv is self-checking and passes, and
//   sim/tb_extension_pcm_capture.sv captures the real RTL PCM of one config-D
//   chorus run for model/analyze_chorus_sidebands.py.  No logic-analyser or
//   oscilloscope data has been taken: 硬件数据尚未采集.
//   Synthesis, place & route / static timing and real hardware are NOT
//   verified.  rtl/instrument_extension_core.sv instantiates this module, but
//   no bitstream has been built or tested for that extension, and the signal
//   that the array really infers as BSRAM is a synthesis-time claim only.)
// ============================================================================
module chorus_delay #(
    parameter integer DEPTH     = 2048,   // delay-line length in samples, power of two
    parameter integer MIX_SHIFT = 2,      // wet gain 1/2^MIX_SHIFT; 0 = fully dry
    parameter integer MOD_DEPTH = 64,     // triangle LFO span in samples, power of two
    parameter integer LFO_W     = 26,     // LFO phase accumulator width in bits
    parameter integer LFO_STEP  = 699,    // LFO phase increment per sample (0.5007 Hz @ 48 kHz)
    parameter integer FS_HZ     = 48000,  // sample rate of sample_ce, used by the Hz band check
    parameter integer LFO_SHIFT = -1,     // legacy: >= 0 overrides LFO_STEP with 2^LFO_SHIFT
    parameter bit EXTERNAL_WET_GAIN = 1'b0,
    // One-multiply interpolation of neighbouring stored samples. Off retains
    // the original integer-tap arithmetic and output/sample timing.
    parameter bit FRACTIONAL_TAP = 1'b0
) (
    input  logic               clk,
    input  logic               rst_n,
    input  logic               sample_ce,
    input  logic signed [15:0] pcm_in,
    input  logic [1:0]         mode,
    input  logic [7:0]         wet_gain_target_q8,
    output logic signed [15:0] pcm_out,
    output logic [15:0]        peak_abs,
    output logic [15:0]        clip_count,
    output logic [15:0]        bypass_count,
    output logic               ready,      // 0 until the delay line has filled once
    output logic [7:0]         wet_gain_active_q8,
    output logic [255:0]       diag_snapshot
);
    localparam integer ADDR_W      = $clog2(DEPTH);
    localparam integer MOD_W       = $clog2(MOD_DEPTH);
    localparam integer FIXED_DELAY = DEPTH >> 1;   // DEPTH is a power of two (constant fold)
    localparam integer MAX_DELAY   = FIXED_DELAY + (MOD_DEPTH - 1) + (FRACTIONAL_TAP ? 1 : 0);
    localparam integer FILL_TARGET = DEPTH + MAX_DELAY + 2;
    localparam integer FILL_W      = $clog2(FILL_TARGET + 1);
    localparam integer PEAK_WINDOW = 256;               // ~5.3 ms at 48 kHz
    localparam integer PEAK_W      = $clog2(PEAK_WINDOW);

    localparam logic [1:0] MODE_BYPASS   = 2'd0;
    localparam logic [1:0] MODE_FIXED    = 2'd1;
    localparam logic [1:0] MODE_CHORUS   = 2'd2;
    localparam logic [1:0] MODE_FEEDBACK = 2'd3;

    // LFO geometry.  The direction is the top bit of a counter that wraps once per
    // triangle cycle, and the modulation magnitude is the MOD_W bits directly below
    // it (see the header): the lowest phase bit is LFO_W-1-MOD_W, the highest is one
    // bit below the direction bit, LFO_W-2.
    localparam integer MOD_LSB     = LFO_W - 1 - MOD_W;
    localparam integer MOD_MSB     = LFO_W - 2;
    // Legacy LFO_SHIFT = -1 means "use LFO_STEP"; >= 0 means "1 << LFO_SHIFT".
    localparam integer LFO_STEP_I  = (LFO_SHIFT < 0) ? LFO_STEP
                                                     : (1 << ((LFO_SHIFT < 0) ? 0 : LFO_SHIFT));

    localparam logic [MOD_W-1:0]  MOD_MAX       = MOD_W'(MOD_DEPTH - 1);
    localparam logic [LFO_W-1:0]  LFO_STEP_C    = LFO_W'(LFO_STEP_I);
    localparam logic [ADDR_W-1:0] FIXED_DELAY_C = ADDR_W'(FIXED_DELAY);

    initial begin
        if (DEPTH < 4 || DEPTH != (1 << ADDR_W))
            $error("chorus_delay: DEPTH must be a power of two and at least 4");
        if (MOD_DEPTH < 2 || MOD_DEPTH != (1 << MOD_W))
            $error("chorus_delay: MOD_DEPTH must be a power of two and at least 2");
        if (MIX_SHIFT < 0 || MIX_SHIFT > 16)
            $error("chorus_delay: MIX_SHIFT must be in 0 .. 16");
        if (LFO_W < MOD_W + 1 || LFO_W > 32 || (FRACTIONAL_TAP && MOD_LSB < 8))
            $error("chorus_delay: LFO_W must be in clog2(MOD_DEPTH)+1 .. 32");
        if (LFO_STEP_I < 1 || LFO_STEP_I > ((1 << LFO_W) - 1))
            $error("chorus_delay: LFO_STEP must be in 1 .. 2^LFO_W-1 so the LFO moves and fits");
        if (FS_HZ < 1)
            $error("chorus_delay: FS_HZ must be the positive sample rate of sample_ce");
        // f_lfo = LFO_STEP * FS_HZ / 2^LFO_W must stay inside 0.2 .. 2 Hz.  The two
        // comparisons below are the same statement multiplied out, so no divider is
        // needed: f >= 0.2 <=> 5*LFO_STEP*Fs >= 2^LFO_W, f <= 2 <=> LFO_STEP*Fs <= 2^(LFO_W+1).
        if ((64'd5 * LFO_STEP_I * FS_HZ) < (64'd1 << LFO_W))
            $error("chorus_delay: f_lfo = %0d*%0d/2^%0d Hz is below 0.2 Hz; raise LFO_STEP or lower LFO_W",
                   LFO_STEP_I, FS_HZ, LFO_W);
        if ((64'd1 * LFO_STEP_I * FS_HZ) > (64'd2 << LFO_W))
            $error("chorus_delay: f_lfo = %0d*%0d/2^%0d Hz is above 2 Hz; lower LFO_STEP or raise LFO_W",
                   LFO_STEP_I, FS_HZ, LFO_W);
        if (FIXED_DELAY < 1 || (MAX_DELAY + 1) >= DEPTH)
            $error("chorus_delay: delay must be >= 1 and delay+1 must stay below DEPTH");
    end

    // The delay line, declared as block RAM.  It is written once per sample and
    // read through the register wet_q below: that is the shape Gowin infers as
    // BSRAM.  It is deliberately NOT reset and has no initial contents: BSRAM
    // contents are undefined after power-up, so a reset loop over the array
    // would infer 16*DEPTH flip-flops (and destroy BSRAM inference) while still
    // not being observable - the fill window below is what guarantees a
    // deterministic post-reset behaviour instead.
    // A packed pair permits the same one registered read per sample: low word
    // is x[k], high word is x[k-1]. It requires no additional dry-path register.
    (* syn_ramstyle = "block_ram" *) logic signed [31:0] line [0:DEPTH-1];

    logic [ADDR_W-1:0] wr_ptr;         // slot written on THIS sample
    logic [ADDR_W-1:0] wr_ptr_nxt;     // that pointer one sample later
    logic [LFO_W-1:0]  lfo_phase;
    logic [MOD_W-1:0]  lfo_mag;
    logic [MOD_W-1:0]  mod_offset;
    logic [ADDR_W-1:0] delay;
    logic [ADDR_W-1:0] rd_addr;
    logic [FILL_W-1:0] fill_cnt;
    logic [PEAK_W-1:0] peak_cnt;

    logic signed [15:0] older_q, previous_write, interpolated_wet;
    logic [7:0] tap_fraction, fraction_q;
    logic signed [16:0] tap_delta;
    logic signed [25:0] tap_product;
    logic signed [25:0] interp_sum;
    logic [31:0] diag_seq;
    logic signed [15:0] wet_q;         // registered block-RAM read data
    logic signed [16:0] dry_ext;
    logic signed [16:0] wet_ext;
    logic signed [16:0] wet_eff;
    logic signed [16:0] wet_mix;
    logic signed [24:0] wet_product;
    logic [7:0] wet_gain_q8;
    assign wet_gain_active_q8 = wet_gain_q8;
    localparam logic [7:0] DEFAULT_WET_Q8 = (MIX_SHIFT == 0) ? 8'd0 : (256 >> MIX_SHIFT);
    logic signed [16:0] out_sum;
    logic signed [16:0] fb_sum;
    logic signed [15:0] out_sat;
    logic signed [15:0] fb_sat;
    logic signed [15:0] out_next;
    logic               out_clip;
    logic [15:0]        abs_next;

    assign wr_ptr_nxt = wr_ptr + 1'b1;

    // Tap address.  wr_ptr is the slot written on THIS sample, so wr_ptr_nxt is
    // the slot written one sample later, and (wr_ptr_nxt - delay - 1) is the
    // slot written "delay" samples before the sample whose output this
    // registered read feeds.  With the one sample the register itself costs, a
    // sample written at index k therefore reappears at output index k+delay+1
    // (exactly what sim/tb_chorus_delay.sv predicts).  delay >= 1 keeps this
    // address away from the write address of the same sample, and
    // MAX_DELAY + 1 < DEPTH keeps every tap inside the line.
    always_comb begin
        // Triangle LFO: the top bit of the phase counter selects the falling half
        // and the MOD_W bits directly below it are the ramp magnitude, so the
        // offset sweeps 0 .. MOD_DEPTH-1 and back without a jump and one counter
        // wrap is exactly one triangle cycle (see the header for the Hz formula).
        lfo_mag = lfo_phase[MOD_MSB:MOD_LSB];
        if (lfo_phase[LFO_W-1])
            mod_offset = MOD_MAX - lfo_mag;
        else
            mod_offset = lfo_mag;

        case (mode)
            MODE_CHORUS, MODE_FEEDBACK: delay = FIXED_DELAY_C + ADDR_W'(mod_offset);
            default:                    delay = FIXED_DELAY_C;
        endcase

        // Q0.8 fraction follows the triangle without one-sample tap jumps.
        // The falling endpoint reaches MOD_DEPTH exactly; its predecessor is
        // (MOD_DEPTH-1)+255/256, making both turns continuous to 1/256 sample.
        tap_fraction = 8'd0;
        if (FRACTIONAL_TAP && (mode == MODE_CHORUS || mode == MODE_FEEDBACK)) begin
            if (!lfo_phase[LFO_W-1]) begin
                delay = FIXED_DELAY_C + ADDR_W'(lfo_mag);
                tap_fraction = 8'(lfo_phase >> (MOD_LSB-8));
            end else begin
                if (8'(lfo_phase >> (MOD_LSB-8)) == 0) begin
                    delay = FIXED_DELAY_C + ADDR_W'(MOD_DEPTH) - ADDR_W'(lfo_mag);
                    tap_fraction = 0;
                end else begin
                    delay = FIXED_DELAY_C + ADDR_W'(MOD_DEPTH-1) - ADDR_W'(lfo_mag);
                    tap_fraction = 8'd0 - 8'(lfo_phase >> (MOD_LSB-8));
                end
            end
        end
        rd_addr = wr_ptr_nxt - delay - ADDR_W'(1);
    end

    // Mix, saturation and magnitude.  One extra bit of headroom keeps the sums
    // exact until they are clamped. Fractional interpolation adds one signed
    // 17x9 product; the Q8 wet-gain product is shared with the original path.
    always_comb begin
        dry_ext = {pcm_in[15], pcm_in};
        tap_delta = $signed({older_q[15],older_q}) - $signed({wet_q[15],wet_q});
        tap_product = tap_delta * $signed({1'b0,fraction_q});
        interp_sum = $signed(wet_q) + (tap_product >>> 8);
        interpolated_wet = FRACTIONAL_TAP ? interp_sum[15:0] : wet_q;
        wet_ext = {interpolated_wet[15], interpolated_wet};

        // Fill window: until the line has been written FILL_TARGET times the wet
        // term is forced to zero, in the output AND in the feedback write-back,
        // so neither the output nor the memory contents can depend on the
        // undefined power-up state of the BSRAM.
        wet_eff = ready ? wet_ext : 17'sd0;

        // MIX_SHIFT = 0 is documented as fully dry, not as unity wet.
        // The auxiliary controller only emits targets 0..64; a one-code-per-
        // sample slew gives the wet gain a bounded, click-free transition.
        wet_product = wet_eff * $signed({1'b0, wet_gain_q8[6:0]});
        if (EXTERNAL_WET_GAIN)
            wet_mix = wet_product[24:8];
        else if (MIX_SHIFT == 0)
            wet_mix = 17'sd0;
        else
            wet_mix = wet_eff >>> MIX_SHIFT;

        out_sum = dry_ext + wet_mix;
        fb_sum  = dry_ext + (wet_eff >>> 1);       // fixed 1/2 feedback

        out_clip = 1'b0;
        if (out_sum > 17'sd32767) begin
            out_sat  = 16'sd32767;
            out_clip = 1'b1;
        end else if (out_sum < -17'sd32768) begin
            out_sat  = -16'sd32768;
            out_clip = 1'b1;
        end else begin
            out_sat = out_sum[15:0];
        end

        if (fb_sum > 17'sd32767)
            fb_sat = 16'sd32767;
        else if (fb_sum < -17'sd32768)
            fb_sat = -16'sd32768;
        else
            fb_sat = fb_sum[15:0];

        // Bypass is bit exact: pcm_in reaches the output untouched, whatever the
        // delay line and the wet path are doing.
        if (mode == MODE_BYPASS)
            out_next = pcm_in;
        else
            out_next = out_sat;

        // Magnitude of a 16-bit signed sample; |-32768| is 0x8000.
        if (out_next[15])
            abs_next = (~out_next) + 16'd1;
        else
            abs_next = {1'b0, out_next[14:0]};
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr       <= '0;
            lfo_phase    <= '0;
            wet_q        <= 16'sd0;
            older_q      <= 16'sd0;
            previous_write <= 16'sd0;
            fraction_q   <= 8'd0;
            wet_gain_q8  <= DEFAULT_WET_Q8;
            fill_cnt     <= '0;
            ready        <= 1'b0;
            peak_cnt     <= '0;
            pcm_out      <= 16'sd0;
            peak_abs     <= 16'd0;
            clip_count   <= 16'd0;
            bypass_count <= 16'd0;
        end else if (sample_ce) begin
            if (EXTERNAL_WET_GAIN) begin
                if (wet_gain_q8 < wet_gain_target_q8)
                    wet_gain_q8 <= wet_gain_q8 + 8'd1;
                else if (wet_gain_q8 > wet_gain_target_q8)
                    wet_gain_q8 <= wet_gain_q8 - 8'd1;
            end
            wr_ptr    <= wr_ptr_nxt;
            lfo_phase <= lfo_phase + LFO_STEP_C;

            // Registered block-RAM read.  The write below targets wr_ptr while
            // this read targets wr_ptr_nxt - delay - 1 != wr_ptr, so one
            // single-port BSRAM serves both without a read-during-write hazard.
            wet_q <= line[rd_addr][15:0];
            older_q <= line[rd_addr][31:16];
            fraction_q <= tap_fraction;

            if (mode == MODE_FEEDBACK)
                begin line[wr_ptr] <= {previous_write,fb_sat}; previous_write <= fb_sat; end
            else
                begin line[wr_ptr] <= {previous_write,pcm_in}; previous_write <= pcm_in; end

            pcm_out <= out_next;

            if (mode == MODE_BYPASS) begin
                if (bypass_count != 16'hffff)
                    bypass_count <= bypass_count + 16'd1;
            end else if (out_clip) begin
                if (clip_count != 16'hffff)
                    clip_count <= clip_count + 16'd1;
            end

            // Fill window: FILL_TARGET sample writes make every reachable tap
            // address hold data written by this run.  ready then latches high
            // for good; the wet path is live from the next sample on.
            if (!ready) begin
                if (fill_cnt == FILL_W'(FILL_TARGET - 1))
                    ready <= 1'b1;
                else
                    fill_cnt <= fill_cnt + 1'b1;
            end

            // Self-resetting peak window: the window boundary restarts the
            // maximum from the current sample, so silence drives peak_abs to 0
            // without any host write.
            if (peak_cnt == PEAK_W'(PEAK_WINDOW - 1)) begin
                peak_cnt <= '0;
                peak_abs <= abs_next;
            end else begin
                peak_cnt <= peak_cnt + 1'b1;
                if (abs_next > peak_abs)
                    peak_abs <= abs_next;
            end
        end
    end

    // Passive output-stage snapshot. Packing is identical to the existing
    // chorus experiment schema; no probe signal controls the sound path.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin diag_seq <= 0; diag_snapshot <= 0; end
        else if (sample_ce) begin
            diag_seq <= diag_seq + 1;
            diag_snapshot <= {7'd1, diag_seq, pcm_in, wet_q, older_q, interpolated_wet, fraction_q, wet_mix, out_sum, out_next, wet_gain_q8, wet_gain_target_q8, lfo_phase, delay, wr_ptr, rd_addr, ready, mode, out_clip, clip_count};
        end
    end
endmodule
