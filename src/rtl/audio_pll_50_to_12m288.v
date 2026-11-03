// GW5AT PLLA: 50 MHz / 2 * 29 / 59 = 12.288135593 MHz (11.035 ppm high).
// Keep the equivalent ratio integer-only so Gowin timing analysis models it correctly.
module audio_pll_50_to_12m288 (
    input  wire clkin_50m,
    output wire clkout_12m288,
    output wire lock
);
    wire clkout1, clkout2, clkout3, clkout4, clkout5, clkout6, clkfbout;
    wire [7:0] mdrdo;
    wire gnd = 1'b0;

    PLLA pll (
        .LOCK(lock), .CLKOUT0(clkout_12m288), .CLKOUT1(clkout1),
        .CLKOUT2(clkout2), .CLKOUT3(clkout3), .CLKOUT4(clkout4),
        .CLKOUT5(clkout5), .CLKOUT6(clkout6), .CLKFBOUT(clkfbout),
        .MDRDO(mdrdo), .CLKIN(clkin_50m), .CLKFB(gnd), .RESET(gnd),
        .PLLPWD(gnd), .RESET_I(gnd), .RESET_O(gnd),
        .PSSEL(3'b000), .PSDIR(gnd), .PSPULSE(gnd),
        .SSCPOL(gnd), .SSCON(gnd), .SSCMDSEL(7'b0000000),
        .SSCMDSEL_FRAC(3'b000), .MDCLK(gnd), .MDOPC(2'b00),
        .MDAINC(gnd), .MDWDI(8'b00000000)
    );

    defparam pll.FCLKIN = "50";
    defparam pll.IDIV_SEL = 2;
    defparam pll.FBDIV_SEL = 1;
    defparam pll.MDIV_SEL = 29;
    defparam pll.MDIV_FRAC_SEL = 0;
    defparam pll.ODIV0_SEL = 59;
    defparam pll.ODIV0_FRAC_SEL = 0;
    defparam pll.ODIV1_SEL = 8;
    defparam pll.ODIV2_SEL = 8;
    defparam pll.ODIV3_SEL = 8;
    defparam pll.ODIV4_SEL = 8;
    defparam pll.ODIV5_SEL = 8;
    defparam pll.ODIV6_SEL = 8;
    defparam pll.CLKOUT0_EN = "TRUE";
    defparam pll.CLKOUT1_EN = "FALSE";
    defparam pll.CLKOUT2_EN = "FALSE";
    defparam pll.CLKOUT3_EN = "FALSE";
    defparam pll.CLKOUT4_EN = "FALSE";
    defparam pll.CLKOUT5_EN = "FALSE";
    defparam pll.CLKOUT6_EN = "FALSE";
    defparam pll.CLKFB_SEL = "INTERNAL";
    defparam pll.CLK0_IN_SEL = 1'b0;
    defparam pll.CLK0_OUT_SEL = 1'b0;
    defparam pll.CLK1_IN_SEL = 1'b0;
    defparam pll.CLK1_OUT_SEL = 1'b0;
    defparam pll.CLK2_IN_SEL = 1'b0;
    defparam pll.CLK2_OUT_SEL = 1'b0;
    defparam pll.CLK3_IN_SEL = 1'b0;
    defparam pll.CLK3_OUT_SEL = 1'b0;
    defparam pll.CLK4_IN_SEL = 2'b00;
    defparam pll.CLK4_OUT_SEL = 1'b0;
    defparam pll.CLK5_IN_SEL = 1'b0;
    defparam pll.CLK5_OUT_SEL = 1'b0;
    defparam pll.CLK6_IN_SEL = 1'b0;
    defparam pll.CLK6_OUT_SEL = 1'b0;
    defparam pll.DYN_DPA_EN = "FALSE";
    defparam pll.CLKOUT0_DT_DIR = 1'b1;
    defparam pll.CLKOUT1_DT_DIR = 1'b1;
    defparam pll.CLKOUT2_DT_DIR = 1'b1;
    defparam pll.CLKOUT3_DT_DIR = 1'b1;
    defparam pll.CLKOUT0_DT_STEP = 0;
    defparam pll.CLKOUT1_DT_STEP = 0;
    defparam pll.CLKOUT2_DT_STEP = 0;
    defparam pll.CLKOUT3_DT_STEP = 0;
    defparam pll.CLKOUT0_PE_COARSE = 0;
    defparam pll.CLKOUT0_PE_FINE = 0;
    defparam pll.CLKOUT1_PE_COARSE = 0;
    defparam pll.CLKOUT1_PE_FINE = 0;
    defparam pll.CLKOUT2_PE_COARSE = 0;
    defparam pll.CLKOUT2_PE_FINE = 0;
    defparam pll.CLKOUT3_PE_COARSE = 0;
    defparam pll.CLKOUT3_PE_FINE = 0;
    defparam pll.CLKOUT4_PE_COARSE = 0;
    defparam pll.CLKOUT4_PE_FINE = 0;
    defparam pll.CLKOUT5_PE_COARSE = 0;
    defparam pll.CLKOUT5_PE_FINE = 0;
    defparam pll.CLKOUT6_PE_COARSE = 0;
    defparam pll.CLKOUT6_PE_FINE = 0;
    defparam pll.DYN_PE0_SEL = "FALSE";
    defparam pll.DYN_PE1_SEL = "FALSE";
    defparam pll.DYN_PE2_SEL = "FALSE";
    defparam pll.DYN_PE3_SEL = "FALSE";
    defparam pll.DYN_PE4_SEL = "FALSE";
    defparam pll.DYN_PE5_SEL = "FALSE";
    defparam pll.DYN_PE6_SEL = "FALSE";
    defparam pll.DE0_EN = "FALSE";
    defparam pll.DE1_EN = "FALSE";
    defparam pll.DE2_EN = "FALSE";
    defparam pll.DE3_EN = "FALSE";
    defparam pll.DE4_EN = "FALSE";
    defparam pll.DE5_EN = "FALSE";
    defparam pll.DE6_EN = "FALSE";
    defparam pll.RESET_I_EN = "FALSE";
    defparam pll.RESET_O_EN = "FALSE";
    defparam pll.ICP_SEL = 6'bXXXXXX;
    defparam pll.LPF_RES = 3'bXXX;
    defparam pll.LPF_CAP = 2'b00;
    defparam pll.SSC_EN = "FALSE";
endmodule
