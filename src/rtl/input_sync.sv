module input_sync (
    input  logic clk,
    input  logic async_in,
    output logic sync_out
);
    logic meta;
    always_ff @(posedge clk) begin
        meta     <= async_in;
        sync_out <= meta;
    end
endmodule
