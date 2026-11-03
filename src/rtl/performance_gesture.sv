// Config D only. No single click is emitted before double-click resolution.
// A stable two-key press always cancels pending clicks and fires panic immediately.
// Maintenance is available only when a key was held across reset:
// Z2 release -> calibrate, Z1 release -> test. Both held -> neither.
module performance_gesture #(
    parameter integer DEBOUNCE_CYCLES = 61_440,
    parameter integer DOUBLE_CYCLES = 2_457_600,
    parameter integer MAX_PRESS_CYCLES = 6_144_000,
    parameter integer LONG_CYCLES = 12_288_000,
    parameter integer BOOT_CYCLES = 1_228_800
) (
    input logic clk, rst_n,
    input logic [1:0] key_n,
    output logic [5:0] command,
    output logic guide_toggle, test_start,
    output logic practice_toggle,
    output logic test4_start,   // T3: BOTH keys held across reset -> release = four-freq mode
    output logic [1:0] pressed
);
    logic [1:0] synced, stable;
    for (genvar k=0;k<2;k=k+1) begin : keys
        input_sync sync_key(.clk(clk),.async_in(key_n[k]),.sync_out(synced[k]));
        button_debounce #(.STABLE_CYCLES(DEBOUNCE_CYCLES)) db(
            .clk(clk),.rst_n(rst_n),.noisy_in(synced[k]),.stable_out(stable[k]));
    end
    assign pressed = ~stable;
    localparam [2:0] BOOT=0, BOOT_RELEASE=1, IDLE=2, DOWN=3, WAIT_SECOND=4,
                     SECOND_DOWN=5, SUPPRESS=6;
    logic [2:0] state;
    logic owner;
    logic [1:0] boot_keys;
    logic [31:0] timer;
    logic panic_latched;
    wire owner_down = pressed[owner];
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state<=BOOT; timer<=0; boot_keys<=0; owner<=0;
            command<=0; guide_toggle<=0; test_start<=0;practice_toggle<=0; panic_latched<=0;
        end else begin
            command<=0; guide_toggle<=0; test_start<=0;practice_toggle<=0; test4_start<=0;
            if(pressed==0) panic_latched<=0;
            if (state!=BOOT && state!=BOOT_RELEASE && !panic_latched && pressed==2'b11) begin
                panic_latched<=1;
                command[1]<=1; state<=SUPPRESS; timer<=0;
            end else case(state)
                BOOT: begin
                    if(timer>=BOOT_CYCLES-1) begin
                        boot_keys<=pressed; timer<=0;
                        state <= pressed==0 ? IDLE : BOOT_RELEASE;
                    end else timer<=timer+1;
                end
                BOOT_RELEASE: begin
                    if (pressed==2'b11) boot_keys<=2'b11;
                    if (pressed==0) begin
                        if(boot_keys==2'b10) command[2]<=1;
                        if(boot_keys==2'b01) test_start<=1;
                        // Both keys across reset: no maintenance action was assigned to
                        // this combination and it cannot trigger panic (panic needs a
                        // RUN-state double press), so it is the four-frequency entry.
                        if(boot_keys==2'b11) test4_start<=1;
                        state<=IDLE;
                    end
                end
                IDLE: if(pressed!=0) begin
                    owner<=pressed[1]; timer<=0; state<=DOWN;
                end
                DOWN: begin
                    if(!owner_down) begin
                        if(pressed!=0) state<=SUPPRESS;
                        else begin state<=WAIT_SECOND; timer<=0; end
                    end else if(owner && timer>=LONG_CYCLES-1)begin practice_toggle<=1;state<=SUPPRESS;end
                    else if(!owner && timer>=MAX_PRESS_CYCLES-1) state<=SUPPRESS;
                    else timer<=timer+1;
                end
                WAIT_SECOND: begin
                    // Window includes the last timer tick: a second press wins at the boundary.
                    if(owner_down) begin state<=SECOND_DOWN;timer<=0;end
                    else if(pressed!=0) begin
                        // Alternating sticks are separate singles, not a double click.
                        if(owner) command[4]<=1; else command[5]<=1;
                        owner<=pressed[1];timer<=0;state<=DOWN;
                    end else if(timer>=DOUBLE_CYCLES-1) begin
                        if(owner) command[4]<=1; else command[5]<=1;
                        state<=IDLE;timer<=0;
                    end else timer<=timer+1;
                end
                SECOND_DOWN: begin
                    if(!owner_down) begin
                        if(pressed!=0) state<=SUPPRESS;
                        else begin
                            if(owner) guide_toggle<=1; else command[3]<=1;
                            state<=IDLE;timer<=0;
                        end
                    end else if(timer>=MAX_PRESS_CYCLES-1) state<=SUPPRESS;
                    else timer<=timer+1;
                end
                SUPPRESS: if(pressed==0) begin state<=IDLE;timer<=0;end
                default: state<=BOOT;
            endcase
        end
    end
endmodule
