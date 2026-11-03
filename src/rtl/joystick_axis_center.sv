// Captures a mechanical joystick centre from four stable, plausible ADC samples.
// The measured centre is fixed until reset. A stale axis cannot drive a control.
module joystick_axis_center #(
    parameter logic [11:0] REFERENCE_CENTER = 12'd2048,
    parameter logic [11:0] ACCEPT_WINDOW = 12'd500,
    parameter logic [11:0] STABLE_SPREAD = 12'd64,
    parameter integer STALE_AUDIO_SAMPLES = 480
) (
    input  logic clk,
    input  logic rst_n,
    input  logic sample_ce,
    input  logic [11:0] axis_code,
    input  logic axis_valid,
    output logic [11:0] center_code,
    output logic [11:0] filtered_code,
    output logic center_valid,
    output logic stale
);
    localparam integer AGE_W = $clog2(STALE_AUDIO_SAMPLES + 1);
    logic [AGE_W-1:0] age_samples;
    logic [2:0] stable_count;
    logic [13:0] stable_sum;
    logic [11:0] stable_min, stable_max;
    logic [11:0] next_min, next_max;
    logic [12:0] reference_error;
    logic signed [13:0] filter_error, filter_step, filter_next;

    assign next_min = (axis_code < stable_min) ? axis_code : stable_min;
    assign next_max = (axis_code > stable_max) ? axis_code : stable_max;
    assign reference_error = (axis_code >= REFERENCE_CENTER)
                           ? ({1'b0, axis_code} - {1'b0, REFERENCE_CENTER})
                           : ({1'b0, REFERENCE_CENTER} - {1'b0, axis_code});
    assign stale = !center_valid || (age_samples >= STALE_AUDIO_SAMPLES);

    always_comb begin
        filter_error = $signed({2'b00, axis_code}) - $signed({2'b00, filtered_code});
        filter_step = filter_error >>> 2;
        if ((filter_step == 0) && (filter_error != 0))
            filter_step = (filter_error > 0) ? 14'sd1 : -14'sd1;
        filter_next = $signed({2'b00, filtered_code}) + filter_step;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            age_samples  <= STALE_AUDIO_SAMPLES[AGE_W-1:0];
            stable_count <= 3'd0;
            stable_sum   <= 14'd0;
            stable_min   <= 12'hfff;
            stable_max   <= 12'd0;
            center_code  <= REFERENCE_CENTER;
            filtered_code<= REFERENCE_CENTER;
            center_valid <= 1'b0;
        end else begin
            if (axis_valid) begin
                age_samples <= '0;
                if (!center_valid) begin
                    if (reference_error > {1'b0, ACCEPT_WINDOW}) begin
                        stable_count <= 3'd0;
                        stable_sum   <= 14'd0;
                        stable_min   <= 12'hfff;
                        stable_max   <= 12'd0;
                    end else if ((stable_count == 0) ||
                                 (({1'b0, next_max} - {1'b0, next_min}) > {1'b0, STABLE_SPREAD})) begin
                        stable_count <= 3'd1;
                        stable_sum   <= {2'b00, axis_code};
                        stable_min   <= axis_code;
                        stable_max   <= axis_code;
                    end else if (stable_count == 3) begin
                        center_code  <= (stable_sum + {2'b00, axis_code} + 14'd2) >> 2;
                        filtered_code<= axis_code;
                        center_valid <= 1'b1;
                    end else begin
                        stable_count <= stable_count + 3'd1;
                        stable_sum   <= stable_sum + {2'b00, axis_code};
                        stable_min   <= next_min;
                        stable_max   <= next_max;
                    end
                end else begin
                    filtered_code <= filter_next[11:0];
                end
            end else if (sample_ce && age_samples < STALE_AUDIO_SAMPLES) begin
                age_samples <= age_samples + 1'b1;
            end
        end
    end
endmodule
