module adsr_envelope #(
    parameter bit CURVED_DECAY_RELEASE = 1'b0,
    parameter bit CONTINUOUS_RETRIGGER = 1'b0,
    parameter integer CURVE_SHIFT = 9,
    parameter bit CURVE_ERROR_FEEDBACK = 1'b0
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        sample_ce,
    input  logic        gate,
    input  logic        retrigger,
    input  logic [15:0] attack_step,
    input  logic [15:0] decay_step,
    input  logic [15:0] sustain_level,
    input  logic [15:0] release_step,
    output logic [15:0] level,
    output logic [2:0]  state
);
    localparam logic [2:0] IDLE    = 3'd0;
    localparam logic [2:0] ATTACK  = 3'd1;
    localparam logic [2:0] DECAY   = 3'd2;
    localparam logic [2:0] SUSTAIN = 3'd3;
    localparam logic [2:0] RELEASE = 3'd4;

    logic gate_d;
    logic [16:0] decay_distance, decay_delta, release_delta;
    // Keep the discarded fractional part of distance/2^CURVE_SHIFT.
    // A separate remainder per voice removes the positive envelope bias of
    // truncating every decay decrement. Default-off keeps old traces exact.
    // CURVE_SHIFT 0..16 is supported; shift zero has no fractional state.
    localparam integer REMAINDER_WIDTH = (CURVE_SHIFT > 0) ? CURVE_SHIFT : 1;
    logic [REMAINDER_WIDTH-1:0] curve_remainder;
    logic [16:0] decay_fraction_sum, release_fraction_sum;

    always_comb begin
        decay_distance = ({1'b0, level} > {1'b0, sustain_level})
                       ? ({1'b0, level} - {1'b0, sustain_level}) : 17'd0;
        decay_delta = {1'b0, decay_step};
        release_delta = {1'b0, release_step};
        decay_fraction_sum = decay_distance;
        release_fraction_sum = {1'b0, level};
        if (CURVE_ERROR_FEEDBACK && CURVE_SHIFT != 0) begin
            decay_fraction_sum = decay_fraction_sum + curve_remainder;
            release_fraction_sum = release_fraction_sum + curve_remainder;
        end
        if (CURVED_DECAY_RELEASE) begin
            decay_delta = decay_delta + (decay_fraction_sum >> CURVE_SHIFT);
            release_delta = release_delta + (release_fraction_sum >> CURVE_SHIFT);
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            level  <= '0;
            state  <= IDLE;
            gate_d <= 1'b0;
            curve_remainder <= '0;
        end else begin
            gate_d <= gate;
            if (retrigger) begin
                curve_remainder <= '0;
                if (!CONTINUOUS_RETRIGGER)
                    level <= '0;
                state <= ATTACK;
            end else if (gate && !gate_d) begin
                curve_remainder <= '0;
                state <= ATTACK;
            end else if (!gate && gate_d && state != IDLE) begin
                curve_remainder <= '0;
                state <= RELEASE;
            end else if (sample_ce) begin
                case (state)
                    IDLE: begin
                        level <= '0;
                        curve_remainder <= '0;
                    end
                    ATTACK: begin
                        curve_remainder <= '0;
                        if (attack_step == 0 || level >= 16'hffff - attack_step) begin
                            level <= 16'hffff;
                            state <= DECAY;
                        end else
                            level <= level + attack_step;
                    end
                    DECAY: begin
                        if (decay_step == 0 || level <= sustain_level ||
                            decay_distance <= decay_delta) begin
                            level <= sustain_level;
                            state <= SUSTAIN;
                            curve_remainder <= '0;
                        end else begin
                            level <= level - decay_delta[15:0];
                            if (CURVED_DECAY_RELEASE && CURVE_ERROR_FEEDBACK && CURVE_SHIFT != 0)
                                curve_remainder <= decay_fraction_sum[REMAINDER_WIDTH-1:0];
                        end
                    end
                    SUSTAIN: begin
                        level <= sustain_level;
                        curve_remainder <= '0;
                    end
                    RELEASE: begin
                        if (release_step == 0 || {1'b0, level} <= release_delta) begin
                            level <= '0;
                            state <= IDLE;
                            curve_remainder <= '0;
                        end else begin
                            level <= level - release_delta[15:0];
                            if (CURVED_DECAY_RELEASE && CURVE_ERROR_FEEDBACK && CURVE_SHIFT != 0)
                                curve_remainder <= release_fraction_sum[REMAINDER_WIDTH-1:0];
                        end
                    end
                    default: begin
                        level <= '0;
                        state <= IDLE;
                        curve_remainder <= '0;
                    end
                endcase
            end
        end
    end
endmodule
