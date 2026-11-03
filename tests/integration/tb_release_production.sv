`timescale 1ns/1ps
module tb_release_production;
 reg clk=0;always #5 clk=~clk;reg rst_n=0,ce=0,ev=0,on=0;reg[1:0]preset=0;reg[63:0]pressure=64'hc000;
 wire[63:0]envelopes,expression;wire[7:0]presets;wire signed[15:0]pcm;wire[3:0]active;
 poly_synth_regions #(.EXPRESSIVE_ADSR(1'b1),.ADSR_ERROR_FEEDBACK(1'b1),.BALANCED_PRESETS(1'b1),.MUSICAL_PRESETS(1'b1))dut(
 .clk,.rst_n,.sample_ce(ce),.event_valid(ev),.event_on(on),.event_region(2'd0),.event_note(7'd60),
 .event_phase_inc(32'h016533c1),.event_preset(preset),.event_generation(8'd1),.region_pressure(pressure),.bend_ratio_q15(16'h8000),
 .pcm_sample(pcm),.voice_envelopes(envelopes),.voice_expression(expression),.voice_presets(presets),.active_voices(active));
 integer f,a,release_samples,nonzero,hold_samples,ix;reg[15:0]last,freeze;reg[1:0]p;
 task sample;begin @(negedge clk);ce=1;@(negedge clk);ce=0;repeat(14)@(negedge clk);end endtask
 task event_note(input bit v);begin @(negedge clk);on=v;ev=1;@(negedge clk);ev=0;repeat(12)@(negedge clk);end endtask
 initial begin
 f=$fopen("production_release.csv","w");a=$fopen("production_audio.csv","w");
 $fwrite(f,"preset,hold_samples,release_samples,release_ms,pcm_nonzero_samples\n");$fwrite(a,"preset,index,pcm,envelope\n");
 for(integer k=0;k<4;k++)for(integer h=0;h<3;h++)begin
  hold_samples=h==0?2400:h==1?24000:96000;ix=0;
  rst_n=0;repeat(3)@(negedge clk);rst_n=1;preset=2'(k);pressure=64'hc000;event_note(1);
  repeat(hold_samples)begin sample();if(h==0)begin $fwrite(a,"%0d,%0d,%0d,%0d\n",k,ix,pcm,envelopes[15:0]);ix++;end end
  if(envelopes[15:0]==0)$fatal(1,"voice not audible before release");
  event_note(0);freeze=expression[15:0];p=presets[1:0];pressure=0;preset=~preset;last=envelopes[15:0];release_samples=0;nonzero=0;
  while(envelopes[15:0]!=0 && release_samples<20000)begin
   sample();release_samples++;if(envelopes[15:0]>last)$fatal(1,"release grew");
   if(expression[15:0]!=freeze || presets[1:0]!=p)$fatal(1,"tail ownership changed");
   if(pcm!=0)nonzero++;last=envelopes[15:0];
   if(h==0)begin $fwrite(a,"%0d,%0d,%0d,%0d\n",k,ix,pcm,envelopes[15:0]);ix++;end
  end
  if(release_samples<20 || release_samples>=20000 || nonzero==0)$fatal(1,"release missing/unbounded");
  repeat(10)sample();if(pcm!=0)$fatal(1,"tail never silent");
  $fwrite(f,"%0d,%0d,%0d,%0f,%0d\n",k,hold_samples,release_samples,release_samples/48.0,nonzero);
 end
 $fclose(f);$fclose(a);$display("PASS tb_release_production 12 cases, musical preset/shift12, monotonic retained tail, final exact zero");$finish;
 end
endmodule
