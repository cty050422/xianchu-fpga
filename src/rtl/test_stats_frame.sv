// T3 auditable statistics frame (0x86, body 14 bytes). READ-ONLY observation:
// nothing here can change the audio timing, the allocator, the engine or the DAC.
//
// Counting rules (documented口径, mirrored in the delivery docs):
//   voice          = a slot that is gated AND has a nonzero envelope (actually
//                    sounding through the base voice core), capped at 4;
//   audible partial= that voice's ACTUALLY COMPUTED partial count (the engine's
//                    own per-voice tally) while the voice is audible, summed over
//                    voices, capped at 128. "Configured 32" is never reported as
//                    "audible 32" - the engine's counter is the source.
//   latency        = the qualified internal digital probe measurement (accepted
//                    note-on -> first nonzero PT8211 serial word). NOT physical
//                    control-to-analogue latency. last/min/max over up to the
//                    reported 8-bit measurement count, plus the probe's own
//                    invalid-observation counter.
// Throughput (count x actual output sample rate) is a DOCUMENTATION-level formula;
// the frame only carries the counts.
module test_stats_frame (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        sample_ce,
    input  logic [1:0]  test_kind,          // 00 normal 01 55Hz 10 four-freq
    input  logic [3:0]  voice_gates,
    input  logic [63:0] voice_envelopes,    // 4 x 16
    input  logic [23:0] voice_partials,     // 4 x 6, the engine's computed tally
    input  logic [31:0] voice_gains,        // 4 x 8 layer gains
    input  logic        lat_valid,          // one-clock pulse per qualified measure
    input  logic [15:0] lat_us,
    input  logic [15:0] lat_invalid,
    // ready/length/body/take handshake, same family as voice_status_stream
    output logic        ready,
    output logic [5:0]  length,
    output logic [111:0] body,
    input  logic        take,
    output logic [7:0]  seq
);
    logic [2:0]  voices_cur, voices_peak;
    logic [7:0]  partials_cur, partials_peak;
    logic [15:0] lat_last, lat_min, lat_max;
    logic [7:0]  lat_count, seq_r;
    logic [2:0]  v0, v1, v2, v3;

    always_comb begin
        v0 = (voice_gates[0] && voice_envelopes[15:0]   != 16'd0) ? 3'd1 : 3'd0;
        v1 = (voice_gates[1] && voice_envelopes[31:16]  != 16'd0) ? 3'd1 : 3'd0;
        v2 = (voice_gates[2] && voice_envelopes[47:32]  != 16'd0) ? 3'd1 : 3'd0;
        v3 = (voice_gates[3] && voice_envelopes[63:48]  != 16'd0) ? 3'd1 : 3'd0;
    end

    wire [2:0]  voices_now  = v0 + v1 + v2 + v3;
    wire [7:0]  partials_now = {5'd0, v0} * (v0 ? voice_partials[5:0]   : 6'd0)
                             + {5'd0, v1} * (v1 ? voice_partials[11:6]  : 6'd0)
                             + {5'd0, v2} * (v2 ? voice_partials[17:12] : 6'd0)
                             + {5'd0, v3} * (v3 ? voice_partials[23:18] : 6'd0);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            voices_cur <= 3'd0; voices_peak <= 3'd0;
            partials_cur <= 8'd0; partials_peak <= 8'd0;
            lat_last <= 16'd0; lat_min <= 16'hffff; lat_max <= 16'd0;
            lat_count <= 8'd0; seq_r <= 8'd0;
        end else begin
            if (sample_ce) begin
                voices_cur   <= voices_now;
                partials_cur <= partials_now;
                if (voices_now > voices_peak) voices_peak <= voices_now;
                if (partials_now > partials_peak) partials_peak <= partials_now;
            end
            if (lat_valid) begin
                lat_last <= lat_us;
                if (lat_us < lat_min) lat_min <= lat_us;
                if (lat_us > lat_max) lat_max <= lat_us;
                if (lat_count != 8'hff) lat_count <= lat_count + 8'd1;
            end
            if (take && ready) seq_r <= seq_r + 8'd1;
        end
    end

    // pace: one frame every ~200 ms of audio clock (2457600 cycles), so the
    // telemetry never floods the UART - ACK/status always outrank it anyway.
    logic [21:0] pace;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) pace <= 22'd0;
        else if (take && ready) pace <= 22'd2457_599;
        else if (pace != 22'd0) pace <= pace - 22'd1;
    end
    assign ready  = (pace == 22'd0);
    assign length = 6'd14;
    assign seq    = seq_r;
    // byte13 reserved, 12 lat_count, 11..10 lat_invalid LE, 9..8 lat_max,
    // 7..6 lat_min, 5..4 lat_last, 3 partials_peak, 2 voices_peak,
    // 1 partials_cur, 0 {test_kind, voices_cur, reserved}
    assign body   = {8'h00,
                     lat_count,
                     lat_invalid,
                     lat_max,
                     lat_min,
                     lat_last,
                     partials_peak,
                     {5'd0, voices_peak},
                     partials_cur,
                     test_kind, voices_cur, 3'b000};
endmodule
