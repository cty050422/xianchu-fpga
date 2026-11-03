`timescale 1ns/1ps
// ---------------------------------------------------------------------------
// Independent behavioural MCP3208, written from DS21298E section 5.0:
//   edges 1..5 command, edge 6 sample/hold completion (DIN don't care),
//   edge 7 null bit, edges 8..19 B11..B0.
// The model drives DOUT on the SCK falling edge and assumes the master latches on
// the rising edge (SPI mode 0,0, which the datasheet names as supported).
//   late_bit : answer one SCK bit late (a wrong-master-alignment detector)
//   stuck_low: hold DOUT low (a missing or stuck line must not hang the driver)
// ---------------------------------------------------------------------------
module mcp3208_datasheet_model #(
    parameter integer CHANNELS = 5 // default legacy table size; D test supplies all 8 codes
) (
    input  logic        sck,
    input  logic        cs_n,
    input  logic        mosi,
    output logic        miso,
    input  logic        late_bit,
    input  logic        stuck_low,
    input  logic [11:0] code_override,
    input  logic        override_enable,
    // Optional per-channel response table: lets a testbench give every electrode
    // its own level, which a single override value cannot express.
    input  logic [CHANNELS*12-1:0] channel_codes,
    input  logic        use_channel_codes,
    output logic [2:0]  decoded_channel,
    output integer      edge_count,
    output integer      frame_count,
    output integer      protocol_errors,
    output integer      min_sck_period_ns,
    output integer      min_clock_half_ns,
    output integer      min_sucs_ns,
    output integer      min_csh_ns,
    output integer      min_su_ns,
    output integer      min_hd_ns
);
    localparam integer FRAME_EDGES = 19;   // the model's own datasheet constant
    localparam integer T_SCK_MIN  = 1000;
    localparam integer T_HALF_MIN = 500;
    localparam integer T_SUCS_MIN = 100;
    localparam integer T_SU_MIN   = 50;
    localparam integer T_HD_MIN   = 50;
    localparam integer T_CSH_MIN  = 100;

    logic [11:0] code;
    logic [4:0]  command;
    integer      edges;
    integer      last_rise, last_change, last_fall, cs_fall, cs_rise;
    integer      min_period, min_half, min_sucs, min_csh, min_su, min_hd;
    logic        frame_active;

    function automatic logic [11:0] code_for(input logic [2:0] ch);
        begin
            code_for = 12'h800 | ({9'd0, ch} << 6) | 12'h003 | {9'd0, ch};
        end
    endfunction

    // Value the master latches on rising edge r of the current frame.
    function automatic logic bit_for_rising(input integer r);
        integer rr;
        begin
            rr = late_bit ? (r - 1) : r;
            if (stuck_low)               bit_for_rising = 1'b0;
            else if (rr <= 6)            bit_for_rising = 1'b1;   // floating region, driven high on purpose
            else if (rr == 7)            bit_for_rising = 1'b0;   // null bit
            else if (rr <= FRAME_EDGES)  bit_for_rising = code[FRAME_EDGES - rr];
            else                         bit_for_rising = 1'b0;
        end
    endfunction

    initial begin
        miso = 1'b0;
        code = 12'd0;
        command = 5'd0;
        edges = 0;
        decoded_channel = 3'd0;
        edge_count = 0;
        frame_count = 0;
        protocol_errors = 0;
        frame_active = 1'b0;
        last_rise = 0; last_change = 0; last_fall = 0; cs_fall = 0; cs_rise = 0;
        min_period = 1000000; min_half = 1000000; min_sucs = 1000000;
        min_csh = 1000000; min_su = 1000000; min_hd = 1000000;
        min_sck_period_ns = 0; min_clock_half_ns = 0; min_sucs_ns = 0;
        min_csh_ns = 0; min_su_ns = 0; min_hd_ns = 0;
    end

    always @(mosi) last_change = $time;

    always @(negedge cs_n) begin
        edges = 0;
        command = 5'd0;
        code = 12'd0;
        frame_active = 1'b1;
        cs_fall = $time;
        miso = 1'b0;
        if (cs_rise > 0) begin
            if (($time - cs_rise) < T_CSH_MIN) protocol_errors = protocol_errors + 1;
            if (($time - cs_rise) < min_csh) min_csh = $time - cs_rise;
            min_csh_ns = min_csh;
        end
    end

    always @(posedge cs_n) begin
        frame_active = 1'b0;
        cs_rise = $time;
        miso = 1'b0;
    end

    always @(posedge sck) begin
        if (frame_active) begin
            edges = edges + 1;
            edge_count = edges;
            if (last_rise > 0) begin
                if (($time - last_rise) < T_SCK_MIN) protocol_errors = protocol_errors + 1;
                if (($time - last_rise) < min_period) min_period = $time - last_rise;
                min_sck_period_ns = min_period;
            end
            if (edges == 1) begin
                if (($time - cs_fall) < T_SUCS_MIN) protocol_errors = protocol_errors + 1;
                if (($time - cs_fall) < min_sucs) min_sucs = $time - cs_fall;
                min_sucs_ns = min_sucs;
            end
            if (($time - last_change) < T_SU_MIN) protocol_errors = protocol_errors + 1;
            if (($time - last_change) < min_su) min_su = $time - last_change;
            min_su_ns = min_su;
            if (edges <= 5) command = {command[3:0], mosi};
            if (edges == 5) begin
                decoded_channel = command[2:0];
                code = use_channel_codes ? channel_codes[command[2:0]*12 +: 12]
                                         : (override_enable ? code_override : code_for(command[2:0]));
            end
            if (edges == FRAME_EDGES) frame_count = frame_count + 1;
            last_rise = $time;
        end
    end

    always @(negedge sck) begin
        if (frame_active) begin
            if (($time - last_rise) < T_HD_MIN) protocol_errors = protocol_errors + 1;
            if (($time - last_rise) < min_hd) min_hd = $time - last_rise;
            min_hd_ns = min_hd;
            if (($time - last_rise) < T_HALF_MIN) protocol_errors = protocol_errors + 1;
            if (($time - last_rise) < min_half) min_half = $time - last_rise;
            min_clock_half_ns = min_half;
            miso = bit_for_rising(edges + 1);   // DOUT changes on the falling edge
            last_fall = $time;
        end
    end
endmodule

// ---------------------------------------------------------------------------
// Simulation-only stub with the same request interface as mcp3208_adc, used to test
// the scanner's timeout and refusal paths: the real driver always answers, so a
// converter that never responds cannot be produced from it. It is never synthesised
// and never instantiated outside a testbench.
//   answer=1 : completes after LATENCY clocks with a channel-dependent code
//   answer=0 : never completes (the scanner must time the frame out)
//   refuse=1 : reports a refused request instead of accepting it
// ---------------------------------------------------------------------------
module mcp3208_stall_stub #(
    parameter integer LATENCY = 40
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        answer,
    input  logic        refuse,
    input  logic        start,
    input  logic [2:0]  channel,
    output logic [11:0] data,
    output logic        data_valid,
    output logic        busy,
    output logic        request_dropped,
    output logic        request_too_soon
);
    logic [15:0] counter;
    logic        running;
    logic [2:0]  channel_r;

    assign busy = running;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            counter         <= 16'd0;
            running         <= 1'b0;
            channel_r       <= 3'd0;
            data            <= 12'd0;
            data_valid      <= 1'b0;
            request_dropped <= 1'b0;
            request_too_soon <= 1'b0;
        end else begin
            data_valid       <= 1'b0;
            request_dropped  <= 1'b0;
            request_too_soon <= 1'b0;
            if (start && !running && refuse) begin
                request_too_soon <= 1'b1;
            end else if (start && !running) begin
                running   <= 1'b1;
                counter   <= 16'd0;
                channel_r <= channel;
            end else if (start && running) begin
                request_dropped <= 1'b1;
            end
            if (running) begin
                counter <= counter + 16'd1;
                if (answer && (counter + 16'd1 >= LATENCY[15:0])) begin
                    running    <= 1'b0;
                    data       <= 12'h800 | ({9'd0, channel_r} << 6) | 12'h003 | {9'd0, channel_r};
                    data_valid <= 1'b1;
                end
            end
        end
    end
endmodule
