`timescale 1ns/1ps
module tb_adsr_expressive;
    logic clk = 0, rst_n = 0, sample_ce = 1, gate = 0, retrigger = 0;
    logic [15:0] attack_step = 16'd512, decay_step = 16'd8;
    logic [15:0] sustain_level = 16'd8192, release_step = 16'd4;
    logic [15:0] linear_level, curved_level, prev_curve;
    logic [2:0] linear_state, curved_state;
    integer n, csv;
    always #5 clk = ~clk;

    adsr_envelope linear_env (
        .clk, .rst_n, .sample_ce, .gate, .retrigger,
        .attack_step, .decay_step, .sustain_level, .release_step,
        .level(linear_level), .state(linear_state)
    );
    adsr_envelope #(.CURVED_DECAY_RELEASE(1'b1),
                    .CONTINUOUS_RETRIGGER(1'b1)) curved_env (
        .clk, .rst_n, .sample_ce, .gate, .retrigger,
        .attack_step, .decay_step, .sustain_level, .release_step,
        .level(curved_level), .state(curved_state)
    );

    task automatic tick(input integer sample_index);
        @(posedge clk); #1;
        if ((^linear_level === 1'bx) || (^curved_level === 1'bx))
            $fatal(1, "Unknown ADSR level");
        $fwrite(csv, "%0d,%0d,%0d,%0d,%0d,%0d\n", sample_index, gate,
                linear_level, curved_level, linear_state, curved_state);
    endtask

    initial begin
        csv = $fopen("adsr_compare.csv", "w");
        if (!csv) $fatal(1, "Cannot open trace");
        $fwrite(csv, "sample,gate,linear_level,curved_level,linear_state,curved_state\n");
        repeat (2) @(negedge clk);
        rst_n = 1;
        gate = 1;
        for (n = 0; n < 7300; n = n + 1) begin
            tick(n);
            if (n == 128 && (linear_level != curved_level || curved_level != 16'hffff))
                $fatal(1, "Attack changed");
            if (n == 500 && !(curved_level < linear_level))
                $fatal(1, "Curved decay did not differ");
            if (n > 129 && curved_state == 3'd2 && curved_level > prev_curve)
                $fatal(1, "Curved decay increased");
            prev_curve = curved_level;
        end
        @(negedge clk);
        gate = 0;
        for (n = 7300; n < 10500; n = n + 1) begin
            tick(n);
            if (n == 7500 && !(curved_level < linear_level))
                $fatal(1, "Curved release did not differ");
        end
        if (curved_level != 0 || linear_level != 0)
            $fatal(1, "Release did not reach exact zero");
        @(negedge clk);
        gate = 1;
        for (n = 10500; n < 10540; n = n + 1) tick(n);
        prev_curve = curved_level;
        @(negedge clk);
        retrigger = 1;
        tick(10540);
        if (linear_level != 0 || curved_level != prev_curve)
            $fatal(1, "Retrigger behavior invalid");
        @(negedge clk);
        retrigger = 0;
        tick(10541);
        if (curved_level <= prev_curve)
            $fatal(1, "Candidate did not resume Attack");
        $fclose(csv);
        $display("PASS tb_adsr_expressive: unchanged attack, curved D/R, exact zero, continuous retrigger");
        $finish;
    end
endmodule
