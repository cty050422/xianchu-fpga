`timescale 1ns/1ps
module tb_display_scale;
 reg ca=0,cp=0;always #5 ca=~ca;always #7 cp=~cp;
 reg rst=0,ce=0,fs=0;wire pixel,ready;wire[1:0]gain;
 display_capture dut(.clk_audio(ca),.rst_audio_n(rst),.sample_ce(ce),.pcm_x(16'sd512),.pcm_y(16'sd1024),.voice_samples(64'd0),.mode(2'd0),.preset(2'd0),.step(6'd0),.target(4'd0),.wrong(16'd0),.clk_pix(cp),.rst_pix_n(rst),.frame_start(fs),.pixel_x(10'd100),.pixel_y(10'd194),.trace_pixel(pixel),.video_ready(ready),.video_gain(gain));
 initial begin
 #30;rst=1;repeat(1800)begin @(negedge ca);ce=1;@(negedge ca);ce=0;end
 wait(dut.req==1);repeat(5)@(negedge cp);fs=1;@(negedge cp);fs=0;repeat(5)@(negedge cp);
 if(!ready||gain!==3||pixel!==1)$fatal(1,"weak display scale or sync pixel failed");
 if(dut.traces.xy_origin!==dut.traces.xy_write)$fatal(1,"ring not frozen during draw");
 if(dut.choose_gain(16'd4000,2'd3)!==3||dut.choose_gain(16'd4000,2'd2)!==2||dut.choose_gain(16'd4200,2'd3)!==2||dut.choose_gain(16'd3400,2'd2)!==3)$fatal(1,"range hysteresis");
 $display("PASS DISPLAY SCALE: shared gain, late coordinate conversion, coherent XY and hysteresis");$finish;
 end
 initial begin #10000000;$fatal(1,"timeout");end
endmodule
