// Four-voice status frame 0x84, schema2, coherent sample_ce snapshot.
// Body: schema, flags(bit0 active, bit1 budget), seq, grants LE16;
// then four 10-byte records: generation, preset/partials, PCM LE16, gain,
// flags(gate7/active6/effect-family5), MIDI note, region, envelope LE16.
// 45 body bytes + 7 framing = 52 bytes, three ATT20 fragments. A slow
// consumer never stalls audio; pending frames remain immutable until taken.
module voice_status_stream #(
    parameter integer STATUS_CLOCKS = 1_228_800  // 100 ms at 12.288 MHz
)(
    input  logic        clk, rst_n, sample_ce,
    input  logic [63:0] lane_pcm,          // 4 x 16 signed, from poly_additive_engine
    input  logic [23:0] voice_partials,    // 4 x 6
    input  logic [31:0] voice_gains,       // 4 x 8
    input  logic [31:0] voice_generation,  // 4 x 8
    input  logic [3:0]  voice_gates,
    input  logic [3:0]  voice_note_active,
    input  logic [7:0]  voice_presets,     // 4 x 2 (current preset per voice)
    input  logic [127:0] voice_phase_incs, // reserved compatibility input; schema2 reports actual MIDI note
    input  logic [15:0] grant_count,
    input  logic [31:0] voice_notes=32'd0,
    input  logic [7:0] voice_regions=8'd0,
    input  logic [63:0] voice_envelopes=64'd0,
    input  logic        effect_family,     // committed family (0 legacy, 1 space)
    input  logic        budget_violation,
    output logic        ready,
    output logic [7:0]  kind,
    output logic [5:0]  length,
    output logic [359:0] body,
    input  logic        take
);
    logic [31:0] ticks;
    logic [7:0]  seq;
    logic        due;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ticks <= 0; due <= 0; seq <= 0;
            ready <= 0; kind <= 0; length <= 0; body <= 0;
        end else begin
            if (ticks >= STATUS_CLOCKS - 1) begin
                ticks <= 0;
                if (!ready) due <= 1;   // busy: drop this period's frame, keep counting
            end else ticks <= ticks + 32'd1;

            if (ready && take) ready <= 0;
            if (!ready && due && sample_ce) begin
                ready  <= 1;
                due    <= 0;
                kind   <= 8'h84;
                length <= 6'd45;
                seq    <= seq + 8'd1;
                body   <= build();
            end
        end
    end

    // Latch the observed engine state at frame build time. sample_ce alignment: the
    // engine commits all four voices inside one sample period, so this snapshot is a
    // consistent cross-domain frame (no tearing within one frame).
    function automatic logic [359:0] build();
        logic [359:0] b;
        b = 360'd0;
        b[7:0]   = 8'd2; // schema2: 5 header bytes + 4 x 10-byte voices
        b[15:8]  = {6'd0, budget_violation, |voice_note_active};
        b[23:16] = seq;
        b[39:24] = grant_count;
        for (integer v = 0; v < 4; v = v + 1) begin
            b[40 + v*80 +: 8]  = voice_generation[v*8 +: 8];
            b[48 + v*80 +: 8]  = {voice_presets[v*2 +: 2], voice_partials[v*6 +: 6]};
            b[56 + v*80 +: 16] = lane_pcm[v*16 +: 16];
            b[72 + v*80 +: 8]  = voice_gains[v*8 +: 8];
            b[80 + v*80 +: 8]  = {voice_gates[v], voice_note_active[v], effect_family, 5'd0};
            b[88 + v*80 +: 8]  = voice_notes[v*8 +:8];
            b[96 + v*80 +: 8]  = {6'd0,voice_regions[v*2 +:2]};
            b[104 + v*80 +:16] = voice_envelopes[v*16 +:16];
        end
        return b;
    endfunction
endmodule
