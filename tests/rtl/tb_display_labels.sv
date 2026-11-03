`timescale 1ns/1ps
module tb_display_labels;
 reg clk=0;always #5 clk=~clk;reg rst=0;reg[9:0]x=400,y=460;reg lv=1;reg[1:0]mode=0;
 wire[7:0]r,g,b;
 display_dashboard dut(.clk_pix(clk),.rst_n(rst),.x,.y,.visible(1'b1),.trace_pixel(1'b0),.spectrum(1024'd0),.levels(64'd0),.mode,.preset(2'd2),.step(6'd0),.target(4'd0),.wrong(16'd0),.latency_valid(lv),.latency_us(16'd1234),.display_gain(2'd3),.r,.g,.b);
 initial begin
 #12;rst=1;#10;
 if(dut.text_line[191:152]!=="01234")$fatal(1,"decimal digital latency field misplaced");
 if(dut.text_line[143:128]!=="us")$fatal(1,"latency units must remain microseconds");
 lv=0;#2;if(dut.text_line[191:152]!=="-----")$fatal(1,"missing digital measure must be dashes");
 x=20;y=40;mode=3;#2;if(dut.zh_line==0)$fatal(1,"Chinese audition mode label missing");
 x=116;y=112;#2;if(dut.text_line[71:64]!=="8")$fatal(1,"display gain label");
 $display("PASS DISPLAY LABELS: decimal us, unavailable dashes, audition, display-only gain");$finish;
 end
endmodule
