// T2 performance-event telemetry. Captures the MANUAL note events the FPGA actually
// accepted (arm low while a demo owns the synth, so only player-triggered events are
// recorded) and offers them as versioned 0x85 telemetry frames.
//
// What this is NOT: it is not an event log with guaranteed delivery, not a PCM/audio
// path, and not the retired chat/voice recording service. The frame is a bounded
// snapshot of one accepted event; when the queue is full the event is DROPPED and the
// loss is reported (sticky flag in the next delivered frame + a dropped counter in
// every frame), never silently hidden.
//
// Frame body (8 bytes, one accepted event per frame):
//   byte0 seq        8-bit event sequence, increments per pushed event (wraps)
//   byte1 flags      bit7 note-on, bit6 loss since last delivered frame,
//                    [5:4] region, [3:2] preset, [1:0] zero
//   byte2 note       MIDI note 36..96; a release carries the same note as its press
//   byte3 generation the event's owner generation (8-bit wrap)
//   byte4..6 delta   audio-sample ticks since the previous pushed event (LE24)
//   byte7 dropped    total dropped events, saturating at 255
// The phone rebuilds a relative sample timeline by summing deltas; wall-clock time is
// UI-only and never a substitute for the FPGA sample stamps.
module event_recorder #(
    parameter integer QUEUE_DEPTH = 8
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        sample_ce,
    input  logic        arm,             // 1 = capture manual events (0 = demo owns synth)
    input  logic        event_valid,     // manual event stream (pre-audition-mux)
    input  logic        event_on,
    input  logic [1:0]  event_region,
    input  logic [1:0]  event_preset,
    input  logic [6:0]  event_note,
    input  logic [7:0]  event_generation,
    // ready/length/body/take follow the voice_status_stream handshake
    output logic        ready,
    output logic [5:0]  length,
    output logic [63:0] body,
    input  logic        take,
    output logic [7:0]  dropped,
    output logic [7:0]  seq
);
    localparam integer CW = (QUEUE_DEPTH <= 2) ? 1 : $clog2(QUEUE_DEPTH);

    logic [23:0] sample_counter;
    logic [23:0] last_stamp;
    logic [7:0]  seq_r, dropped_r;
    logic        loss_sticky;
    logic [63:0] q [0:QUEUE_DEPTH-1];
    logic [CW-1:0] head, tail;
    logic [CW:0]   count;
    logic        push, pop;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) sample_counter <= 24'd0;
        else if (sample_ce) sample_counter <= sample_counter + 24'd1;
    end

    assign push     = event_valid && arm;
    assign pop      = ready && take;
    assign ready    = (count != 0);
    assign length   = 6'd8;
    assign body     = (count != 0) ? q[head] : 64'd0;
    assign dropped  = dropped_r;
    assign seq      = seq_r;

    wire [CW:0] count_after_pop = (pop && count != 0) ? count - 1'b1 : count;
    wire        full            = (count_after_pop >= QUEUE_DEPTH[CW:0]);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            seq_r <= 8'd0; dropped_r <= 8'd0; loss_sticky <= 1'b0;
            last_stamp <= 24'd0; head <= '0; tail <= '0; count <= '0;
            for (integer i = 0; i < QUEUE_DEPTH; i = i + 1) q[i] <= 64'd0;
        end else begin
            if (pop) head <= (head == QUEUE_DEPTH-1) ? '0 : head + 1'b1;
            count <= count_after_pop;
            if (push) begin
                if (full) begin
                    // queue full: report the loss, never fake completeness
                    if (dropped_r != 8'hff) dropped_r <= dropped_r + 8'd1;
                    loss_sticky <= 1'b1;
                end else begin
                    q[tail] <= {dropped_r,                            // byte7
                                (sample_counter - last_stamp),        // bytes6..4 LE
                                event_generation,                     // byte3
                                {1'b0, event_note},                   // byte2
                                event_on, loss_sticky,                // byte1: b7 on, b6 loss
                                event_region, event_preset,           //        b5-4 region, b3-2 preset
                                2'b00,                                //        b1-0 zero
                                seq_r};                               // byte0
                    tail <= (tail == QUEUE_DEPTH-1) ? '0 : tail + 1'b1;
                    count <= count_after_pop + 1'b1;
                    seq_r <= seq_r + 8'd1;
                    last_stamp <= sample_counter;
                    loss_sticky <= 1'b0;
                end
            end
        end
    end
endmodule
