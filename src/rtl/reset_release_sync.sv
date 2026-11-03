module reset_release_sync (
    input  logic clk,
    input  logic async_rst_n,
    output logic rst_n
);
    logic [1:0] pipe;
    always_ff @(posedge clk or negedge async_rst_n) begin
        if (!async_rst_n)
            pipe <= 2'b00;
        else
            pipe <= {pipe[0], 1'b1};
    end
    assign rst_n = pipe[1];
endmodule
