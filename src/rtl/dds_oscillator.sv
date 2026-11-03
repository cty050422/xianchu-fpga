module dds_oscillator #(
    parameter bit HIGH_NOTE_SMOOTHING = 1'b0
) (
    input  logic               clk,
    input  logic               rst_n,
    input  logic               sample_ce,
    input  logic [1:0]         waveform,
    input  logic [31:0]        phase_inc,
    output logic signed [15:0] sample,
    output logic [31:0]        phase_debug
);
    localparam logic [1:0] WAVE_SQUARE   = 2'd0;
    localparam logic [1:0] WAVE_SAW      = 2'd1;
    localparam logic [1:0] WAVE_TRIANGLE = 2'd2;

    logic [31:0] phase;
    logic [15:0] triangle_unsigned;
    logic signed [15:0] raw_sample, smooth_sine;
    logic [9:0] sine_index;
    logic [8:0] sine_blend_q8;
    logic signed [16:0] sine_delta;
    logic signed [26:0] sine_product, smooth_result;

    generate if (HIGH_NOTE_SMOOTHING) begin : high_note_rom
        // Triangle starts at its negative peak; align its replacement to -cos.
        always_comb sine_index = (waveform == WAVE_TRIANGLE)
                             ? phase[31:22] - 10'd256 : phase[31:22];
        sine_table_1024 sine_rom(.clk(clk), .index(sine_index), .value(smooth_sine));
    end else begin : no_high_note_rom
        always_comb begin sine_index = '0; smooth_sine = '0; end
    end endgenerate

    always_comb begin
        case (waveform)
            WAVE_SQUARE: raw_sample = phase[31] ? -16'sd32767 : 16'sd32767;
            WAVE_SAW: raw_sample = $signed(phase[31:16]);
            WAVE_TRIANGLE: raw_sample = $signed({~triangle_unsigned[15],triangle_unsigned[14:0]});
            default: raw_sample = '0;
        endcase
        // Leave the normal low register unchanged. Progressively replace high
        // notes (1500..4500 Hz at Fs=48 kHz) with a phase-aligned sine.
        if (waveform == 2'd3 || phase_inc <= 32'h0800_0000) sine_blend_q8 = 0;
        else if (phase_inc >= 32'h1800_0000) sine_blend_q8 = 256;
        else sine_blend_q8 = 9'((phase_inc - 32'h0800_0000) >> 20);
        sine_delta = $signed({smooth_sine[15],smooth_sine}) - $signed({raw_sample[15],raw_sample});
        sine_product = sine_delta * $signed({1'b0,sine_blend_q8});
        smooth_result = $signed({{11{raw_sample[15]}},raw_sample}) + (sine_product >>> 8);
    end

    always_comb begin
        triangle_unsigned = phase[31] ? ~phase[30:15] : phase[30:15];
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase  <= '0;
            sample <= '0;
        end else if (sample_ce) begin
            // The envelope, not the gate, controls audibility. Continuing the
            // oscillator after gate-off preserves the ADSR release tail.
            phase <= phase + phase_inc;
            sample <= HIGH_NOTE_SMOOTHING ? smooth_result[15:0] : raw_sample;
        end
    end

    assign phase_debug = phase;
endmodule
