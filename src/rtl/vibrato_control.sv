// Independent CH5 expression axis: a phase-continuous, depth-controlled vibrato.
//
// The FSR pressure controls force/brightness and CH4 controls manual pitch bend;
// CH5 is a physically separate joystick axis.  Its displacement from a measured
// centre sets vibrato depth (0..about 50 cents).  A 5 Hz triangle LFO supplies the
// periodic motion.  The phase runs continuously, even at zero depth, so touching
// the control never restarts the oscillator.  The output is a Q1.15 frequency
// ratio; 32768 is exactly unity and therefore a safe value before calibration or
// after stale ADC data.  No audio samples or pre-recorded waveforms are stored.
//
// The initial centre capture deliberately requires four consecutive CH5 readings
// close to the nominal centre and mutually stable.  The performer must release
// this stick during startup.  It never re-zeroes itself while being played.
module vibrato_control #(
    parameter integer STARTUP_SAMPLES = 4,
    parameter logic [11:0] REFERENCE_CENTER = 12'd2048,
    parameter logic [11:0] ACCEPT_WINDOW = 12'd400,
    parameter logic [11:0] STABLE_SPREAD = 12'd32,
    parameter logic [11:0] DEAD_ZONE = 12'd64,
    parameter logic [11:0] SLEW_STEP_Q8 = 12'd16,
    parameter integer STALE_AUDIO_SAMPLES = 480, // 10 ms at 48 kHz
    parameter logic [23:0] LFO_STEP = 24'd1748  // 5.001 Hz at 48 kHz
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        sample_ce,
    input  logic [11:0] axis_code,
    input  logic        axis_valid,
    output logic [15:0] ratio_q15,
    output logic        center_valid,
    output logic [11:0] center_code,
    output logic [11:0] depth_q8,
    output logic        axis_stale,
    output logic [23:0] lfo_phase
);
    localparam integer COUNT_W = $clog2(STARTUP_SAMPLES + 1);
    localparam integer SUM_W = 12 + $clog2(STARTUP_SAMPLES + 1);
    localparam integer AGE_W = $clog2(STALE_AUDIO_SAMPLES + 1);
    localparam logic [11:0] MAX_DEPTH_Q8 = 12'd2048; // eight 6.25-cent steps

    logic [COUNT_W-1:0] stable_count;
    logic [SUM_W-1:0] stable_sum;
    logic [11:0] stable_min, stable_max;
    logic [11:0] last_code;
    logic [AGE_W-1:0] age_samples;
    logic [12:0] reference_error;
    logic [11:0] min_next, max_next;
    logic [12:0] displacement;
    logic [12:0] after_dead;
    logic [11:0] target_depth_q8;
    logic [SUM_W-1:0] sum_rounded;
    logic [SUM_W-1:0] centered_average;
    localparam logic [SUM_W-1:0] ROUND_BIAS = STARTUP_SAMPLES / 2;
    logic [8:0] phase_top;
    logic signed [10:0] triangle;
    logic signed [10:0] phase_twice;
    logic signed [23:0] depth_product;
    logic signed [31:0] depth_product_ext;
    logic signed [31:0] ratio_delta_scaled;
    logic signed [17:0] ratio_signed;

    initial begin
        if (STARTUP_SAMPLES < 2 || STARTUP_SAMPLES > 8)
            $error("vibrato_control: STARTUP_SAMPLES must be in 2..8");
        if (STALE_AUDIO_SAMPLES < 2 || SLEW_STEP_Q8 == 0 || LFO_STEP == 0)
            $error("vibrato_control: sample timeout, slew, and LFO step must be positive");
    end

    always_comb begin
        reference_error = (axis_code >= REFERENCE_CENTER)
                        ? ({1'b0, axis_code} - {1'b0, REFERENCE_CENTER})
                        : ({1'b0, REFERENCE_CENTER} - {1'b0, axis_code});
        min_next = (axis_code < stable_min) ? axis_code : stable_min;
        max_next = (axis_code > stable_max) ? axis_code : stable_max;
        displacement = (last_code >= center_code)
                     ? ({1'b0, last_code} - {1'b0, center_code})
                     : ({1'b0, center_code} - {1'b0, last_code});
        after_dead = displacement - {1'b0, DEAD_ZONE};
        sum_rounded = stable_sum + {{(SUM_W-12){1'b0}}, axis_code} + ROUND_BIAS;
        centered_average = sum_rounded / STARTUP_SAMPLES;
        // Two Q8.8 depth units per ADC code after the dead band.  At full
        // travel the upper bound is eight steps, approximately +/-50 cents.
        if (!center_valid || axis_stale || displacement <= {1'b0, DEAD_ZONE})
            target_depth_q8 = 12'd0;
        else if (displacement >= {1'b0, DEAD_ZONE} + 13'd1024)
            target_depth_q8 = MAX_DEPTH_Q8;
        else
            target_depth_q8 = {after_dead[10:0], 1'b0};
    end

    assign axis_stale = !center_valid || (age_samples >= STALE_AUDIO_SAMPLES);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stable_count <= '0;
            stable_sum   <= '0;
            stable_min   <= 12'hfff;
            stable_max   <= 12'd0;
            center_valid <= 1'b0;
            center_code  <= REFERENCE_CENTER;
            last_code    <= REFERENCE_CENTER;
            age_samples  <= STALE_AUDIO_SAMPLES[AGE_W-1:0];
            depth_q8     <= 12'd0;
            lfo_phase    <= 24'd0;
        end else begin
            if (axis_valid) begin
                age_samples <= '0;
                last_code <= axis_code;
                if (!center_valid) begin
                    if (reference_error > {1'b0, ACCEPT_WINDOW}) begin
                        stable_count <= '0;
                        stable_sum <= '0;
                        stable_min <= 12'hfff;
                        stable_max <= 12'd0;
                    end else if (stable_count == 0 ||
                                 ({1'b0, max_next} - {1'b0, min_next}) > {1'b0, STABLE_SPREAD}) begin
                        stable_count <= {{(COUNT_W-1){1'b0}}, 1'b1};
                        stable_sum <= axis_code;
                        stable_min <= axis_code;
                        stable_max <= axis_code;
                    end else if (stable_count == STARTUP_SAMPLES - 1) begin
                        center_code <= centered_average[11:0];
                        center_valid <= 1'b1;
                    end else begin
                        stable_count <= stable_count + 1'b1;
                        stable_sum <= stable_sum + axis_code;
                        stable_min <= min_next;
                        stable_max <= max_next;
                    end
                end
            end else if (sample_ce && age_samples < STALE_AUDIO_SAMPLES) begin
                age_samples <= age_samples + 1'b1;
            end

            if (sample_ce) begin
                lfo_phase <= lfo_phase + LFO_STEP;
                if (depth_q8 < target_depth_q8) begin
                    if ({1'b0, target_depth_q8} - {1'b0, depth_q8} <= {1'b0, SLEW_STEP_Q8})
                        depth_q8 <= target_depth_q8;
                    else depth_q8 <= depth_q8 + SLEW_STEP_Q8;
                end else if (depth_q8 > target_depth_q8) begin
                    if ({1'b0, depth_q8} - {1'b0, target_depth_q8} <= {1'b0, SLEW_STEP_Q8})
                        depth_q8 <= target_depth_q8;
                    else depth_q8 <= depth_q8 - SLEW_STEP_Q8;
                end
            end
        end
    end

    // Triangle -255..+255..-255, phase-continuous at the wrap.  A triangle
    // contains only odd harmonics; its tiny pitch steps are <0.5 cent at max
    // depth.  Using the high phase bits avoids an audio-rate modulation spur.
    assign phase_top = lfo_phase[23:15];
    assign phase_twice = $signed({1'b0, phase_top, 1'b0});
    assign triangle = phase_top[8] ? (11'sd767 - phase_twice)
                                   : (phase_twice - 11'sd255);
    assign depth_product = triangle * $signed({1'b0, depth_q8});
    assign depth_product_ext = {{8{depth_product[23]}}, depth_product};
    // 118 Q1.15 units are approximately 6.25 cents; *118 is shifts/adds.
    assign ratio_delta_scaled = (depth_product_ext <<< 7) -
                                (depth_product_ext <<< 3) -
                                (depth_product_ext <<< 1);
    assign ratio_signed = 18'sd32768 +
                          {{2{ratio_delta_scaled[31]}}, ratio_delta_scaled[31:16]};
    // On stale ADC data the target depth becomes zero and the same slew rule
    // fades vibrato out; forcing unity in one sample would jump the pitch.
    assign ratio_q15 = center_valid ? ratio_signed[15:0] : 16'd32768;
endmodule
