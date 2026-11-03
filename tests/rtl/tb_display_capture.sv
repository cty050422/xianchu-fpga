`timescale 1ns/1ps
module tb_display_capture;
 reg ca=0,cp=0;always #40.69 ca=~ca;always #19.84 cp=~cp;
 reg ra=0,rp=0;integer n=0,divider=0,frames=0,accepted=0;
 reg sample_ce=0;reg signed [15:0] px=0,py=0;
 wire [9:0] x,y;wire visible,hs,vs,fs;
 hdmi_video_timing timing(.clk_pix(cp),.rst_n(rp),.x,.y,.visible,.hsync(hs),.vsync(vs),.frame_start(fs));
 wire[1023:0]spec;wire[63:0] levels;wire trace_pixel,video_ready;wire[1:0]gain;
 wire[1:0] mode,preset;wire[5:0] step;wire[3:0] target;wire[15:0] wrong;
 display_capture dut(.clk_audio(ca),.rst_audio_n(ra),.sample_ce,.pcm_x(px),.pcm_y(py),
 .voice_samples({16'd0,16'd100,16'd3800,16'd4200}),.mode(2'd1),.preset(2'd2),.step(6'd31),.target(4'd5),.wrong(16'd12),
 .clk_pix(cp),.rst_pix_n(rp),.frame_start(fs),.pixel_x(x),.pixel_y(y),.trace_pixel,.video_ready,.video_gain(gain),.video_spectrum(spec),
 .video_levels(levels),.video_mode(mode),.video_preset(preset),.video_step(step),.video_target(target),.video_wrong(wrong));
 wire[7:0] r,g,b;
 reg[9:0]xd,yd;reg vd;
 always@(posedge cp)begin xd<=x;yd<=y;vd<=visible;end
 display_dashboard dash(.clk_pix(cp),.rst_n(rp),.x(xd),.y(yd),.visible(vd),.trace_pixel,.display_gain(gain),.spectrum(spec),.levels,
 .mode,.preset,.step,.target,.wrong,.r,.g,.b);
 // Independent color/address oracle for both trace panels, including their
 // boundaries and grids. Raw coordinates/data pass exactly three pixel stages.
 reg[23:0]expected[0:2];reg[2:0]check_pixel=0;integer aligned=0;
 function automatic[23:0]reference_pixel(input integer ax,ay);
  reg[23:0]color;reg bit_on;integer address;
  begin color=24'h101a1d;bit_on=0;address=0;
   if(ax>=20 && ax<404 && ay>=130 && ay<302)begin
    if(ay==214 || ((ax-20)%48)==0 || ay==166 || ay==262)color=24'h1f2f31;
    address=(ay-130)*384+ax-20;
    if(video_ready)bit_on=dut.traces.trace_memory[{dut.front_bank,17'(address)}];
    if(bit_on)color=24'he9c272;
   end else begin
    if(ax==523 || ay==207 || ax==430 || ax==616 || ay==114 || ay==300)color=24'h283739;
    address=66048+(ay-114)*187+ax-430;
    if(video_ready)bit_on=dut.traces.trace_memory[{dut.front_bank,17'(address)}];
    if(bit_on)color=24'hb7a3e0;
   end
   reference_pixel=color;
  end
 endfunction
 always@(posedge cp)begin
  expected[0]<=reference_pixel(x,y);expected[1]<=expected[0];expected[2]<=expected[1];
  check_pixel<={check_pixel[1:0],rp && visible && ((x>=20 && x<404 && y>=130 && y<302)||(x>=430 && x<=616 && y>=114 && y<=300))};
 end
 always@(negedge cp)if(check_pixel[2])begin
  if({r,g,b}!==expected[2])$fatal(1,"RGB/trace alignment actual=%h expected=%h",{r,g,b},expected[2]);aligned=aligned+1;
 end
 always @(negedge ca) if(ra)begin
   sample_ce=(divider==255);
   if(divider==255)begin
     divider=0;n=n+1;px=$rtoi(10000*$sin(6.283185307*937.5*n/48000));py=$rtoi(10000*$cos(6.283185307*937.5*n/48000));
   end else divider=divider+1;
 end
 always @(posedge ca)if(sample_ce)accepted<=accepted+1;
 integer fd;reg[2:0] pv;integer frameid=0;integer trace_count=0;
 always @(posedge cp)begin
   pv<={pv[1:0],visible};
   if(rp && fs)frameid<=frameid+1;
 end
 always @(negedge cp)if(frameid==4 && pv[2])begin $fwrite(fd,"%c%c%c",r,g,b);if(trace_pixel)trace_count=trace_count+1;end
 initial begin
   fd=$fopen("display_frame.ppm","wb");$fwrite(fd,"P6\n640 480\n255\n");
   #100;ra=1;
   // Video held in reset while audio/FFT continue, then release at unrelated phase.
   wait(accepted==2100);if(n<2100)$fatal(1,"audio observer stalled");
   #77;rp=1;wait(frameid==5);#100;
   if({mode,preset,step,target,wrong}!=={2'd1,2'd2,6'd31,4'd5,16'd12})$fatal(1,"torn CDC state");
   if(levels[15:0]!=4200 || levels[31:16]!=3800 || levels[47:32]!=100 || levels[63:48]!=0)$fatal(1,"postgain meters");
   if(spec[20*8+:8]<=spec[40*8+:8])$fatal(1,"FFT tone not present in streamed public bins");
   if(!video_ready || trace_count<500 || aligned<100000)$fatal(1,"missing real PCM trace pixels %d",trace_count);
   $fclose(fd);$display("PASS DISPLAY: full-rate PCM384/XY256, FFT1024, coherent CDC, audio continues while video reset, trace pixels=%0d aligned pixels=%0d",trace_count,aligned);$finish;
 end
 initial begin #200000000;$fatal(1,"display timeout");end
endmodule
