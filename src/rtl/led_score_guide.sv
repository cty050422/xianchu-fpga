// Three-mode score guide v2 (S05): free / guided practice / rhythm challenge.
//
//   mode 0 (FREE)      : the module stays idle; the instrument plays freely.
//   mode 1 (GUIDE)     : press-driven. A step advances only when every zone of
//                        its target mask has been PRESSED (chords are gathered
//                        key by key, in any order, across clock cycles). A
//                        correct press always sounds immediately - this module
//                        never gates audio; the muting of wrong-FSR new notes
//                        happens in zone_note_map via block_mask. A held key
//                        cannot carry the player through later same-note steps:
//                        only a fresh trigger_on pulse accumulates progress.
//   mode 2 (CHALLENGE) : FPGA-clock-driven. Steps advance by their duration
//                        exactly like the R3 guide; a correct-zone press inside
//                        the window sounds and counts once (idempotent - the
//                        step_hit latch forbids double counting), classified
//                        early (first quarter) / late (last quarter) / on time.
//                        No press by the window end is a miss.
//
// Rests (target mask 0): guide mode waits the step duration with nothing
// required and counts nothing; challenge mode counts the window down silently.
//
// Expression steps (hint != 0): the sound is ALWAYS real. The step refuses to
// advance while expression_ok is low, and expression_dev pulses so the UI can
// show the deviation. No module here ever locks the joystick or mutes audio.
module led_score_guide #(
    parameter integer STEP_SAMPLES     = 24_000, // 500 ms at 48 kHz
    parameter integer FEEDBACK_SAMPLES = 4_800,  // 100 ms at 48 kHz
    parameter bit ALLOW_BUILTIN = 1'b1,
    parameter bit EXPRESSION_HINTS = 1'b0,
    parameter integer FLASH_SAMPLES = 6_000      // 4 Hz flashing at 48 kHz
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        sample_ce,
    input logic enable=1, reset_session=0,
    input  logic [1:0]  mode,              // 0 free, 1 guide, 2 challenge
    input  logic        external_score_enable,
    input  logic [6:0]  external_score_length,
    input  logic [3:0]  external_target_mask,  // multi-hot; 0 = rest
    input  logic [1:0]  external_expression_hint,
    input  logic        external_expression_ok, // live joystick meets the hint
    input  logic [23:0] external_step_samples,
    // Synchronous, one-clk pulses; bit i represents a press in zone i.
    input  logic [3:0]  hit_pulse,
    input  logic [3:0]  held_mask,
    output logic [3:0]  led,
    output logic [3:0]  target_led,
    output logic [5:0]  step_index,
    output logic [1:0]  expression_hint,
    output logic        expression_dev,   // hint unmet while the step waits
    output logic        hit_event,
    output logic        wrong_event,
    output logic        miss_event,
    output logic        phrase_done,
    output logic [15:0] hit_count,
    output logic [15:0] wrong_count,
    output logic [15:0] miss_count,
    output logic [15:0] early_count,      // challenge-only timing classification
    output logic [15:0] late_count
);
    localparam integer STEP_W = 24;
    localparam integer FB_W   = (FEEDBACK_SAMPLES <= 1) ? 1 : $clog2(FEEDBACK_SAMPLES + 1);

    logic [STEP_W-1:0] step_ticks;
    logic [FB_W-1:0] feedback_ticks;
    logic [1:0] feedback_code; // 0=idle, 1=hit, 2=wrong, 3=miss
    logic step_hit;            // challenge: this window already scored a hit
    logic [3:0] target_mask;
    logic [3:0] chord_progress; // guide: zones of this step already pressed
    logic [23:0] active_step_samples;
    logic advance_pending;   // sticky: set by the completing press, consumed at sample_ce
    logic dev_shown;         // the expression deviation was reported for this wait
    logic rest_step;
    logic[1:0]previous_mode;
    always_ff@(posedge clk or negedge rst_n)if(!rst_n)previous_mode<=0;else previous_mode<=mode;

    assign rest_step = external_score_enable && (external_target_mask == 4'b0000);

    always_comb begin
        expression_hint = 0;
        if (external_score_enable && mode != 2'd0)
            expression_hint = external_expression_hint;
        else if (EXPRESSION_HINTS && mode != 2'd0) begin
            if(step_index==2 || step_index==5) expression_hint=1;
            if(step_index==3 || step_index==7) expression_hint=2;
        end
    end

    logic [1:0] rom_zone;
    always_comb begin
        // The internal pattern is a short, repeatable 8-beat exercise, kept so
        // the board can guide without any uploaded score.
        case (step_index)
            5'd0: rom_zone = 2'd0;
            5'd1: rom_zone = 2'd1;
            5'd2: rom_zone = 2'd2;
            5'd3: rom_zone = 2'd3;
            5'd4: rom_zone = 2'd2;
            5'd5: rom_zone = 2'd1;
            5'd6: rom_zone = 2'd0;
            default: rom_zone = 2'd3;
        endcase
        target_mask = external_score_enable ? external_target_mask
                                            : (4'b0001 << rom_zone);
        active_step_samples = external_score_enable
                            ? ((external_step_samples == 0) ? 24'd1 : external_step_samples)
                            : STEP_SAMPLES;
    end

    // Step N is the last one of the currently selected pattern source.
    logic last_step;
    always_comb begin
        if (external_score_enable) last_step = (step_index + 1 >= external_score_length);
        else                       last_step = (step_index == 5'd7);
    end

    assign target_led = (rst_n && mode != 2'd0 && (ALLOW_BUILTIN || (external_score_enable && external_score_length!=0))) ? target_mask : 4'b0000;
    // Guide: a press is correct when every pressed zone is inside the mask.
    // Challenge: at least one pressed zone must be a target zone (R3 rule).
    logic guide_correct, challenge_correct;
    logic [3:0] physical_held;
    assign physical_held=held_mask;
    always_comb begin
        guide_correct     = (hit_pulse != 0) && ((hit_pulse & ~target_mask) == 4'b0000) && !rest_step;
        challenge_correct = (hit_pulse != 0) && ((hit_pulse & ~target_mask)==0) &&
                            (((chord_progress | hit_pulse) & physical_held & target_mask)==target_mask) && !rest_step && (expression_hint==0 || external_expression_ok);
    end
    // Four visible LEDs: the target mask itself is the guidance.
    assign led = !rst_n || mode == 2'd0 ? 4'b0000 :
                 (feedback_ticks == 0) ? target_led :
                 (feedback_code == 2'd1) ? (EXPRESSION_HINTS ? target_led : 4'b1111) : 4'b0000;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || mode == 2'd0 || reset_session || mode!=previous_mode || (!ALLOW_BUILTIN && (!external_score_enable || external_score_length==0))) begin
            step_index      <= 5'd0;
            step_ticks      <= '0;
            step_hit        <= 1'b0;
            chord_progress  <= 4'b0000;
            feedback_ticks  <= '0;
            feedback_code   <= 2'd0;
            hit_event       <= 1'b0;
            wrong_event     <= 1'b0;
            miss_event      <= 1'b0;
            phrase_done     <= 1'b0;
            expression_dev  <= 1'b0;
            hit_count       <= 16'd0;
            wrong_count     <= 16'd0;
            miss_count      <= 16'd0;
            early_count     <= 16'd0;
            late_count      <= 16'd0;
            advance_pending <= 1'b0;
            dev_shown       <= 1'b0;
        end else if(enable) begin
            hit_event      <= 1'b0;
            wrong_event    <= 1'b0;
            miss_event     <= 1'b0;
            phrase_done    <= 1'b0;
            expression_dev <= 1'b0;

            if (sample_ce && feedback_ticks != 0) begin
                feedback_ticks <= feedback_ticks - 1'b1;
                if (feedback_ticks == 1) feedback_code <= 2'd0;
            end

            chord_progress<=chord_progress & physical_held;
            if(mode==2'd1 && advance_pending && (physical_held & target_mask)!=target_mask) begin
                advance_pending<=0;step_ticks<=0;
            end
            // ---- presses -----------------------------------------------------
            if (hit_pulse != 0) begin
                if (mode == 2'd1) begin
                    // GUIDE: every pressed zone must belong to the mask.
                    if (guide_correct) begin
                        // Each target zone latches once per step; re-pressing an
                        // already-gathered zone cannot double-count (idempotent).
                        if (((hit_pulse & ~chord_progress) != 0)) begin
                            hit_event   <= 1'b1;
                            if (hit_count != 16'hffff) hit_count <= hit_count + 1'b1;
                            feedback_code  <= 2'd1;
                            feedback_ticks <= FEEDBACK_SAMPLES;
                            chord_progress <= chord_progress | hit_pulse;
                            // Step complete when the whole mask is gathered.
                            if (((chord_progress | hit_pulse) & physical_held) == target_mask) begin
                                advance_pending <= 1'b1;
                                dev_shown <= 1'b0;
                            end
                        end
                    end else begin
                        // A wrong zone pressed: recorded and shown. The sound was
                        // already withheld by zone_note_map (block_mask).
                        wrong_event   <= 1'b1;
                        if (wrong_count != 16'hffff) wrong_count <= wrong_count + 1'b1;
                        feedback_code  <= 2'd2;
                        feedback_ticks <= FEEDBACK_SAMPLES;
                    end
                end else begin
                    // CHALLENGE: all target keys must form the chord, not only
                    // one member. Fresh pulses gather only while actually held.
                    if((hit_pulse & ~target_mask)==0) chord_progress<=(chord_progress | hit_pulse)&physical_held;
                    // FPGA clock window, one score per window.
                    if (challenge_correct) begin
                        if (!step_hit) begin
                            step_hit    <= 1'b1;
                            hit_event   <= 1'b1;
                            if (hit_count != 16'hffff) hit_count <= hit_count + 1'b1;
                            feedback_code  <= 2'd1;
                            feedback_ticks <= FEEDBACK_SAMPLES;
                            // Timing classification on the window position.
                            if (step_ticks < active_step_samples / 4) begin
                                if (early_count != 16'hffff) early_count <= early_count + 1'b1;
                            end else if (step_ticks > active_step_samples - (active_step_samples / 4)) begin
                                if (late_count != 16'hffff) late_count <= late_count + 1'b1;
                            end
                        end
                    end else if ((hit_pulse & ~target_mask) != 0) begin
                        wrong_event   <= 1'b1;
                        if (wrong_count != 16'hffff) wrong_count <= wrong_count + 1'b1;
                        feedback_code  <= 2'd2;
                        feedback_ticks <= FEEDBACK_SAMPLES;
                    end
                end
            end

            // ---- expression gate (press-driven mode) --------------------------
            // A hint step only advances when the live joystick satisfies it.
            // The pending advance survives until then; the deviation is shown
            // once per wait, never muting audio or locking the joystick.
            if (advance_pending && mode == 2'd1 && expression_hint != 2'd0 &&
                !external_expression_ok && !dev_shown) begin
                expression_dev <= 1'b1;
                dev_shown      <= 1'b1;
            end

            // ---- step timing -------------------------------------------------
            if (sample_ce) begin
                if (mode == 2'd2 || rest_step) begin
                    // CHALLENGE and rests: the window ends by itself.
                    if (step_ticks == active_step_samples - 1'b1) begin
                        step_ticks <= '0;
                        step_hit   <= 1'b0;
                        chord_progress<=0;
                        // A correct press on this same closing sample belongs
                        // to the ending step (R3 boundary rule) and prevents
                        // the miss.
                        if (mode == 2'd2 && !rest_step && !step_hit && !challenge_correct) begin
                            miss_event <= 1'b1;
                            if (miss_count != 16'hffff) miss_count <= miss_count + 1'b1;
                            feedback_code  <= 2'd3;
                            feedback_ticks <= FEEDBACK_SAMPLES;
                        end
                        if (last_step) begin
                            step_index  <= 5'd0;
                            phrase_done <= 1'b1;
                        end else begin
                            step_index <= step_index + 1'b1;
                        end
                    end else begin
                        step_ticks <= step_ticks + 1'b1;
                    end
                end else if (advance_pending && mode == 2'd1 &&
                             (physical_held & target_mask)==target_mask) begin
                    if(step_ticks < active_step_samples-1) step_ticks<=step_ticks+24'd1;
                    else if(expression_hint==0 || external_expression_ok) begin
                    // GUIDE: only a completed target mask (+ hint condition)
                    // moves the step on; the sticky pending can never be lost
                    // between 48 kHz sample ticks.
                    step_ticks     <= '0;
                    chord_progress <= 4'b0000;
                    advance_pending <= 1'b0;
                    if (last_step) begin
                        step_index  <= 5'd0;
                        phrase_done <= 1'b1;
                    end else begin
                        step_index <= step_index + 1'b1;
                    end
                end
                    end
            end
        end else begin hit_event<=0;wrong_event<=0;miss_event<=0;phrase_done<=0;expression_dev<=0;end
    end
endmodule
