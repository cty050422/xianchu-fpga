// Global pitch bend from the thumb axis (M4).
//
// The thumb controller is one axis with a mechanical centre. This module turns its raw
// converter code into a bend RATIO in Q1.15 (32768 = unity) that the voice path multiplies
// into the phase increment latched at note-on. Two properties matter and are tested:
//
//   * the ratio is computed from the axis position and applied to the latched base
//     increment, never as "multiply the previous result again": returning the stick to the
//     centre returns the ratio to EXACTLY 32768, so repeated bending cannot drift the pitch;
//   * bending changes the increment only. It does not touch any oscillator phase, so the
//     timbre does not restart on a bend (there is no reset path from this module into the
//     oscillators at all).
//
// Mapping: the axis is normalised by SPAN_CODE around CENTER_CODE, clamped to full scale, a
// dead zone of DEAD_ZONE_CODE around the centre holds unity, and the remaining travel is
// divided into SEMITONES*STEPS_PER_SEMITONE segments whose ratios come from
// ratio = 2^(semitones/12). The table is generated from that formula, so no ratio is
// hand-tuned. Quantisation is one segment = 1/STEPS_PER_SEMITONE of a semitone (6.25 cents
// with the default 16 steps, measured and reported by sim/tb_pitch_bend.sv).
//
// BYPASS: while the instrument has no valid measured stick centre, rtl/instrument_top.sv
// raises `bypass`, and this module then publishes EXACTLY 32768 with no step and no
// semitone offset whatever the stick does. Bypass is therefore a property of this module
// rather than of a downstream multiplexer, so a single test can prove that an uncalibrated
// stick cannot transpose anything.
//
// STATUS: simulation complete; the real stick, its centre drift and its mechanical
// hysteresis are UNTESTED.
module pitch_bend #(
    parameter integer SEMITONES           = 2,
    parameter integer STEPS_PER_SEMITONE  = 16
) (
    input  logic [11:0] axis_code,
    input  logic [11:0] center_code,
    input  logic [11:0] dead_zone_code,   // half width of the dead zone
    input  logic [11:0] span_code,        // code distance from centre to full deflection
    input  logic        bypass,           // 1 = force unity: no measured centre yet
    output logic signed [15:0] semitone_q8,   // bend in 1/256 semitone, for telemetry
    output logic [15:0] ratio_q15,            // 32768 = no bend
    output logic signed [6:0] step_index,     // signed segment, 0 inside the dead zone
    output logic        at_center
);
    localparam integer TOTAL_STEPS = SEMITONES * STEPS_PER_SEMITONE;

    // Ratio tables for steps 0..32 (one step = 1/16 semitone, 32 steps = 2 semitones).
    // They are GENERATED OFFLINE from ratio = round(2^(+-step/192) * 32768) and pasted here
    // as constants: the first version computed them with $exp/real arithmetic, which the
    // synthesiser rejects outright (EX3861 "Synthesis of 'real' values is not supported").
    // Offline generation of coefficients is explicitly allowed by the charter; the testbench
    // re-derives 2^(+-2/12) independently and compares, so the table cannot drift unnoticed.
    function automatic logic [15:0] ratio_up(input integer step);
        logic [15:0] ratio;
        begin
            case (step)
                0: ratio = 16'h8000; 1: ratio = 16'h8077; 2: ratio = 16'h80ED; 3: ratio = 16'h8165;
                4: ratio = 16'h81DD; 5: ratio = 16'h8255; 6: ratio = 16'h82CE; 7: ratio = 16'h8347;
                8: ratio = 16'h83C0; 9: ratio = 16'h843A; 10: ratio = 16'h84B5; 11: ratio = 16'h852F;
                12: ratio = 16'h85AB; 13: ratio = 16'h8627; 14: ratio = 16'h86A3; 15: ratio = 16'h871F;
                16: ratio = 16'h879C; 17: ratio = 16'h881A; 18: ratio = 16'h8898; 19: ratio = 16'h8917;
                20: ratio = 16'h8995; 21: ratio = 16'h8A15; 22: ratio = 16'h8A95; 23: ratio = 16'h8B15;
                24: ratio = 16'h8B96; 25: ratio = 16'h8C17; 26: ratio = 16'h8C99; 27: ratio = 16'h8D1B;
                28: ratio = 16'h8D9E; 29: ratio = 16'h8E21; 30: ratio = 16'h8EA4; 31: ratio = 16'h8F28;
                default: ratio = 16'h8FAD;   // step 32 = +2 semitones
            endcase
            ratio_up = ratio;
        end
    endfunction

    function automatic logic [15:0] ratio_down(input integer step);
        logic [15:0] ratio;
        begin
            case (step)
                0: ratio = 16'h8000; 1: ratio = 16'h7F8A; 2: ratio = 16'h7F14; 3: ratio = 16'h7E9F;
                4: ratio = 16'h7E2A; 5: ratio = 16'h7DB6; 6: ratio = 16'h7D42; 7: ratio = 16'h7CCE;
                8: ratio = 16'h7C5B; 9: ratio = 16'h7BE8; 10: ratio = 16'h7B76; 11: ratio = 16'h7B04;
                12: ratio = 16'h7A93; 13: ratio = 16'h7A22; 14: ratio = 16'h79B1; 15: ratio = 16'h7941;
                16: ratio = 16'h78D1; 17: ratio = 16'h7861; 18: ratio = 16'h77F2; 19: ratio = 16'h7784;
                20: ratio = 16'h7715; 21: ratio = 16'h76A8; 22: ratio = 16'h763A; 23: ratio = 16'h75CD;
                24: ratio = 16'h7560; 25: ratio = 16'h74F4; 26: ratio = 16'h7488; 27: ratio = 16'h741D;
                28: ratio = 16'h73B2; 29: ratio = 16'h7347; 30: ratio = 16'h72DD; 31: ratio = 16'h7273;
                default: ratio = 16'h7209;   // step 32 = -2 semitones
            endcase
            ratio_down = ratio;
        end
    endfunction
    integer offset;
    integer magnitude;
    logic   negative;

    always_comb begin
        if (axis_code >= center_code) begin
            offset   = axis_code - center_code;
            negative = 1'b0;
        end else begin
            offset   = center_code - axis_code;
            negative = 1'b1;
        end
        if (offset > span_code) offset = span_code;

        at_center = (offset <= dead_zone_code) || bypass;
        if (at_center) begin
            magnitude = 0;
        end else begin
            magnitude = ((offset - dead_zone_code) * TOTAL_STEPS) /
                        ((span_code > dead_zone_code) ? (span_code - dead_zone_code) : 1);
        end
        if (magnitude > TOTAL_STEPS) magnitude = TOTAL_STEPS;

        if (at_center) begin
            ratio_q15   = 16'd32768;
            step_index  = 7'sd0;
            semitone_q8 = 16'sd0;
        end else if (!negative) begin
            ratio_q15   = ratio_up(magnitude);
            step_index  = magnitude[6:0];
            // One table step is 1/STEPS_PER_SEMITONE of a semitone and semitone_q8 counts
            // 1/256 semitone, so the conversion is a shift by log2(256/STEPS_PER_SEMITONE).
            // Written as a shift it cannot produce a width-truncation warning.
            // 6 bits of step plus a 4-bit shift fit a 16-bit signed value exactly, so the
            // expression is built at its final width (a 32-bit intermediate would be reported
            // as a truncation by the synthesiser).
            semitone_q8 = {6'd0, magnitude[5:0], 4'b0000};
        end else begin
            ratio_q15   = ratio_down(magnitude);
            step_index  = -magnitude[6:0];
            semitone_q8 = -{6'd0, magnitude[5:0], 4'b0000};
        end
    end
endmodule