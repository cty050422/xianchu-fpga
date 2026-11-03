module button_debounce #(
    parameter integer STABLE_CYCLES = 61_440,
    parameter logic   RESET_VALUE   = 1'b1
) (
    input  logic clk,
    input  logic rst_n,
    input  logic noisy_in,
    output logic stable_out
);
    localparam integer COUNTER_WIDTH =
        (STABLE_CYCLES <= 1) ? 1 : $clog2(STABLE_CYCLES);
    logic [COUNTER_WIDTH-1:0] counter;

    initial begin
        if (STABLE_CYCLES < 1)
            $error("STABLE_CYCLES must be at least one");
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stable_out <= RESET_VALUE;
            counter    <= '0;
        end else if (noisy_in == stable_out) begin
            counter <= '0;
        end else if (counter == STABLE_CYCLES - 1) begin
            stable_out <= noisy_in;
            counter    <= '0;
        end else begin
            counter <= counter + 1'b1;
        end
    end
endmodule
