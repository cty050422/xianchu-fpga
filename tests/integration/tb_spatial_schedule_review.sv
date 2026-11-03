`timescale 1ns/1ps
`include "spatial_reverb_reference.sv"
module tb_spatial_schedule_review;
 reg clk=0;always #5 clk=~clk;reg rst_n=0,ce=0;reg signed[15:0]pcm_in=0;reg[7:0]wet=0;reg[1:0]mode=0;
 wire signed[15:0]l,r,m,rl,rr,rm;wire ready,busy,ref_ready,ref_busy;wire[15:0]overrun,clip,stateclip,ro,rc,rsc;wire[7:0]wa,rwa;
 spatial_reverb dut(.clk,.rst_n,.sample_ce(ce),.pcm_in,.wet_target_q8(wet),.mode,.pcm_left(l),.pcm_right(r),.pcm_mono(m),.ready,.busy,.overrun_count(overrun),.clip_count(clip),.state_clip_count(stateclip),.wet_actual(wa));
 spatial_reverb_reference refdut(.clk,.rst_n,.sample_ce(ce),.pcm_in,.wet_target_q8(wet),.mode,.pcm_left(rl),.pcm_right(rr),.pcm_mono(rm),.ready(ref_ready),.busy(ref_busy),.overrun_count(ro),.clip_count(rc),.state_clip_count(rsc),.wet_actual(rwa));
 integer f,seed=123,n,used,peak=0;integer ab;
 initial begin f=$fopen("spatial_equivalence.csv","w");$fwrite(f,"sample,input,left,right,wet,cycles,clip,state_clip\n");
 repeat(3)@(negedge clk);rst_n=1;wait(ready&&ref_ready);
 for(n=0;n<14000;n++)begin
  @(negedge clk);ce=1;
  case(n/2000)0:begin mode=0;wet=0;end 1:begin mode=1;wet=16;end 2:begin mode=1;wet=32;end 3:begin mode=2;wet=64;end 4:begin mode=2;wet=255;end 5:begin mode=0;wet=64;end default:begin mode=2;wet=32;end endcase
  seed=seed*1664525+1013904223;
  if(n>=12000)pcm_in=n<13000?32767:-32768;
  else if(n%2000==0)pcm_in=16000;else if(n%2000<1000)pcm_in=16'((seed>>16)/8);else pcm_in=0;
  @(negedge clk);ce=0;used=0;
  while(busy||ref_busy)begin used++;@(negedge clk);if(used>200)$fatal(1,"sample budget overflow");end
  if({l,r,m,wa,clip,stateclip,overrun}!=={rl,rr,rm,rwa,rc,rsc,ro})$fatal(1,"spatial mismatch n=%0d L=%0d/%0d R=%0d/%0d clip=%0d/%0d state=%0d/%0d",n,l,rl,r,rr,clip,rc,stateclip,rsc);
  if(overrun!==0)$fatal(1,"effect overrun");
  $fwrite(f,"%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",n,pcm_in,l,r,wa,used,clip,stateclip);
  repeat(254-used)@(negedge clk);
 end
 $fclose(f);$display("PASS tb_spatial_schedule_review 14000 sample-exact stereo/wet/clip comparisons, 7 load profiles, no budget overrun");$finish;end
endmodule
