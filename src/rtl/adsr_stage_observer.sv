// Passive per-voice ADSR stage timing. Counts actual sample_ce updates while
// the PRE-UPDATE envelope state is A/D/R, not wall-clock key hold duration.
// Transition recognition runs every clk so the last update is already counted.
// valid[0/1/2] means A->D / D->S / R->IDLE completed in this note epoch.
// Short notes retain partial residence counts but never claim completed stages.
module adsr_stage_observer (
    input  logic clk, rst_n, sample_ce,
    input  logic [2:0] state,
    input  logic gate, retrigger,
    input  logic [1:0] preset,
    input  logic [7:0] model,
    output logic [15:0] attack_count, decay_count, release_count,
    output logic [2:0] valid, overflow,
    output logic [7:0] event_count,
    output logic done,
    output logic [1:0] captured_preset,
    output logic [7:0] captured_model
);
    localparam logic [2:0] IDLE=0, ATTACK=1, DECAY=2, SUSTAIN=3, RELEASE=4;
    logic gate_d, active_epoch;
    logic [2:0] state_d;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            gate_d <= 0; state_d <= IDLE; active_epoch <= 0;
            attack_count <= 0; decay_count <= 0; release_count <= 0;
            valid <= 0; overflow <= 0; event_count <= 0; done <= 0;
            captured_preset <= 0; captured_model <= 0;
        end else begin
            gate_d <= gate;
            state_d <= state;
            if (retrigger || (gate && !gate_d)) begin
                active_epoch <= 1;
                attack_count <= 0; decay_count <= 0; release_count <= 0;
                valid <= 0; overflow <= 0; done <= 0;
                event_count <= event_count + 1'b1;
                captured_preset <= preset; captured_model <= model;
            end else if (active_epoch && !done) begin
                if (state_d==ATTACK && state==DECAY) valid[0] <= 1;
                if (state_d==DECAY && state==SUSTAIN) valid[1] <= 1;
                if (state_d==RELEASE && state==IDLE) begin
                    valid[2] <= 1;
                    done <= 1;
                end
                // Envelope gate edges have priority over its sample update.
                // Do not charge the interrupted stage for that skipped sample.
                if (sample_ce && gate==gate_d) begin
                    case (state)
                        ATTACK: if (&attack_count) overflow[0] <= 1;
                                else attack_count <= attack_count + 1'b1;
                        DECAY: if (&decay_count) overflow[1] <= 1;
                               else decay_count <= decay_count + 1'b1;
                        RELEASE: if (&release_count) overflow[2] <= 1;
                                 else release_count <= release_count + 1'b1;
                        default: ;
                    endcase
                end
            end
        end
    end
endmodule
