// MCP3208 12-bit 8-channel SPI ADC driver (single-ended, SPI mode 0/0).
//
// Electrical assumptions: 3.3 V logic and reference, bounded source impedance.
// Analog settling and physical timing require independent measurement.
// Board pin assignments are defined by the wrapper CST.
//
// FRAME, derived from Microchip DS21298E §5.0 and Figure 5-1 (single-ended):
//
//   "The first clock received with CS low and DIN high will constitute a start bit.
//    The SGL/DIFF bit follows the start bit ... The next three bits (D0, D1 and D2)
//    are used to select the input channel ... Once the D0 bit is input, one more
//    clock is required to complete the sample and hold period (DIN is a 'don't care'
//    for this clock). On the falling edge of the next clock, the device will output a
//    low null bit. The next 12 clocks will output the result of the conversion with
//    MSB first."
//
// Numbering the rising edges from the start bit as edge 1:
//
//   edge 1        : DIN = start bit (1)
//   edge 2        : DIN = SGL/DIFF (1 = single ended)
//   edges 3..5    : DIN = D2 D1 D0 (channel)
//   edge 6        : sample-and-hold completion clock, DIN = don't care
//                   (the datasheet's MCU section calls this the clock after D0)
//   edge 7        : DOUT = null bit (the device drove it on the previous falling edge)
//   edges 8..19   : DOUT = B11 .. B0
//
// 19 rising edges in total, so the conversion result sits in the LAST twelve sampled
// bits. The previous revision of this file used 18 edges (null on edge 6), which is
// one clock early: it collected null+B11..B1 and silently dropped B0. That was a
// deterministic mismatch against the datasheet, found by rebuilding the device model
// from the datasheet instead of from this driver (see sim/tb_mcp3208_adc.sv).
//
// TIMING (DS21298E electrical characteristics; the 2.7 V column is the conservative
// one for a 3.3 V supply):
//   fCLK max            1.0 MHz (2.7 V) / 2.0 MHz (5 V)
//   clock high/low min  500 ns (2.7 V) / 250 ns (5 V)
//   tSUCS (CS fall to first SCK rising edge) min 100 ns
//   tSU  (DIN setup before the SCK rising edge) min 50 ns
//   tHD  (DIN hold after the SCK rising edge)   min 50 ns
//   tCSH (CS high before the next frame)        min 100 ns
//
// This driver is written so that those limits hold by construction, not by luck of
// event scheduling:
//   * MOSI is advanced on the SCK FALLING edge (the state leaves HIGH), so it is
//     stable for a whole low phase (CLK_DIV clocks) before the next rising edge -
//     that is the tSU margin. The previous revision advanced MOSI together with the
//     rising edge, i.e. with zero setup time, which no external device is obliged
//     to accept.
//   * SCK = clk / (2 * CLK_DIV). At the 12.288 MHz audio clock, CLK_DIV = 8 gives a
//     768 kHz clock with 651 ns high and low phases: inside the 2.7 V limits.
//   * CS stays low for SETTLE_CYCLES before the first rising edge (tSUCS) and high
//     for CS_HIGH_CYCLES after the frame (tCSH). A request that arrives too early is
//     refused and reported - it is never silently started with a short CS high time.
//
// OCCUPANCY (why this is not "one conversion per audio sample"):
//   one frame = 2 * CLK_DIV * 19 + SETTLE_CYCLES + CS_HIGH_CYCLES
//             = 2*8*19 + 64 + 16 = 384 clk cycles = 31.25 us at 12.288 MHz.
//   Five channels (the four pressure zones plus the thumb axis) therefore take
//   about 156 us per scan frame, i.e. ~6.4 kscan/s and ~1.28 ksample/s per channel.
//   That meets the M1 budget of about 1 kHz per channel, and it is well inside the
//   device's 50 ksps (2.7 V) limit. It is NOT one conversion per 48 kHz audio
//   sample, and any comment or document claiming that is wrong.
module mcp3208_adc #(
    parameter integer CLK_DIV        = 8,  // SCK half period in clk cycles (>= 7 at 12.288 MHz for 1 MHz SCK)
    parameter integer SETTLE_CYCLES  = 64, // CS falling edge to first SCK rising edge (tSUCS)
    parameter integer CS_HIGH_CYCLES = 16  // minimum CS high time before the next frame (tCSH)
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        start,           // one-clock request; refused (and reported) while not ready
    input  logic [2:0]  channel,
    output logic        sck,             // idle low (mode 0)
    output logic        mosi,
    output logic        cs_n,
    input  logic        miso,
    output logic [11:0] data,
    output logic        data_valid,      // one-clock pulse with a fresh conversion
    output logic        busy,            // frame or CS-high hold-off in progress
    output logic        request_dropped, // 'start' arrived during a frame
    output logic        request_too_soon // 'start' arrived inside the CS-high hold-off
);
    localparam integer FRAME_BITS = 19;

    localparam logic [2:0] IDLE   = 3'd0;
    localparam logic [2:0] LEAD   = 3'd1;  // CS low, waiting for tSUCS
    localparam logic [2:0] HIGH   = 3'd2;  // SCK high for CLK_DIV clocks
    localparam logic [2:0] LOW    = 3'd3;  // SCK low for CLK_DIV clocks, MOSI advances
    localparam logic [2:0] HOLD   = 3'd4;  // CS high, tCSH hold-off before the next frame
    localparam logic [2:0] FINISH = 3'd5;  // data_valid pulse

    // SCK and CS are REGISTERED outputs. A combinational "assign cs_n = (state != ...)"
    // is not only a glitch risk on a real board, it also produced zero-width CS pulses
    // in simulation, which the device model correctly refused to treat as one frame.
    logic [2:0]  state;
    logic [15:0] phase_counter;
    logic [4:0]  bit_index;
    logic [18:0] tx_shift;
    logic [18:0] rx_shift;
    logic        sck_r;
    logic        cs_n_r;

    assign sck  = sck_r;
    assign mosi = tx_shift[18];
    assign cs_n = cs_n_r;
    assign busy = (state != IDLE);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state            <= IDLE;
            phase_counter    <= 16'd0;
            bit_index        <= 5'd0;
            tx_shift         <= 19'd0;
            rx_shift         <= 19'd0;
            sck_r            <= 1'b0;
            cs_n_r           <= 1'b1;
            data             <= 12'd0;
            data_valid       <= 1'b0;
            request_dropped  <= 1'b0;
            request_too_soon <= 1'b0;
        end else begin
            data_valid       <= 1'b0;
            request_dropped  <= 1'b0;
            request_too_soon <= 1'b0;
            case (state)
                IDLE: begin
                    phase_counter <= 16'd0;
                    bit_index     <= 5'd0;
                    if (start) begin
                        // 19 bits: start, SGL/DIFF, channel, the sample-and-hold
                        // completion clock, the null-bit clock, then twelve don't-care
                        // clocks while the device shifts B11..B0 back.
                        tx_shift <= {1'b1, 1'b1, channel, 1'b0, 1'b0, 12'd0};
                        rx_shift <= 19'd0;
                        sck_r    <= 1'b0;
                        cs_n_r   <= 1'b0;
                        state    <= LEAD;
                    end
                end
                LEAD: begin
                    // CS is already low. Raise SCK after tSUCS and take the first sample
                    // in the same clock: the device drove that bit on the previous
                    // falling edge, so it is stable long before the rising edge.
                    if (phase_counter + 16'd1 >= SETTLE_CYCLES[15:0]) begin
                        phase_counter <= 16'd0;
                        sck_r         <= 1'b1;
                        rx_shift      <= {rx_shift[17:0], miso};
                        state         <= HIGH;
                    end else begin
                        phase_counter <= phase_counter + 16'd1;
                    end
                end
                HIGH: begin
                    // SCK is high. Lower it after CLK_DIV clocks; MOSI advances with the
                    // falling edge, so it stays stable for the whole low phase before the
                    // device latches it on the next rising edge (tSU = one half period).
                    if (phase_counter + 16'd1 >= CLK_DIV[15:0]) begin
                        phase_counter <= 16'd0;
                        sck_r         <= 1'b0;
                        tx_shift      <= {tx_shift[17:0], 1'b0};
                        state         <= LOW;
                    end else begin
                        phase_counter <= phase_counter + 16'd1;
                    end
                end
                LOW: begin
                    if (phase_counter + 16'd1 >= CLK_DIV[15:0]) begin
                        phase_counter <= 16'd0;
                        if (bit_index + 5'd1 >= FRAME_BITS[4:0]) begin
                            // All 19 edges are done: release CS and hold it high (tCSH).
                            bit_index <= 5'd0;
                            cs_n_r    <= 1'b1;
                            state     <= HOLD;
                        end else begin
                            bit_index <= bit_index + 5'd1;
                            sck_r     <= 1'b1;
                            rx_shift  <= {rx_shift[17:0], miso};  // sample on the rising edge
                            state     <= HIGH;
                        end
                    end else begin
                        phase_counter <= phase_counter + 16'd1;
                    end
                end
                HOLD: begin
                    // CS stays high for the whole hold-off; a request arriving here is
                    // reported instead of shortening tCSH.
                    if (phase_counter + 16'd1 >= CS_HIGH_CYCLES[15:0]) begin
                        phase_counter <= 16'd0;
                        state         <= FINISH;
                    end else begin
                        phase_counter <= phase_counter + 16'd1;
                    end
                end
                FINISH: begin
                    data       <= rx_shift[11:0];
                    data_valid <= 1'b1;
                    state      <= IDLE;
                end
                default: state <= IDLE;
            endcase
            // Refusals are reported, never queued: a dropped request during a frame is
            // a different condition from a request inside the CS-high hold-off.
            if (start) begin
                case (state)
                    IDLE: begin end
                    HOLD: request_too_soon <= 1'b1;
                    default: request_dropped <= 1'b1;
                endcase
            end
        end
    end
endmodule
