// Two-operator phase-modulation oscillator.
// Both operators are generated in real time; no PCM sample stream is stored.
module phase_mod_oscillator #(
    parameter bit SPECTRAL_GUARD = 1'b0
) (
    input  logic               clk,
    input  logic               rst_n,
    input  logic               sample_ce,
    input  logic [31:0]        carrier_phase_inc,
    input  logic [15:0]        modulation_index,
    input  logic [1:0]         pm_ratio_mode,
    output logic signed [15:0] sample
);
    logic [31:0] carrier_phase;
    logic [31:0] modulator_phase;
    logic signed [15:0] modulator_sample;
    logic signed [16:0] modulation_index_signed;
    logic signed [32:0] modulation_product;
    logic [31:0] modulated_phase;
    logic signed [15:0] sine_modulator_sample, sine_carrier_sample;
    logic [35:0] modulator_increment_wide, spectral_span;
    logic [8:0] spectral_gain_q8;
    logic [24:0] index_product;
    logic [15:0] guarded_index;

    // Estimate the carrier plus three modulator sidebands. Taper modulation
    // between 18 and 24 kHz at 48 kHz Fs. This reduces high-note sidebands;
    // it is not a claim of an ideal brick-wall bandlimited PM oscillator.
    // Wide arithmetic prevents a high ratio from wrapping into a low estimate.
    always_comb begin
        case (pm_ratio_mode)
            2'd1: modulator_increment_wide = ({4'd0,carrier_phase_inc} << 1)
                       + {4'd0,carrier_phase_inc} + ({4'd0,carrier_phase_inc} >> 1);
            2'd2: modulator_increment_wide = {4'd0,carrier_phase_inc};
            default: modulator_increment_wide = {4'd0,carrier_phase_inc} << 1;
        endcase
        spectral_span = {4'd0,carrier_phase_inc} + modulator_increment_wide
                      + (modulator_increment_wide << 1);
        if (spectral_span <= 36'h060000000) spectral_gain_q8 = 9'd256;
        else if (spectral_span >= 36'h080000000) spectral_gain_q8 = 9'd0;
        else spectral_gain_q8 = 9'd256 - 9'((spectral_span - 36'h060000000) >> 21);
        index_product = modulation_index * spectral_gain_q8;
        guarded_index = SPECTRAL_GUARD ? index_product[23:8] : modulation_index;
    end

    // Experimental sine PM for modes 1/2 only. Two registered ROM reads settle
    // in two system clocks; require at least three clocks between sample_ce edges.
    // Production cadence is 256 clocks/sample; the lab also checks four clocks.
    sine_table_1024 sine_modulator(.clk(clk), .index(modulator_phase[31:22]),
                                  .value(sine_modulator_sample));
    sine_table_1024 sine_carrier(.clk(clk), .index(modulated_phase[31:22]),
                                .value(sine_carrier_sample));

    function automatic logic signed [15:0] triangle_sample(input logic [31:0] phase_value);
        logic [15:0] folded;
        begin
            folded = phase_value[31] ? ~phase_value[30:15] : phase_value[30:15];
            triangle_sample = $signed({~folded[15], folded[14:0]});
        end
    endfunction

    always_comb begin
        if (pm_ratio_mode == 2'd0 && !SPECTRAL_GUARD)
            modulator_sample = triangle_sample(modulator_phase);
        else
            modulator_sample = sine_modulator_sample;
        modulation_index_signed = $signed({1'b0, guarded_index});
        // At index 0x4000 the peak phase deviation is approximately 1/8 cycle.
        modulation_product = modulator_sample * modulation_index_signed;
        modulated_phase = carrier_phase + modulation_product[31:0];
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            carrier_phase   <= '0;
            modulator_phase <= '0;
            sample          <= '0;
        end else if (sample_ce) begin
            carrier_phase   <= carrier_phase + carrier_phase_inc;
            // Fixed 2:1 modulator/carrier ratio gives a stable, harmonic timbre.
            if (pm_ratio_mode == 2'd1)
                // floor(3.5*increment), modulo 2^32. Only constant shifts/adds.
                modulator_phase <= modulator_phase + (carrier_phase_inc << 1)
                                   + carrier_phase_inc + (carrier_phase_inc >> 1);
            else if (pm_ratio_mode == 2'd2)
                modulator_phase <= modulator_phase + carrier_phase_inc;
            else
                // Keep the legacy path bit-for-bit, including modulo phase wrap.
                modulator_phase <= modulator_phase + (carrier_phase_inc << 1);
            if (pm_ratio_mode == 2'd0 && !SPECTRAL_GUARD)
                sample <= triangle_sample(modulated_phase);
            else
                sample <= sine_carrier_sample;
        end
    end
endmodule
