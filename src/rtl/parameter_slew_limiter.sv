module parameter_slew_limiter #(
    parameter logic [15:0] STEP = 16'd512,
    parameter logic [15:0] RESET_VALUE = 16'd0
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        sample_ce,
    input  logic [15:0] target,
    output logic [15:0] value
);
    initial begin
        if (STEP == 0)
            $error("STEP must be non-zero");
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            value <= RESET_VALUE;
        end else if (sample_ce) begin
            if (value < target) begin
                if (target - value <= STEP)
                    value <= target;
                else
                    value <= value + STEP;
            end else if (value > target) begin
                if (value - target <= STEP)
                    value <= target;
                else
                    value <= value - STEP;
            end
        end
    end
endmodule
