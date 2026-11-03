// Minimal 8N1 UART transmitter, used by the diagnostic reporter.
//
// It is deliberately independent of any board: the baud rate is a parameter expressed in
// input clocks, so the same module works from a 50 MHz or a 12.288 MHz clock, and the pin it
// drives is chosen later by whoever verifies the schematic.
//
// Handshake: pulse 'start' with 'data' valid. 'busy' is high while a byte is shifting; a
// start pulse while busy is ignored and REPORTED through 'rejected', so a caller can count
// lost bytes instead of silently dropping them.
module uart_tx #(
    parameter integer CLOCKS_PER_BIT = 107   // 12.288 MHz / 115200 baud
) (
    input  logic       clk,
    input  logic       rst_n,
    input  logic       start,
    input  logic [7:0] data,
    output logic       tx,        // idle high (UART mark level)
    output logic       busy,
    output logic       rejected
);
    localparam logic [1:0] IDLE  = 2'd0;
    localparam logic [1:0] SHIFT = 2'd1;
    localparam logic [1:0] STOP  = 2'd2;

    logic [1:0]  state;
    logic [9:0]  shifter;      // start bit, 8 data bits, stop bit
    logic [3:0]  bit_index;
    logic [15:0] bit_counter;

    assign busy = (state != IDLE);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= IDLE;
            shifter     <= 10'h3FF;
            bit_index   <= 4'd0;
            bit_counter <= 16'd0;
            tx          <= 1'b1;
            rejected    <= 1'b0;
        end else begin
            rejected <= 1'b0;
            case (state)
                IDLE: begin
                    tx <= 1'b1;
                    if (start) begin
                        // start bit (0), data LSB first, stop bit (1)
                        shifter     <= {1'b1, data, 1'b0};
                        bit_index   <= 4'd0;
                        bit_counter <= 16'd0;
                        tx          <= 1'b0;      // the start bit begins immediately
                        state       <= SHIFT;
                    end
                end
                SHIFT: begin
                    if (bit_counter + 16'd1 >= CLOCKS_PER_BIT[15:0]) begin
                        bit_counter <= 16'd0;
                        shifter     <= {1'b1, shifter[9:1]};
                        bit_index   <= bit_index + 4'd1;
                        tx          <= shifter[1];
                        // After the 8th data bit the next bit is the stop bit.
                        // Nine shifts, not eight: the eighth data bit needs its FULL bit period
                        // before the stop level is driven. Ending the shift one bit early made the
                        // last data bit one clock wide, which a real receiver reads wrongly.
                        if (bit_index + 4'd1 >= 4'd9) state <= STOP;
                    end else begin
                        bit_counter <= bit_counter + 16'd1;
                    end
                end
                STOP: begin
                    tx <= 1'b1;
                    if (bit_counter + 16'd1 >= CLOCKS_PER_BIT[15:0]) begin
                        bit_counter <= 16'd0;
                        state       <= IDLE;
                    end else begin
                        bit_counter <= bit_counter + 16'd1;
                    end
                end
                default: state <= IDLE;
            endcase
            if (start && (state != IDLE)) rejected <= 1'b1;
        end
    end
endmodule