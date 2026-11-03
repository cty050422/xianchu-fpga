// Minimal 8N1 UART receiver. rx is synchronised internally; data_valid is a
// one-clock pulse and framing_error reports a low stop bit.
module uart_rx #(
    parameter integer CLOCKS_PER_BIT = 107
) (
    input  logic       clk,
    input  logic       rst_n,
    input  logic       rx,
    output logic [7:0] data,
    output logic       data_valid,
    output logic       framing_error
);
    localparam integer HALF_BIT = (CLOCKS_PER_BIT < 2) ? 1 : CLOCKS_PER_BIT / 2;
    typedef enum logic [1:0] {IDLE, START, DATA, STOP} state_t;
    state_t state;
    logic rx_meta, rx_sync;
    logic [15:0] clocks;
    logic [2:0] bit_index;
    logic [7:0] shift;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin rx_meta <= 1'b1; rx_sync <= 1'b1; end
        else begin rx_meta <= rx; rx_sync <= rx_meta; end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE; clocks <= 0; bit_index <= 0; shift <= 0;
            data <= 0; data_valid <= 0; framing_error <= 0;
        end else begin
            data_valid <= 1'b0;
            framing_error <= 1'b0;
            case (state)
                IDLE: if (!rx_sync) begin clocks <= 0; state <= START; end
                START: if (clocks == HALF_BIT - 1) begin
                    clocks <= 0;
                    if (!rx_sync) begin bit_index <= 0; state <= DATA; end
                    else state <= IDLE;
                end else clocks <= clocks + 1'b1;
                DATA: if (clocks == CLOCKS_PER_BIT - 1) begin
                    clocks <= 0; shift[bit_index] <= rx_sync;
                    if (bit_index == 3'd7) state <= STOP;
                    else bit_index <= bit_index + 1'b1;
                end else clocks <= clocks + 1'b1;
                STOP: if (clocks == CLOCKS_PER_BIT - 1) begin
                    clocks <= 0; state <= IDLE;
                    if (rx_sync) begin data <= shift; data_valid <= 1'b1; end
                    else framing_error <= 1'b1;
                end else clocks <= clocks + 1'b1;
                default: state <= IDLE;
            endcase
        end
    end
endmodule
