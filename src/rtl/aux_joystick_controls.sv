// Second joystick: CH6 sets the additive-layer partial target (2..32);
// CH7 sets chorus wet gain. The Z switch alone selects the next-note preset.
module aux_joystick_controls #(
    parameter logic [7:0] DEFAULT_WET_GAIN_Q8 = 8'd32
) (
    input  logic clk,
    input  logic rst_n,
    input  logic sample_ce,
    input  logic [2:0] channel_id,
    input  logic [11:0] code,
    input  logic code_valid,
    output logic [5:0] partial_target,
    output logic [7:0] wet_gain_target_q8,
    output logic [1:0] center_valid,
    output logic [1:0] axis_stale,
    output logic [11:0] diag_center_x,
    output logic [11:0] diag_center_y,
    output logic [11:0] diag_filtered_y
);
    logic [11:0] center_x, center_y, filtered_x, filtered_y;
    assign diag_center_y = center_y;
    assign diag_center_x = center_x;
    assign diag_filtered_y = filtered_y;
    logic [12:0] low_600_y, low_250_y, high_250_y, high_600_y;

    joystick_axis_center x_axis (
        .clk(clk), .rst_n(rst_n), .sample_ce(sample_ce),
        .axis_code(code), .axis_valid(code_valid && channel_id == 3'd6),
        .center_code(center_x), .filtered_code(filtered_x),
        .center_valid(center_valid[0]), .stale(axis_stale[0])
    );
    joystick_axis_center y_axis (
        .clk(clk), .rst_n(rst_n), .sample_ce(sample_ce),
        .axis_code(code), .axis_valid(code_valid && channel_id == 3'd7),
        .center_code(center_y), .filtered_code(filtered_y),
        .center_valid(center_valid[1]), .stale(axis_stale[1])
    );

    assign low_600_y     = {1'b0, center_y} - 13'd600;
    assign low_250_y     = {1'b0, center_y} - 13'd250;
    assign high_250_y    = {1'b0, center_y} + 13'd250;
    assign high_600_y    = {1'b0, center_y} + 13'd600;

    // Absolute travel gives repeatable target counts; centre calibration is used
    // for health, not as a second preset threshold. A stale/unplugged axis
    // returns to a safe middle target rather than leaving an old extreme set.
    always_comb begin
        partial_target = 6'd17;
        if (center_valid[0] && !axis_stale[0]) begin
            partial_target = 6'd2 + {1'b0, filtered_x[11:7]};
            if (partial_target > 6'd32) partial_target = 6'd32;
        end
    end

    // Q0.8 wet gains: left extreme dry, low-left 1/16, center 1/8,
    // high-right 3/16, right extreme 1/4. Invalid/stale returns to 1/8.
    always_comb begin
        wet_gain_target_q8 = DEFAULT_WET_GAIN_Q8;
        if (!axis_stale[1]) begin
            if      ({1'b0, filtered_y} <= low_600_y)  wet_gain_target_q8 = 8'd0;
            else if ({1'b0, filtered_y} <= low_250_y)  wet_gain_target_q8 = 8'd16;
            else if ({1'b0, filtered_y} >= high_600_y) wet_gain_target_q8 = 8'd64;
            else if ({1'b0, filtered_y} >= high_250_y) wet_gain_target_q8 = 8'd48;
        end
    end
endmodule
