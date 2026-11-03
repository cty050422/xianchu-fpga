// Two-key panel gesture controller (KEY0 / KEY1 -> six commands).
//
// The board has only KEY0 and KEY1, so the four panel actions of the instrument are reached
// with short presses, long presses and one two-key gesture. The contract below is the whole
// specification; sim/tb_two_key_gesture.sv checks every line of it.
//
// CONTRACT
//   short KEY0                      -> cmd_group            (toggle note group A/B)
//   short KEY1                      -> cmd_preset           (toggle pluck/wind preset)
//   long  KEY0  (>= LONG_CYCLES)    -> cmd_octave           (toggle the +12 semitone octave)
//   long  KEY1  (>= LONG_CYCLES)    -> cmd_calibrate        (calibrate all five channels)
//   both, short (released < LONG)   -> cmd_panic            (all notes off)
//   both, held >= CLEAR_CYCLES      -> cmd_clear_calibration (make it hard to trigger by accident)
//
//   * A single-key action is emitted ONCE, at the moment its condition is met; holding the key
//     after that produces nothing further (the state machine is level based, not retriggered).
//   * A second key that becomes debounced within COMBO_WINDOW clocks of the first key cancels
//     the pending single-key action and enters combo mode. Combo release never emits a single
//     command. The window is measured from the first debounced press, not from raw contact.
//   * A second key that arrives after COMBO_WINDOW is ignored until both keys are released; the
//     first key remains the gesture owner and can still produce its short/long action. This
//     avoids turning an accidental late overlap into a destructive panic/clear operation.
//   * Reset (or a key held while reset is released) leaves the controller disarmed: nothing is
//     emitted until both keys have been released at least once, so power-up with a finger on a
//     key cannot fire a command.
//   * Debouncing lives HERE and only here. instrument_top owns this controller, so its board
//     shell must pass the raw active-low keys through without synchronising/debouncing again.
module two_key_gesture #(
    parameter integer DEBOUNCE_CYCLES  = 61_440,   // ~5 ms at 12.288 MHz
    parameter integer LONG_CYCLES      = 9_216_000,   // 0.75 s at 12.288 MHz
    parameter integer CLEAR_CYCLES     = 36_864_000,  // 3 s: deliberately hard to trigger
    parameter integer COMBO_WINDOW     = 2_088_960    // 0.17 s to recognise a two-key chord
) (
    input  logic clk,
    input  logic rst_n,
    input  logic [1:0] key_n,          // asynchronous, active low: [0] = KEY0, [1] = KEY1
    output logic cmd_group,
    output logic cmd_preset,
    output logic cmd_octave,
    output logic cmd_calibrate,
    output logic cmd_panic,
    output logic cmd_clear_calibration,
    output logic long_active,          // a long press is currently being held (for LED feedback)
    output logic combo_active,         // both keys are down (for LED feedback)
    output logic armed                 // both keys have been released since reset
);
    localparam logic [2:0] ST_IDLE      = 3'd0;
    localparam logic [2:0] ST_SINGLE    = 3'd1;   // one key held, no action yet
    localparam logic [2:0] ST_LONG      = 3'd2;   // one key held past LONG, action fired
    localparam logic [2:0] ST_COMBO     = 3'd3;   // both keys held, no single action allowed
    localparam logic [2:0] ST_COMBO_LNG = 3'd4;   // both held past CLEAR, action fired
    localparam logic [2:0] ST_SUPPRESS  = 3'd5;   // late second key: wait for a full release

    localparam integer MAX_LONG_CLEAR =
        (LONG_CYCLES > CLEAR_CYCLES) ? LONG_CYCLES : CLEAR_CYCLES;
    localparam integer MAX_COUNT =
        (MAX_LONG_CLEAR > COMBO_WINDOW) ? MAX_LONG_CLEAR : COMBO_WINDOW;
    localparam integer COUNTER_WIDTH =
        (MAX_COUNT < 2) ? 1 : $clog2(MAX_COUNT + 1);

    initial begin
        if (DEBOUNCE_CYCLES < 1) $error("DEBOUNCE_CYCLES must be >= 1");
        if (COMBO_WINDOW < 1)    $error("COMBO_WINDOW must be >= 1");
        if (LONG_CYCLES <= COMBO_WINDOW)
            $error("LONG_CYCLES must be greater than COMBO_WINDOW");
        if (CLEAR_CYCLES < LONG_CYCLES)
            $error("CLEAR_CYCLES must be >= LONG_CYCLES");
    end

    logic [1:0] key_sync_n;
    logic [1:0] key_stable_n;

    genvar k;
    generate
        for (k = 0; k < 2; k = k + 1) begin : pad
            input_sync sync_key (.clk(clk), .async_in(key_n[k]), .sync_out(key_sync_n[k]));
            button_debounce #(.STABLE_CYCLES(DEBOUNCE_CYCLES)) debounce_key (
                .clk(clk), .rst_n, .noisy_in(key_sync_n[k]), .stable_out(key_stable_n[k])
            );
        end
    endgenerate

    logic [1:0] pressed;        // debounced, active high
    assign pressed = ~key_stable_n;

    logic [2:0] state;
    logic [COUNTER_WIDTH-1:0] hold_counter;
    logic armed_r;
    logic origin_key1;
    logic origin_down;
    logic other_down;

    always_comb begin
        origin_down = origin_key1 ? pressed[1] : pressed[0];
        other_down  = origin_key1 ? pressed[0] : pressed[1];
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= ST_IDLE;
            hold_counter <= '0;
            armed_r     <= 1'b0;
            origin_key1 <= 1'b0;
            cmd_group   <= 1'b0;
            cmd_preset  <= 1'b0;
            cmd_octave  <= 1'b0;
            cmd_calibrate <= 1'b0;
            cmd_panic   <= 1'b0;
            cmd_clear_calibration <= 1'b0;
        end else begin
            cmd_group   <= 1'b0;
            cmd_preset  <= 1'b0;
            cmd_octave  <= 1'b0;
            cmd_calibrate <= 1'b0;
            cmd_panic   <= 1'b0;
            cmd_clear_calibration <= 1'b0;

            if (!armed_r) begin
                // Disarmed until both keys have been released once: a key held through power-up
                // (or through a reset) must not produce a command.
                if (pressed == 2'b00) armed_r <= 1'b1;
                hold_counter <= '0;
                state        <= ST_IDLE;
            end else begin
                case (state)
                    ST_IDLE: begin
                        hold_counter <= '0;
                        case (pressed)
                            2'b01: begin state <= ST_SINGLE; origin_key1 <= 1'b0; end
                            2'b10: begin state <= ST_SINGLE; origin_key1 <= 1'b1; end
                            2'b11: state <= ST_COMBO;       // both pressed together
                            default: state <= ST_IDLE;
                        endcase
                    end
                    ST_SINGLE: begin
                        if (!origin_down) begin
                            // The original key ended before its long action. Emit its short
                            // command even if a late second key is still held, then suppress
                            // that second key until a complete release re-arms the gesture.
                            if (!origin_key1) cmd_group  <= 1'b1;
                            else              cmd_preset <= 1'b1;
                            hold_counter <= '0;
                            state <= other_down ? ST_SUPPRESS : ST_IDLE;
                        end else if (other_down && (hold_counter < COMBO_WINDOW)) begin
                            // Only a second debounced press inside the explicit chord window
                            // forms a combo. The pending single-key action is cancelled.
                            state        <= ST_COMBO;
                            hold_counter <= '0;
                        end else if (hold_counter + 1'b1 >= LONG_CYCLES) begin
                            if (!origin_key1) cmd_octave   <= 1'b1;
                            else              cmd_calibrate <= 1'b1;
                            hold_counter <= '0;
                            state        <= ST_LONG;
                        end else begin
                            hold_counter <= hold_counter + 1'b1;
                        end
                    end
                    ST_LONG: begin
                        // The long action already fired. Any overlap is ignored until both keys
                        // are released, preventing a second command from the same physical hold.
                        hold_counter <= '0;
                        if (pressed == 2'b00) state <= ST_IDLE;
                    end
                    ST_COMBO: begin
                        if (pressed == 2'b00) begin
                            cmd_panic    <= 1'b1;
                            hold_counter <= '0;
                            state        <= ST_IDLE;
                        end else if (pressed != 2'b11) begin
                            // Clear requires a contiguous both-held interval. Once recognised as
                            // a combo, however, sequential release still produces one panic.
                            hold_counter <= '0;
                        end else if (hold_counter + 1'b1 >= CLEAR_CYCLES) begin
                            cmd_clear_calibration <= 1'b1;
                            hold_counter          <= '0;
                            state                 <= ST_COMBO_LNG;
                        end else begin
                            hold_counter <= hold_counter + 1'b1;
                        end
                    end
                    ST_COMBO_LNG: begin
                        hold_counter <= '0;
                        if (pressed == 2'b00) state <= ST_IDLE;
                    end
                    ST_SUPPRESS: begin
                        hold_counter <= '0;
                        if (pressed == 2'b00) state <= ST_IDLE;
                    end
                    default: begin
                        state <= ST_IDLE;
                        hold_counter <= '0;
                    end
                endcase
            end
        end
    end

    assign long_active  = (state == ST_LONG) || (state == ST_COMBO_LNG);
    assign combo_active = (state == ST_COMBO) || (state == ST_COMBO_LNG);
    assign armed        = armed_r;
endmodule
