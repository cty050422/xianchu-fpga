// 32-partial additive tone generator (competition extension: "at least 32 additive components").
//
// Target: Tang Mega 60K with NEO Dock; see docs/hardware.md.
//
// ONE tone is built from up to 32 harmonic partials: partial k has its own 32-bit phase
// accumulator advancing by exactly k * base_inc every sample, so the partials stay harmonic for
// as long as the note is held - they cannot drift apart, because they all derive from one base
// increment instead of from 32 independently tuned oscillators.
//
// Contract:
//   * sample_ce marks the audio sample (about 48 kHz). One partial takes two clocks
//     with the original lookup, or three with optional eight-bit linear interpolation.
//     All 32 finish in 64/96 clocks (66/98 with mask fading), inside the 256-clock period at
//     12.288 MHz. 'busy' is high while a sample is being summed; a sample_ce arriving during that
//     window is ignored (it cannot happen at 48 kHz, and ignoring it is safer than truncating a
//     partial sum).
//   * EVERY parameter is LATCHED on the clock that starts a sample (base_inc -> base_latch,
//     partial_enable -> mask/fade state, level_shift -> shift_latch) and the whole sample uses
//     nothing but those latches. The layer that drives partial_enable is combinational and can
//     change in the middle of a sample; without the latch one sample would be summed from two
//     different parameter sets (part of the old mask, part of the new one, scaled with the wrong
//     level_shift) and it would TEAR.
//   * partial_enable selects which partials contribute: bit k-1 enables partial k. Masking the
//     high partials makes the tone darker WITHOUT touching the other partials' phases, so a
//     pressure gesture can reshape the timbre without re-triggering or detuning the note.
//   * NYQUIST GUARD: partial k advances by k * base_inc, i.e. it sounds at k * f0, and anything
//     above Fs/2 = 24 kHz folds back as a NON-HARMONIC alias. A partial is summed only while its
//     own increment k * base_inc is below NYQUIST_LIMIT (default 0x7000_0000).
//     Derivation: f = inc * Fs / 2^32, so inc < 2^31 is f < Fs/2. 0x7000_0000 = 0.4375 * 2^32,
//     i.e. 0.4375 * Fs = 21 kHz at Fs = 48 kHz - one eighth below Nyquist, which keeps the last
//     partial clear of the anti-imaging filter's transition region.
//     The PHASES OF THE EXCLUDED PARTIALS KEEP RUNNING (inc_running still accumulates); they are
//     only left out of the sum, so a partial that comes back into the band is not re-triggered.
//   * partials_active reports how many partials really contributed to the LAST FINISHED sample
//     (mask bit set AND inside the guard band). It is the measurable form of "32 additive
//     components in one tone", and a low fixed note has to report exactly 32.
//   * Every partial is scaled by a power of two (partial k is shifted by floor(log2 k)), which
//     approximates a 1/k spectrum without per-partial DSP multiplication. Optional mask fading
//     adds one shared signed multiply after summation; physical DSP use is reported by PnR.
//   * level_shift scales the sum for mixing. The sum is accumulated in 24 bits and the result is
//     SATURATED to signed 16 bits - it can never wrap.
//   * Reset clears every phase and the output: after reset, and with partial_enable = 0, the
//     output is exactly zero and partials_active is 0.
//
// The sine values come from rtl/sine_table_1024.sv, generated offline by
// model/generate_sine_table.py from sin(2*pi*i/1024) - no real-valued arithmetic in RTL, because
// the synthesiser rejects it (EX3861).
//
// STATUS: RTL simulation complete (sim/tb_additive_bank_32.sv checks a golden sine model, measured
// periods/amplitudes of single partials, the 32-partial sum, the parameter latch, the Nyquist
// guard band, a 32-term low-note golden sum, silence, scaling and saturation).
// Synthesis and hardware are reported separately; nothing about the audible result is measured yet.
module additive_bank_32 #(
    parameter integer PARTIALS = 32,
    // 0 retains the original hard mask and 64-clock sample contract. Nonzero ramps a mask
    // transition over ceil(256 / MASK_FADE_STEP) audio samples (4 = about 1.33 ms).
    parameter integer MASK_FADE_STEP = 0,
    // Interpolate between adjacent sine-table entries using eight extra phase bits.
    // Zero preserves the legacy waveform and cycle contract exactly. One shared
    // multiplier and a second ROM read add one clock per partial (96/98 total).
    parameter bit SINE_INTERPOLATION = 1'b0,
    // Guard band in phase-increment units; see the derivation in the header.
    parameter logic [31:0] NYQUIST_LIMIT = 32'h7000_0000
) (
    input  logic               clk,
    input  logic               rst_n,
    input  logic               sample_ce,
    input  logic [31:0]        base_inc,        // phase increment of the fundamental
    input  logic [31:0]        partial_enable,  // bit k-1 enables partial k (k = 1..32)
    input  logic [3:0]         level_shift,     // output scaling: sample = sum >>> level_shift
    output logic signed [15:0] sample,
    output logic [5:0]         partials_active, // partials that contributed to the last sample
    output logic               busy,            // high while the partials are being summed
    output logic [255:0]       diag_snapshot    // passive aligned arithmetic taps; optional
);
    // Clamp positive steps to one full transition; size the arithmetic explicitly.
    // Supported parameter values are non-negative; zero selects the legacy path.
    localparam logic [8:0] FADE_STEP_9 = (MASK_FADE_STEP > 256) ? 9'd256 : MASK_FADE_STEP[8:0];
    logic               active;
    logic               stage;          // 0 = advance phase and start the ROM read, 1 = accumulate
    logic [5:0]         step;           // 0..PARTIALS-1
    logic [31:0]        inc_running;    // k * base_inc, built by adding base_inc once per step
    logic [31:0]        base_latch;     // base_inc captured when this sample started
    logic [31:0]        mask_latch;     // partial_enable captured when this sample started
    logic [3:0]         shift_latch;    // level_shift captured when this sample started
    logic               guard_closed;   // a partial already reached the guard band: later ones are out
    logic [5:0]         used_count;     // partials summed into the sample that is in flight
    logic [4:0]         amp_shift;      // floor(log2(k)) for the current step
    logic [5:0]         next_pow2;      // 2, 4, 8, 16, 32 - where amp_shift steps up
    logic signed [23:0] acc;
    logic signed [23:0] acc_next;
    logic signed [23:0] partial_used;
    logic [31:0]        phase [0:PARTIALS-1];
    logic [9:0]         rom_index;
    logic signed [15:0] rom_value;
    logic signed [23:0] rom_ext;
    logic signed [23:0] partial_value;
    logic               use_step;
    logic               interp_pending;
    logic [7:0]         interp_fraction;
    logic signed [15:0] interp_base;
    logic [9:0]         rom_index_next;
    logic signed [15:0] rom_value_next;
    logic signed [16:0] interp_delta;
    logic signed [25:0] interp_product;
    logic signed [26:0] interp_rounded;
    logic signed [17:0] interp_value;
    logic               accumulate_valid;
    logic               done_pulse;

    // Both sums reuse exactly the same phases and ROM read. A new request during a fade
    // remains pending at the input: the latest request at the next accepted sample after
    // completion starts the next fade. Restarting alpha mid-fade would jump backwards.
    logic [31:0]        fade_from_mask, fade_to_mask;
    logic [8:0]         fade_alpha;    // unsigned Q0.8 with an exact unity value of 256
    logic signed [23:0] acc_to, acc_to_next;
    logic               use_from, use_to;
    logic [1:0]         tail_stage;
    logic signed [24:0] mix_difference;
    logic signed [34:0] mix_product;
    logic signed [34:0] mixed_wide;
    logic signed [23:0] mixed_sum;

    assign busy = active;
    // Explicit synthesis ports avoid relying on nonportable hierarchical GAO taps.
    // Every accepted term uses index 0..31 and the accumulator values of that clock.
    always_comb begin
        diag_snapshot = '0;
        diag_snapshot[0]       = sample_ce;
        diag_snapshot[1]       = sample_ce && !active;
        diag_snapshot[2]       = accumulate_valid;
        diag_snapshot[3]       = done_pulse;
        diag_snapshot[4]       = active;
        diag_snapshot[5]       = stage;
        diag_snapshot[6]       = interp_pending;
        diag_snapshot[7]       = sample_ce && active;
        diag_snapshot[13:8]    = step;
        diag_snapshot[37:14]   = partial_used;
        diag_snapshot[61:38]   = acc;
        diag_snapshot[85:62]   = acc_next;
        diag_snapshot[91:86]   = partials_active;
        diag_snapshot[97:92]   = used_count;
        diag_snapshot[129:98]  = base_latch;
        diag_snapshot[161:130] = inc_running;
        diag_snapshot[166:162] = amp_shift;
        diag_snapshot[182:167] = sample;
        diag_snapshot[191:183] = fade_alpha;
        diag_snapshot[193:192] = tail_stage;
        diag_snapshot[194]     = SINE_INTERPOLATION;
        diag_snapshot[195]     = (MASK_FADE_STEP != 0);
        diag_snapshot[199:196] = shift_latch;
        diag_snapshot[231:200] = phase[step];
        diag_snapshot[255:232] = acc_to_next;
    end

    // The instance name must not be 'table': that is a Verilog keyword (UDP tables).
    sine_table_1024 sine_rom (
        .clk(clk), .index(rom_index), .value(rom_value)
    );
    generate if (SINE_INTERPOLATION) begin : g_interpolated_sine
        // The ten-bit sum wraps 1023 -> 0, preserving sine-period continuity.
        sine_table_1024 sine_rom_next (
            .clk(clk), .index(rom_index_next), .value(rom_value_next)
        );
    end else begin : g_original_sine
        assign rom_value_next = 16'sd0;
    end endgenerate

    // Sign-extend the ROM value, then scale it with an ARITHMETIC shift: rom_ext is signed, so
    // '>>>' keeps the sign of negative partials (a logical shift would fold them to positive).
    always_comb rom_index     = phase[step][31:22];
    always_comb rom_index_next = rom_index + 10'd1;
    always_comb interp_delta  = $signed({rom_value_next[15], rom_value_next}) -
                                 $signed({rom_value[15], rom_value});
    // Signed Q0.8 interpolation. The 27-bit addition cannot overflow a 26-bit
    // product; +128 implements nearest rounding with ties toward positive infinity.
    always_comb interp_rounded = $signed({interp_product[25], interp_product}) + 27'sd128;
    always_comb interp_value = $signed({{2{interp_base[15]}}, interp_base}) +
                               (interp_rounded >>> 8);
    always_comb rom_ext       = SINE_INTERPOLATION ?
                               {{6{interp_value[17]}}, interp_value} :
                               {{8{rom_value[15]}}, rom_value};
    always_comb partial_value = rom_ext >>> amp_shift;
    // GAO must count accepted terms, excluding the interpolation multiply cycle.
    always_comb accumulate_valid = active && stage &&
                                   (!SINE_INTERPOLATION || interp_pending) &&
                                   (tail_stage == 2'd0);

    // Is the partial of THIS step summed? Two conditions, both built from latched values:
    //   * its mask bit was set when the sample started;
    //   * its own increment k * base_inc (held in inc_running) is still inside the guard band.
    // guard_closed makes the second condition sticky: once a partial has reached the guard band no
    // later partial can be back inside it, and the flag also stops the 32-bit inc_running from
    // wrapping (k * base_inc >= 2^32) and claiming that a very high partial is a low one again.
    // The fade path can count the contributing masks directly. This removes the extra
    // 32-bit mask latch from the nonzero-fade implementation while preserving the old
    // latch and cycle-by-cycle behavior when MASK_FADE_STEP is zero.
    always_comb use_step = ((MASK_FADE_STEP == 0) ? mask_latch[step] :
                            (((fade_alpha != 9'd256) && fade_from_mask[step]) ||
                             ((fade_alpha != 9'd0)   && fade_to_mask[step]))) &&
                           !guard_closed && (inc_running < NYQUIST_LIMIT);

    // acc_next includes the partial that is arriving on this clock. The sample must be taken from
    // acc_next, not from acc: otherwise the last partial would be summed into the accumulator that
    // is then thrown away, and partial 32 would never reach the output.
    always_comb use_from = fade_from_mask[step] && !guard_closed && (inc_running < NYQUIST_LIMIT);
    always_comb use_to   = fade_to_mask[step]   && !guard_closed && (inc_running < NYQUIST_LIMIT);
    always_comb partial_used = ((MASK_FADE_STEP == 0) ? use_step : use_from) ? partial_value : 24'sd0;
    always_comb acc_next     = acc + partial_used;
    always_comb acc_to_next  = acc_to + (use_to ? partial_value : 24'sd0);
    // Interpolate BEFORE output scaling/saturation. Prematurely clipping the two sums
    // would distort a transition. The leading zero keeps alpha=256 positive when signed.
    always_comb mixed_wide  = {{11{acc[23]}}, acc} + (mix_product >>> 8);
    always_comb mixed_sum   = mixed_wide[23:0];

    // Saturating narrowing: the sum is narrowed deliberately and can never wrap.
    function automatic logic signed [15:0] saturate(input logic signed [23:0] value);
        begin
            if (value > 24'sd32767)        saturate = 16'sd32767;
            else if (value < -24'sd32768)  saturate = -16'sd32768;
            else                           saturate = value[15:0];
        end
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active          <= 1'b0;
            stage           <= 1'b0;
            step            <= 6'd0;
            inc_running     <= 32'd0;
            base_latch      <= 32'd0;
            mask_latch      <= 32'd0;
            shift_latch     <= 4'd0;
            guard_closed    <= 1'b0;
            used_count      <= 6'd0;
            amp_shift       <= 5'd0;
            next_pow2       <= 6'd2;
            acc             <= 24'sd0;
            sample          <= 16'sd0;
            partials_active <= 6'd0;
            fade_from_mask  <= 32'd0;
            fade_to_mask    <= 32'd0;
            fade_alpha      <= 9'd256;
            acc_to          <= 24'sd0;
            tail_stage      <= 2'd0;
            mix_difference  <= 25'sd0;
            mix_product     <= 35'sd0;
            interp_pending  <= 1'b0;
            interp_fraction <= 8'd0;
            interp_base     <= 16'sd0;
            interp_product  <= 26'sd0;
            done_pulse      <= 1'b0;
            for (integer i = 0; i < PARTIALS; i = i + 1) phase[i] <= 32'd0;
        end else begin
            done_pulse <= 1'b0;
            if (sample_ce && !active) begin
                // Start a new sample: partial 1 uses base_inc, and the running increment grows by
                // base_inc at every step, so partial k always advances by exactly k * base_inc
                // (modulo 2^32, which is what a phase accumulator wants).
                // The three parameters are captured HERE, and they are the only ones this sample
                // ever sees - a change on any later clock belongs to the next sample.
                active       <= 1'b1;
                stage        <= 1'b0;
                step         <= 6'd0;
                inc_running  <= base_inc;
                base_latch   <= base_inc;
                if (MASK_FADE_STEP == 0) begin
                    mask_latch <= partial_enable;
                end else if (fade_alpha == 9'd256) begin
                    fade_from_mask <= fade_to_mask;
                    if (partial_enable != fade_to_mask) begin
                        fade_to_mask <= partial_enable;
                        fade_alpha   <= 9'd0;
                    end
                end else if ((9'd256 - fade_alpha) <= FADE_STEP_9) begin
                    fade_alpha <= 9'd256;
                end else begin
                    fade_alpha <= fade_alpha + FADE_STEP_9;
                end
                shift_latch  <= level_shift;
                // Partial 1's increment is base_inc itself.
                guard_closed <= (base_inc >= NYQUIST_LIMIT);
                used_count   <= 6'd0;
                amp_shift    <= 5'd0;
                next_pow2    <= 6'd2;
                acc          <= 24'sd0;
                acc_to       <= 24'sd0;
                tail_stage   <= 2'd0;
                interp_pending <= 1'b0;
            end else if (active) begin
                if ((MASK_FADE_STEP != 0) && (tail_stage == 2'd1)) begin
                    // Shared signed multiplier: never 32 per-partial multipliers.
                    mix_product <= mix_difference * $signed({1'b0, fade_alpha});
                    tail_stage  <= 2'd2;
                end else if ((MASK_FADE_STEP != 0) && (tail_stage == 2'd2)) begin
                    sample          <= saturate(mixed_sum >>> shift_latch);
                    partials_active <= used_count;
                    active          <= 1'b0;
                    tail_stage      <= 2'd0;
                    done_pulse      <= 1'b1;
                end else if (stage == 1'b0) begin
                    // The index comes from the phase BEFORE this step's increment, so sample n uses
                    // the phase n * inc. rom_index is COMBINATIONAL from that phase: the table has a
                    // one-clock registered read, and a registered index would push the read one
                    // partial behind (partial k would then sum the sine of partial k-1, and partial
                    // 1 would sum whatever the previous sample left in the index register).
                    // The phase advances even when the partial is masked or out of band: that is
                    // what keeps every partial's phase continuous across mask changes.
                    phase[step] <= phase[step] + inc_running;
                    interp_fraction <= phase[step][21:14];
                    stage       <= 1'b1;
                end else if (SINE_INTERPOLATION && !interp_pending) begin
                    // Both registered ROM endpoints correspond to the OLD phase.
                    // Advance only the multiply pipeline here; accumulate next clock.
                    interp_base    <= rom_value;
                    interp_product <= interp_delta * $signed({1'b0, interp_fraction});
                    interp_pending <= 1'b1;
                end else begin
                    // The ROM value for rom_index arrives on this clock (registered read).
                    acc          <= acc_next;
                    acc_to       <= acc_to_next;
                    guard_closed <= guard_closed || (inc_running >= NYQUIST_LIMIT);
                    if (use_step) used_count <= used_count + 6'd1;
                    stage        <= 1'b0;
                    interp_pending <= 1'b0;
                    if (step == PARTIALS[5:0] - 6'd1) begin
                        if (MASK_FADE_STEP == 0) begin
                            sample          <= saturate(acc_next >>> shift_latch);
                            // The counter is published together with the sample it describes.
                            partials_active <= used_count + (use_step ? 6'd1 : 6'd0);
                            active          <= 1'b0;
                            done_pulse      <= 1'b1;
                        end else begin
                            // Subtract full signed sums, then multiply and narrow on the next
                            // two clocks. Completion takes 66/98 clocks, below the 256-clock period.
                            mix_difference <= $signed({acc_to_next[23], acc_to_next}) -
                                              $signed({acc_next[23], acc_next});
                            tail_stage <= 2'd1;
                        end
                    end else begin
                        step        <= step + 6'd1;
                        inc_running <= inc_running + base_latch;
                        // 'step' still holds the step that is finishing, so the NEXT partial is
                        // step+2: partial k must already carry floor(log2 k) when it is summed.
                        if (step + 6'd2 == next_pow2) begin
                            amp_shift <= amp_shift + 5'd1;
                            next_pow2 <= {next_pow2[4:0], 1'b0};
                        end
                    end
                end
            end
        end
    end
endmodule
