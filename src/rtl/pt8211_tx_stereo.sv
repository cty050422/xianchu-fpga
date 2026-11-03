// Tang Mega NEO onboard PT8211-S DAC transmitter, independent stereo PCM.
// Derived from the established mono transmitter; clocks, PA timing and shared
// startup fade are unchanged. Both signed channels are latched atomically.
// PT8211 uses 16-bit two's-complement, MSB first, LSB-justified/Japanese format.
// WS low selects right, WS high selects left. DIN is captured on BCK rising edges.
// clk_12m288 / 4 = 3.072 MHz BCK; 64 BCK per stereo frame = 48 kHz WS.
module pt8211_tx_stereo #(
    // Let the DAC receive stable zero frames before enabling the active-low
    // amplifier. 122,880 clocks are 10 ms at 12.288 MHz.
    parameter integer PA_ENABLE_DELAY_CYCLES = 122_880
) (
    input  logic               clk_12m288,
    input  logic               rst_n,
    input  logic signed [15:0] pcm_left,
    input  logic signed [15:0] pcm_right,
    output logic               hp_bck,
    output logic               hp_ws,
    output logic               hp_din,
    output logic               pa_en
);
    logic [1:0] mclk_div;
    logic [5:0] bit_index;
    logic signed [15:0] left_latched, right_latched;
    localparam integer PA_DELAY_WIDTH =
        (PA_ENABLE_DELAY_CYCLES < 2) ? 1 : $clog2(PA_ENABLE_DELAY_CYCLES + 1);
    logic [PA_DELAY_WIDTH-1:0] pa_delay_count;
    logic delay_elapsed;
    logic pa_ready;
    logic [8:0] startup_gain;
    logic [8:0] next_startup_gain;
    logic signed [25:0] startup_product_left, startup_product_right;
    logic signed [15:0] faded_left, faded_right;

    initial begin
        if (PA_ENABLE_DELAY_CYCLES < 1)
            $error("PA_ENABLE_DELAY_CYCLES must be at least one clock");
    end

    assign hp_bck = mclk_div[1];
    assign hp_ws  = bit_index[5];
    // Schematic: PA_EN=0 enables the speaker amplifier. Keep it off through
    // reset and a one-time settling interval; this does not affect key latency.
    assign pa_en  = !rst_n || !pa_ready;

    always_comb begin
        if (startup_gain >= 9'd248)
            next_startup_gain = 9'd256;
        else
            next_startup_gain = startup_gain + 9'd8;
        startup_product_left = pcm_left * $signed({1'b0, next_startup_gain});
        startup_product_right = pcm_right * $signed({1'b0, next_startup_gain});
        // Product is Q16.8 at maximum gain; this deliberate slice removes
        // the fractional bits without an implicit-width truncation warning.
        faded_left = startup_product_left[23:8];
        faded_right = startup_product_right[23:8];

        hp_din = 1'b0;
        // Right channel occupies the final 16 bits while WS is low.
        if (bit_index >= 6'd16 && bit_index <= 6'd31)
            hp_din = right_latched[31 - bit_index];
        // Left channel occupies the final 16 bits while WS is high.
        else if (bit_index >= 6'd48)
            hp_din = left_latched[63 - bit_index];
    end

    always_ff @(posedge clk_12m288 or negedge rst_n) begin
        if (!rst_n) begin
            mclk_div      <= '0;
            bit_index     <= '0;
            left_latched <= '0;
            right_latched <= '0;
            pa_delay_count <= '0;
            delay_elapsed  <= 1'b0;
            pa_ready       <= 1'b0;
            startup_gain   <= '0;
        end else begin
            if (!delay_elapsed) begin
                if (pa_delay_count == PA_ENABLE_DELAY_CYCLES - 1)
                    delay_elapsed <= 1'b1;
                else
                    pa_delay_count <= pa_delay_count + 1'b1;
            end
            mclk_div <= mclk_div + 1'b1;
            // Change DIN/WS after BCK falls, leaving half a BCK before capture.
            if (mclk_div == 2'b11) begin
                if (bit_index == 6'd63) begin
                    bit_index      <= '0;
                    if (!delay_elapsed) begin
                        left_latched <= '0;
            right_latched <= '0;
                        startup_gain   <= '0;
                    end else begin
                        // Unmute only on a complete stereo-frame boundary and
                        // fade from 1/32 to unity over 32 following frames.
                        pa_ready       <= 1'b1;
                        startup_gain   <= next_startup_gain;
                        // Both channels are sampled on the same complete-frame boundary.
                        left_latched <= faded_left;
                        right_latched <= faded_right;
                    end
                end else begin
                    bit_index <= bit_index + 1'b1;
                end
            end
        end
    end
endmodule
