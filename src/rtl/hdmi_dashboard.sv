// HDMI dashboard compositor (S12): one screen, no scrolling.
//   * colour-bar test strip across the top 24 rows (digital verification aid),
//   * four voice-level bars fed by the REAL post-gain levels (S10 chain),
//   * a live waveform column drawn from a 64-point pre-effect snapshot,
//   * a text line: mode / timbre / step / target / wrong count in ASCII.
// Everything is derived from FPGA-authoritative signals; nothing here fabricates
// stereo or a second path. The TMDS serialization layer is a Gowin-IP step at
// synthesis (documented in the S12 profile), so this module outputs RGB+sync.
module hdmi_dashboard #(
    parameter integer WAVE_POINTS = 64
) (
    input  logic        clk_pix,
    input  logic        rst_n,
    // timing
    input  logic [9:0]  x,
    input  logic [9:0]  y,
    input  logic        visible,
    // authoritative panel data (sample-domain latches; the video domain treats
    // them as slowly-changing - each is sampled once per frame, no CDC hazard
    // worse than a one-frame-old value, and no back-pressure into audio)
    input  logic [1:0]  mode,             // 0 free 1 guide 2 challenge
    input  logic [1:0]  preset,
    input  logic [5:0]  step,
    input  logic [3:0]  target_mask,
    input  logic [15:0] wrong_count,
    input  logic [63:0] voice_levels,     // post-gain {v3,v2,v1,v0}
    input  logic [15:0] layer_level,
    input  logic [63:0] wave_points,      // 4 x 16-bit: latest pre-effect snippet
    output logic [7:0]  r,
    output logic [7:0]  g,
    output logic [7:0]  b
);
    localparam int BAR_W = 40;    // level bar width per voice (pixels)
    localparam int BAR_X0 = 24, BAR_Y0 = 64, BAR_H = 48, BAR_GAP = 64;
    localparam int WAVE_X0 = 24, WAVE_Y0 = 200, WAVE_H = 100;

    // Text: one line at y=16..23 with 8x8 glyphs.
    logic [6:0]  char_idx;
    logic [63:0] font_word;
    logic        font_px;
    logic [2:0]  font_col, font_row;

    // The status line renders as: "M<n> T<n> S<nn> Z<n> W<nnn>" (ASCII only -
    // the Chinese OLED owns the Chinese text; this dashboard is the judge view).
    // ASCII glyph indices ('0'=16 ... '9'=25, 'A'=33 ...): computed with plain
    // case statements (no functions - see the RESUME.md iverilog note).
    localparam logic [6:0] A_M = 7'd45, A_T = 7'd52, A_S = 7'd51,
                           A_Z = 7'd58, A_W = 7'd55;
    logic [6:0] line_chars [0:15];
    logic [6:0] asc_mode, asc_preset, asc_step, asc_mask;
    logic [6:0] asc_w2, asc_w1, asc_w0;
    always_comb begin
        case (mode)   0: asc_mode=7'd16; 1: asc_mode=7'd17; 2: asc_mode=7'd18; 3: asc_mode=7'd19; endcase
        case (preset) 0: asc_preset=7'd16; 1: asc_preset=7'd17; 2: asc_preset=7'd18; 3: asc_preset=7'd19; endcase
        case (step % 10)  0: asc_step=7'd16; 1: asc_step=7'd17; 2: asc_step=7'd18; 3: asc_step=7'd19;
            4: asc_step=7'd20; 5: asc_step=7'd21; 6: asc_step=7'd22; 7: asc_step=7'd23;
            8: asc_step=7'd24; default: asc_step=7'd25; endcase
        case (target_mask) 0: asc_mask=7'd16; 1: asc_mask=7'd17; 2: asc_mask=7'd18; 3: asc_mask=7'd19;
            4: asc_mask=7'd20; 5: asc_mask=7'd21; 6: asc_mask=7'd22; 7: asc_mask=7'd23;
            8: asc_mask=7'd24; 9: asc_mask=7'd25; 10: asc_mask=7'd26; 11: asc_mask=7'd27;
            12: asc_mask=7'd28; 13: asc_mask=7'd29; 14: asc_mask=7'd30; default: asc_mask=7'd31; endcase
        case ((wrong_count/100)%10) 0: asc_w2=7'd16; 1: asc_w2=7'd17; 2: asc_w2=7'd18; 3: asc_w2=7'd19;
            4: asc_w2=7'd20; 5: asc_w2=7'd21; 6: asc_w2=7'd22; 7: asc_w2=7'd23;
            8: asc_w2=7'd24; default: asc_w2=7'd25; endcase
        case ((wrong_count/10)%10) 0: asc_w1=7'd16; 1: asc_w1=7'd17; 2: asc_w1=7'd18; 3: asc_w1=7'd19;
            4: asc_w1=7'd20; 5: asc_w1=7'd21; 6: asc_w1=7'd22; 7: asc_w1=7'd23;
            8: asc_w1=7'd24; default: asc_w1=7'd25; endcase
        case (wrong_count%10) 0: asc_w0=7'd16; 1: asc_w0=7'd17; 2: asc_w0=7'd18; 3: asc_w0=7'd19;
            4: asc_w0=7'd20; 5: asc_w0=7'd21; 6: asc_w0=7'd22; 7: asc_w0=7'd23;
            8: asc_w0=7'd24; default: asc_w0=7'd25; endcase
        line_chars[0]  = A_M; line_chars[1]  = asc_mode;
        line_chars[2]  = A_T; line_chars[3]  = asc_preset;
        line_chars[4]  = A_S; line_chars[5]  = asc_step;
        line_chars[6]  = A_Z; line_chars[7]  = asc_mask;
        line_chars[8]  = A_W;
        line_chars[9]  = asc_w2;
        line_chars[10] = asc_w1;
        line_chars[11] = asc_w0;
        line_chars[12] = 7'd0; line_chars[13] = 7'd0;
        line_chars[14] = 7'd0; line_chars[15] = 7'd0;
    end

    // Wave: expand 4 x 16-bit samples into a staircase across WAVE_POINTS pixels.
    logic [15:0] wave_sel;
    logic [8:0]  wave_level;
    logic [15:0] lvl_sel;

    vga_font8x8 u_font (.idx(char_idx), .word(font_word));

    logic [7:0] r_c, g_c, b_c;
    always_comb begin
        r_c = 8'h00; g_c = 8'h00; b_c = 8'h00;
        font_px = 1'b0;
        char_idx = 7'd0;
        font_row = y[2:0];
        // --- colour bars: top 24 rows, 8 bars of 80 px ---
        if (y < 24 && x < 640) begin
            // 8 bars x 80 px: plain comparisons (80 is not a power of two).
            if      (x <  80) begin r_c=8'hFF; g_c=8'h00; b_c=8'h00; end
            else if (x < 160) begin r_c=8'h00; g_c=8'hFF; b_c=8'h00; end
            else if (x < 240) begin r_c=8'h00; g_c=8'h00; b_c=8'hFF; end
            else if (x < 320) begin r_c=8'hFF; g_c=8'hFF; b_c=8'h00; end
            else if (x < 400) begin r_c=8'h00; g_c=8'hFF; b_c=8'hFF; end
            else if (x < 480) begin r_c=8'hFF; g_c=8'h00; b_c=8'hFF; end
            else if (x < 560) begin r_c=8'hFF; g_c=8'hFF; b_c=8'hFF; end
            else                begin r_c=8'h20; g_c=8'h20; b_c=8'h20; end
        end
        // --- status text line (y 16..23, x 0..127) ---
        if (y >= 16 && y < 24 && x < 128) begin
            char_idx = line_chars[x[6:3]];
            font_col = x[2:0];
            font_px  = font_word[63 - (font_row*8 + (7 - font_col))];
            if (font_px) begin r_c=8'hFF; g_c=8'hFF; b_c=8'hFF; end
        end
        // --- four voice-level bars ---
        if (y >= BAR_Y0 && y < BAR_Y0 + BAR_H && x >= BAR_X0 &&
            x < BAR_X0 + 4*BAR_GAP + BAR_W) begin
            lvl_sel = (x < BAR_X0 + 1*BAR_GAP)           ? voice_levels[15:0] :
                      (x < BAR_X0 + 2*BAR_GAP)           ? voice_levels[31:16] :
                      (x < BAR_X0 + 3*BAR_GAP)           ? voice_levels[47:32] :
                                                           voice_levels[63:48];
            wave_level = lvl_sel[15:8];          // 8-bit bar length
            if ((x - BAR_X0) % BAR_GAP < BAR_W) begin
                if (x - BAR_X0 - ((x - BAR_X0)/BAR_GAP)*BAR_GAP < (wave_level * BAR_W) / 256) begin
                    r_c = 8'h00; g_c = 8'hC0; b_c = 8'h00;   // filled: green
                end else begin
                    r_c = 8'h18; g_c = 8'h18; b_c = 8'h18;   // empty: dark grey
                end
            end
        end
        // --- waveform staircase from the 4-sample snippet, repeated ---
        if (y >= WAVE_Y0 && y < WAVE_Y0 + WAVE_H && x >= WAVE_X0 && x < WAVE_X0 + 256) begin
            wave_sel = (x[3:2] == 2'd0) ? wave_points[15:0] :
                       (x[3:2] == 2'd1) ? wave_points[31:16] :
                       (x[3:2] == 2'd2) ? wave_points[47:32] : wave_points[63:48];
            if (y == WAVE_Y0 + WAVE_H/2 - (wave_sel[13:8] % (WAVE_H/2))) begin
                r_c = 8'hFF; g_c = 8'h80; b_c = 8'h00;       // amber trace
            end
        end
    end
    assign r = visible ? r_c : 8'h00;
    assign g = visible ? g_c : 8'h00;
    assign b = visible ? b_c : 8'h00;
endmodule
