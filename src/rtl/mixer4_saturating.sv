module mixer4_saturating #(
    parameter integer NORMALIZE_SHIFT = 2
) (
    input  logic signed [15:0] voice0,
    input  logic signed [15:0] voice1,
    input  logic signed [15:0] voice2,
    input  logic signed [15:0] voice3,
    output logic signed [15:0] mixed,
    output logic               clipped
);
    logic signed [17:0] sum_wide;
    logic signed [17:0] normalized;

    always_comb begin
        sum_wide = {{2{voice0[15]}}, voice0}
                 + {{2{voice1[15]}}, voice1}
                 + {{2{voice2[15]}}, voice2}
                 + {{2{voice3[15]}}, voice3};
        normalized = sum_wide >>> NORMALIZE_SHIFT;
        clipped = 1'b0;
        if (normalized > 18'sd32767) begin
            mixed   = 16'sd32767;
            clipped = 1'b1;
        end else if (normalized < -18'sd32768) begin
            mixed   = -16'sd32768;
            clipped = 1'b1;
        end else begin
            mixed = normalized[15:0];
        end
    end
endmodule
