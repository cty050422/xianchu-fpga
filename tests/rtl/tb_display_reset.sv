`timescale 1ns/1ps
module tb_display_reset;
 reg ca=0,cp=0,pix_running=1;always #5 ca=~ca;always #7 if(pix_running)cp=~cp;
 reg ra=0,rp=0,ce=0;reg[9:0]pix_count=0;reg fs=0;integer divider=0,accepted=0;
 wire ready,pixel;wire[1:0]gain;reg[1:0]mode_value=0;
 display_capture dut(.clk_audio(ca),.rst_audio_n(ra),.sample_ce(ce),.pcm_x(16'sd512),.pcm_y(16'sd1024),.voice_samples(64'd0),
  .mode(mode_value),.preset(2'd0),.step(6'd0),.target(4'd0),.wrong(16'd0),
  .clk_pix(cp),.rst_pix_n(rp),.frame_start(fs),.pixel_x(10'd100),.pixel_y(10'd194),.trace_pixel(pixel),.video_ready(ready),.video_gain(gain));
 always@(negedge ca)begin ce=divider==0;divider=(divider+1)%4;if(ce)accepted=accepted+1;end
 always@(negedge cp)begin pix_count<=pix_count+10'd1;fs<=pix_count==0;end
 always@(negedge ca)if(ready && dut.render_busy && dut.render_bank==dut.front_bank)$fatal(1,"writing displayed bank");
 wire[113:0]descriptor={dut.front_bank,dut.video_gain,dut.video_levels,dut.video_mode,dut.video_preset,dut.video_step,dut.video_target,dut.video_wrong,dut.video_latency_valid,dut.video_latency_us};
 reg[113:0]previous_descriptor;reg previous_ready=0,frame_allowed=0;
 always@(posedge cp)frame_allowed<=fs;
 always@(negedge cp)begin
  if(ready && previous_ready && descriptor!==previous_descriptor && !frame_allowed)$fatal(1,"descriptor changed inside frame");
  previous_descriptor<=descriptor;previous_ready<=ready;
 end
 integer count_before,checks=0;reg held_bank;reg[113:0]held_descriptor;
 task await_frame;begin
  wait(ready);repeat(4)@(negedge cp);
  if(gain!==3 || pixel!==1)$fatal(1,"published partial/uninitialized frame");checks=checks+1;
 end endtask
 task reset_check(input bit reset_pixel);begin
  if(reset_pixel)rp=0;else ra=0;#3;
  if(ready!==0 || pixel!==0)$fatal(1,"reset failed to blank observer");
  #53;if(reset_pixel)rp=1;else ra=1;await_frame();
 end endtask
 initial begin
 #30;ra=1;rp=1;await_frame();reset_check(1);reset_check(0);
 wait(dut.traces.state==dut.traces.CLEAR);reset_check(1);
 wait(dut.traces.state==dut.traces.DRAW);reset_check(0);
 // Paused video cannot acknowledge. Audio keeps accepting samples; back stays back.
 @(negedge cp);pix_running=0;count_before=accepted;#2500000;
 if(accepted-count_before<50000)$fatal(1,"producer stopped when video paused");
 held_bank=dut.front_bank;held_descriptor=descriptor;mode_value=1;#2500000;
 if(dut.front_bank!==held_bank || descriptor!==held_descriptor)$fatal(1,"paused video descriptor mutated");
 pix_running=1;wait(dut.video_mode==1);repeat(4)@(negedge cp);checks=checks+1;
 // Pause a second time, then reset with the destination clock still stopped.
 @(negedge cp);pix_running=0;
 // Also exercise a video reset that entirely occurs with its clock stopped.
 rp=0;#3;if(ready!==0 || pixel!==0)$fatal(1,"stopped-clock reset blanking");#53;rp=1;#200;pix_running=1;await_frame();
 $display("PASS DISPLAY RESET %0d frames, independent mid-clear/mid-line resets, stopped pixel clock, bank ownership",checks);$finish;
 end
 initial begin #30000000;$fatal(1,"reset test timeout");end
endmodule
