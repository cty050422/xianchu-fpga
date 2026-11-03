`timescale 1ns/1ps
module tb_display_trace_engine;
 reg ca=0,cp=0,rst=0,ce=0,start=0,read_valid=0,read_bank=0;
 always #5 ca=~ca;always #7 cp=~cp;
 reg signed[15:0]px=512,py=1024;reg[16:0]addr=0;
 wire ready,busy,done,bank,pixel;
 display_trace_engine dut(.clk_audio(ca),.rst_n(rst),.sample_ce(ce),.pcm_x(px),.pcm_y(py),
  .render_start(start),.display_gain(2'd3),.capture_ready(ready),.render_busy(busy),.render_done(done),.render_bank(bank),
  .clk_pix(cp),.rst_pix_n(rst),.read_bank,.read_addr(addr),.read_valid,.pixel);
 integer checks=0,cycles=0,scenario=0;
 always@(negedge ca)if(rst && dut.state==dut.DRAW && dut.address(dut.xy_kind,dut.lx,dut.ly)>=101017)$fatal(1,"trace address escaped valid frame");
 task getpixel(input integer a,input bit expected);begin
  @(negedge cp);addr=17'(a);read_valid=1;repeat(2)@(negedge cp);
  if(pixel!==expected)$fatal(1,"pixel %d expected %b got %b",a,expected,pixel);checks=checks+1;
 end endtask
 task capture;begin
  for(integer k=0;k<1200;k=k+1)begin
   @(negedge ca);ce=1;
   if(scenario==1)begin py=16'(k-768);px= -py;end
   if(scenario==2)begin px=k<1008?-16'sd32768:16'sd32767;py=k<1072?16'sd32767:-16'sd32768;end
   if(scenario==3)begin px=k[0]?-16'sd32768:16'sd32767;py=k[0]?16'sd32767:-16'sd32768;end
   @(negedge ca);ce=0;repeat(254)@(negedge ca);
  end
  if(!ready)$fatal(1,"capture did not complete");
 end endtask
 task draw;begin
  @(negedge ca);start=1;@(negedge ca);start=0;cycles=0;
  while(!done && cycles<320000)begin @(negedge ca);cycles=cycles+1;end
  if(!done)$fatal(1,"unbounded raster");read_bank=bank;checks=checks+1;
 end endtask
 initial begin
 #30;rst=1;capture();
 for(integer i=0;i<384;i=i+1)if(dut.wave_memory[i]!==16'sd1024)$fatal(1,"uninitialized wave address %d",i);
 for(integer i=0;i<256;i=i+1)if(dut.xy_memory[i]!=={16'd512,16'd1024})$fatal(1,"incoherent XY pair %d",i);
 draw();for(integer x=0;x<384;x=x+1)getpixel(64*384+x,1);
 getpixel(63*384+100,0);getpixel(65*384+100,0);
 getpixel(66048+73*187+103,1);getpixel(66048+73*187+104,0);getpixel(66048+74*187+103,0);
 // A complete second frame must erase the old trace, not accumulate it.
 px=-512;py=-1024;capture();draw();getpixel(64*384+100,0);getpixel(104*384+100,1);
 getpixel(66048+73*187+103,0);getpixel(66048+113*187+83,1);
 scenario=1;capture();
 // Auto-trigger fires at sample767 (-1) one sample before the zero crossing.
 for(integer i=0;i<384;i=i+1)if(dut.wave_memory[i]!==16'(i-1))$fatal(1,"full-rate ramp lost sample %d got %d",i,dut.wave_memory[i]);
 for(integer i=0;i<256;i=i+1)if(dut.xy_memory[(int'(dut.xy_write)+i)&255]!=={16'(-176-i),16'(176+i)})$fatal(1,"coherent chronological ring pair %d",i);
 draw();scenario=2;capture();draw();
 // The L path must not be implicitly closed by a diagonal from last to first.
 getpixel(66048+13*187+93,1);getpixel(66048+93*187+173,1);getpixel(66048+93*187+93,0);
 scenario=3;capture();draw();
 // A steep one-pixel line crosses adjacent columns; it must not fill a rectangle.
 for(integer y=4;y<=164;y=y+1)begin
  if(!(dut.trace_memory[{bank,17'(y*384+99)}]||dut.trace_memory[{bank,17'(y*384+100)}]||dut.trace_memory[{bank,17'(y*384+101)}]))$fatal(1,"gap in steep segment row %d",y);
  checks=checks+1;
 end
 $display("PASS TRACE ENGINE %0d checks, full-rate384/ring256, thin lines, no closure, signed extremes, erase, bounded draw=%0d cycles",checks,cycles);$finish;
 end
 initial begin #40000000;$fatal(1,"timeout");end
endmodule
