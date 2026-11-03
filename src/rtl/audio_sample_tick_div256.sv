module audio_sample_tick_div256 (
    input  logic clk,
    input  logic rst_n,
    output logic sample_ce
);
    logic [7:0] counter;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            counter   <= '0;
            sample_ce <= 1'b0;
        end else begin
            counter   <= counter + 1'b1;
            sample_ce <= (counter == 8'hff);
        end
    end
endmodule
