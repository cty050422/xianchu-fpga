// Five-channel scan engine for the MCP3208 expression input (M1).
//
// One scan frame converts CH0..CH(CHANNELS-1) in order and publishes each result with
// a LATCHED channel id and the frame id, so the consumer never has to guess which
// electrode a value belongs to. DESIGN BUDGET, measured by sim/tb_mcp3208_scanner.sv:
// one conversion is ~387 clk (31.5 us at 12.288 MHz), so five channels cost ~1935 clk
// (157.5 us) and a 1 ms frame leaves ~84% of the frame as margin - about 1 kHz per
// channel, which is the M1 requirement. The previous free-running trigger converted
// one channel at 4.8 kHz and could not express per-zone pressure at all.
//
// The scanner never assumes that a conversion succeeded: a request is only issued when
// the driver reports itself idle, refusals are counted, and a frame that does not
// complete inside FRAME_TIMEOUT is closed as incomplete (timeouts counted) so the
// consumer can age the stale channels instead of treating a missing sample as zero.
//
// The scanner talks to a generic conversion interface, so the timeout and refusal paths
// can be tested with a stub; mcp3208_scan_engine wraps it around the real SPI driver.
//
// The scanner is deliberately protocol-only: calibration, hysteresis, per-zone
// expression and health live in rtl/zone_bank.sv, and note ownership lives in the M2
// event path. This module contains no board pin.
module mcp3208_scanner #(
    parameter integer CHANNELS      = 5,       // CH0..CH3 zones, CH4 thumb axis
    parameter integer SCAN_INTERVAL = 12_288,  // clk cycles between scan frames (1 ms)
    parameter integer FRAME_TIMEOUT = 4_096,   // clk cycles allowed for one whole frame
    parameter integer ADC_CLK_DIV   = 8,
    parameter integer ADC_SETTLE    = 64,
    parameter integer ADC_CS_HIGH   = 16
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        enable,              // 0 = no conversions at all
    // Generic conversion request interface (the driver lives in mcp3208_scan_engine).
    output logic        adc_start,           // one-clock request
    output logic [2:0]  adc_channel,         // channel asked for in this request
    input  logic        adc_busy,
    input  logic        adc_data_valid,
    input  logic [11:0] adc_data,
    input  logic        adc_dropped,
    input  logic        adc_too_soon,
    // Streaming result: one pulse per conversion, tagged with channel and frame.
    output logic [2:0]  channel_id,
    output logic [11:0] code,
    output logic        code_valid,
    output logic [7:0]  frame_id,
    output logic [7:0]  channel_seen,        // bitmap of channels updated this frame
    output logic        frame_done,          // one-clock pulse: the frame is committed
    output logic        frame_incomplete,    // valid with frame_done
    output logic [15:0] frame_clocks,        // measured length of the closed frame
    output logic [15:0] frame_skew_clocks,   // first to last conversion inside the frame
    output logic        scan_busy,
    output logic [15:0] refused_requests,    // driver refused a request (retried)
    output logic [15:0] timeouts             // frames closed without all channels
);
    localparam logic [1:0] ST_IDLE = 2'd0;   // waiting for the next scan interval
    localparam logic [1:0] ST_REQ  = 2'd1;   // waiting for the driver to be idle
    localparam logic [1:0] ST_WAIT = 2'd2;   // conversion running
    localparam logic [1:0] ST_DONE = 2'd3;   // publish the frame result

    // Avoid width truncation at CHANNELS=8: (8'h01 << 8) is zero in some tools,
    // and CHANNELS[2:0] also wraps 8 to zero.  The scanner supports all MCP3208 inputs.
    localparam logic [7:0] ALL_SEEN = (CHANNELS >= 8) ? 8'hFF : ((8'h01 << CHANNELS) - 8'h01);
    localparam logic [2:0] LAST_CHANNEL = CHANNELS - 1;

    logic [1:0]  state;
    logic [15:0] clk_counter;        // free-running, used for measured intervals
    logic [15:0] wait_counter;
    logic [2:0]  index;
    logic [7:0]  seen;
    logic [7:0]  frame_r;
    logic [15:0] frame_start;
    logic [15:0] skew_r;
    logic [11:0] code_r;
    logic [2:0]  channel_r;
    logic        incomplete_r;

    assign scan_busy      = (state != ST_IDLE);
    assign adc_channel    = index;
    assign channel_id     = channel_r;
    assign code           = code_r;
    assign frame_id       = frame_r;
    assign channel_seen   = seen;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state             <= ST_IDLE;
            clk_counter       <= 16'd0;
            wait_counter      <= 16'd0;
            index             <= 3'd0;
            seen              <= 8'd0;
            frame_r           <= 8'd0;
            frame_start       <= 16'd0;
            skew_r            <= 16'd0;
            code_r            <= 12'd0;
            channel_r         <= 3'd0;
            adc_start         <= 1'b0;
            code_valid        <= 1'b0;
            frame_done        <= 1'b0;
            frame_incomplete  <= 1'b0;
            frame_clocks      <= 16'd0;
            frame_skew_clocks <= 16'd0;
            refused_requests  <= 16'd0;
            timeouts          <= 16'd0;
            incomplete_r      <= 1'b0;
        end else begin
            clk_counter  <= clk_counter + 16'd1;
            adc_start    <= 1'b0;
            code_valid   <= 1'b0;
            frame_done   <= 1'b0;
            case (state)
                ST_IDLE: begin
                    // The scan period is measured from frame start to frame start, so the
                    // per-channel rate is 1/SCAN_INTERVAL and the conversion time is
                    // absorbed inside the frame instead of extending it.
                    if (enable && !adc_busy && ((clk_counter - frame_start) >= SCAN_INTERVAL[15:0])) begin
                        seen          <= 8'd0;
                        index         <= 3'd0;
                        wait_counter  <= 16'd0;
                        frame_start   <= clk_counter;
                        skew_r        <= 16'd0;
                        incomplete_r  <= 1'b0;
                        frame_r       <= frame_r + 8'd1;
                        state         <= ST_REQ;
                    end
                end
                ST_REQ: begin
                    // Only ask a driver that reports itself idle; a refusal is counted
                    // and retried instead of silently dropping the channel.
                    if (adc_dropped || adc_too_soon) refused_requests <= refused_requests + 16'd1;
                    if (!adc_busy) begin
                        adc_start <= 1'b1;
                        state     <= ST_WAIT;
                    end
                end
                ST_WAIT: begin
                    if (adc_dropped || adc_too_soon) refused_requests <= refused_requests + 16'd1;
                    wait_counter <= wait_counter + 16'd1;
                    if (adc_data_valid) begin
                        code_r      <= adc_data;
                        channel_r   <= index;
                        code_valid  <= 1'b1;
                        seen[index] <= 1'b1;
                        skew_r      <= clk_counter - frame_start;
                        if (index >= LAST_CHANNEL) begin
                            state <= ST_DONE;
                        end else begin
                            index <= index + 3'd1;
                            state <= ST_REQ;
                        end
                    end else if (wait_counter + 16'd1 >= FRAME_TIMEOUT[15:0]) begin
                        // The converter never answered: close the frame as incomplete so
                        // the consumer ages the channels instead of reading a zero.
                        timeouts     <= timeouts + 16'd1;
                        incomplete_r <= 1'b1;
                        state        <= ST_DONE;
                    end
                end
                ST_DONE: begin
                    frame_done        <= 1'b1;
                    frame_incomplete  <= incomplete_r || (seen != ALL_SEEN);
                    frame_clocks      <= clk_counter - frame_start;
                    frame_skew_clocks <= skew_r;
                    state             <= ST_IDLE;
                end
                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
