// VESA 640x480 (~59.524Hz with integer25MHz profile) video timing generator (S12).
// Classic, well-documented mode: pixel clock 25 MHz, negative syncs.
// The pixel clock itself comes from a Gowin PLL at synthesis time (documented
// in the profile); this module only counts and shapes the digital timing.
module hdmi_video_timing #(
    parameter integer H_VISIBLE = 640,
    parameter integer H_FRONT   = 16,
    parameter integer H_SYNC    = 96,
    parameter integer H_BACK    = 48,     // total 800
    parameter integer V_VISIBLE = 480,
    parameter integer V_FRONT   = 10,
    parameter integer V_SYNC    = 2,
    parameter integer V_BACK    = 33      // total 525
) (
    input  logic       clk_pix,          // 25 MHz at synthesis
    input  logic       rst_n,
    output logic [9:0] x,                // 0..639 inside the visible area
    output logic [9:0] y,                // 0..479
    output logic       visible,          // inside both visible windows
    output logic       hsync,
    output logic       vsync,
    output logic       frame_start       // one clk pulse at the top-left corner
);
    localparam int H_TOTAL = H_VISIBLE + H_FRONT + H_SYNC + H_BACK;
    localparam int V_TOTAL = V_VISIBLE + V_FRONT + V_SYNC + V_BACK;

    logic [10:0] hc = 0;
    logic [10:0] vc = 0;

    assign hsync = !((hc >= (H_VISIBLE + H_FRONT)) &&
                   (hc <  (H_VISIBLE + H_FRONT + H_SYNC)));      // negative
    assign vsync = !((vc >= (V_VISIBLE + V_FRONT)) &&
                   (vc <  (V_VISIBLE + V_FRONT + V_SYNC)));      // negative
    assign visible = (hc < H_VISIBLE) && (vc < V_VISIBLE);
    assign x = hc[9:0];
    assign y = vc[9:0];
    assign frame_start = visible && (x == 0) && (y == 0);

    always_ff @(posedge clk_pix or negedge rst_n) begin
        if (!rst_n) begin
            hc <= 0; vc <= 0;
        end else begin
            if (hc == H_TOTAL-1) begin
                hc <= 0;
                vc <= (vc == V_TOTAL-1) ? 11'd0 : 11'(vc + 11'd1);
            end else hc <= hc + 11'd1;
        end
    end
endmodule
