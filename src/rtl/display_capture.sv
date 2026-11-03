// Read-only observer: contiguous PCM traces, FFT and atomic frame descriptors.
// Either observer-side reset discards observation history in BOTH domains.
// This reset never feeds the audio core. RAM is hidden until fully redrawn.
module display_capture(
 input logic clk_audio,rst_audio_n,sample_ce,
 input logic signed[15:0]pcm_x,pcm_y,input logic[63:0]voice_samples,
 input logic[3:0]note_on=4'd0,voice_gates=4'd0,
 input logic[7:0]voice_regions=8'd0,input logic group_b=1'b0,
 input logic measure_enable=1'b0,serial_bck=1'b0,serial_ws=1'b0,serial_din=1'b0,
 input logic[2:0]transport=3'd0,input logic score_valid=1'b0,octave=1'b0,
 input logic[1:0]mode,preset,input logic[5:0]step,input logic[3:0]target,input logic[15:0]wrong,
 input logic clk_pix,rst_pix_n,frame_start,input logic[9:0]pixel_x,pixel_y,
 output wire trace_pixel,
 output logic[1023:0]video_spectrum,output logic[1:0]video_gain,
 output logic[63:0]video_levels,output logic[1:0]video_mode,video_preset,
 output logic[7:0]video_regions,output logic video_group,
 output logic[2:0]video_transport,output logic video_score_valid,video_octave,
 output logic[5:0]video_step,output logic[3:0]video_target,output logic[15:0]video_wrong,
 output logic video_latency_valid,output logic[15:0]video_latency_us,output logic video_ready
);
 wire observer_async_n=rst_audio_n && rst_pix_n;
 (* syn_preserve=1 *)reg[1:0]audio_reset_sync,pix_reset_sync;
 always_ff@(posedge clk_audio or negedge observer_async_n)begin
  if(!observer_async_n)audio_reset_sync<=0;else audio_reset_sync<={audio_reset_sync[0],1'b1};
 end
 always_ff@(posedge clk_pix or negedge observer_async_n)begin
  if(!observer_async_n)pix_reset_sync<=0;else pix_reset_sync<={pix_reset_sync[0],1'b1};
 end
 wire audio_reset_n=audio_reset_sync[1],pix_reset_n=pix_reset_sync[1];
 reg req,ack,front_bank,inflight,start;
 (* syn_preserve=1 *)reg[1:0]ack_sync,req_sync;
 reg[63:0]levels_hold;reg[51:0]state_hold;
 reg[1023:0]spectrum_history,spec_hold;reg[1:0]gain_hold;
 reg[10:0]period;reg[15:0]display_peak,peaks[0:3];
 function automatic[15:0]abs16(input signed[15:0]v);abs16=v[15]?(~v+16'd1):v;endfunction
 function automatic[7:0]log_mag(input[15:0]m);reg[7:0]v;
  begin v=0;for(integer k=0;k<16;k=k+1)if(m>>k)v=8'(k<<4);log_mag=v;end
 endfunction
 function automatic[1:0]choose_gain(input[15:0]p,input[1:0]current_gain);
  begin
   if(p<128)choose_gain=0;
   else if(p<3584)choose_gain=3;
   else if(p<4096 && current_gain==3)choose_gain=3;
   else if(p<7168)choose_gain=2;
   else if(p<8192 && current_gain>=2)choose_gain=2;
   else if(p<14336)choose_gain=1;
   else if(p<16384 && current_gain>=1)choose_gain=1;
   else choose_gain=0;
  end
 endfunction
 wire[15:0]current_peak=abs16(pcm_x)>abs16(pcm_y)?abs16(pcm_x):abs16(pcm_y);
 wire[15:0]peak_now=(sample_ce && current_peak>display_peak)?current_peak:display_peak;
 wire probe_valid;wire[15:0]probe_us;
 digital_latency_probe latency(.clk(clk_audio),.rst_n(audio_reset_n),.enable(measure_enable),
  .note_on,.voice_gates,.bck(serial_bck),.ws(serial_ws),.din(serial_din),.valid(probe_valid),.latency_us(probe_us),.slot(),.invalid_count());
 wire fft_ready;reg fft_start,copying;reg[9:0]fft_addr;reg[1:0]copy_phase;wire[15:0]fft_mag;
 fft_fixed_engine #(.LOGN(10))fft(.clk(clk_audio),.rst_n(audio_reset_n),.sample_ce,.sample(pcm_y),
  .capture_start(fft_start),.frame_ready(fft_ready),.mag_addr(fft_addr),.mag_data(fft_mag));
 wire capture_ready,render_busy,render_done,render_bank;
 reg[16:0]read_addr,row;reg read_valid;
 always_comb begin
  read_addr=0;row=0;read_valid=0;
  if(pixel_x>=20 && pixel_x<404 && pixel_y>=130 && pixel_y<302)begin
   row=17'(pixel_y-10'd130);read_addr=(row<<8)+(row<<7)+17'(pixel_x-10'd20);read_valid=video_ready;
  end else if(pixel_x>=430 && pixel_x<=616 && pixel_y>=114 && pixel_y<=300)begin
   row=17'(pixel_y-10'd114);read_addr=17'd66048+(row<<7)+(row<<5)+(row<<4)+(row<<3)+(row<<1)+row+17'(pixel_x-10'd430);read_valid=video_ready;
  end
 end
 display_trace_engine traces(.clk_audio,.rst_n(audio_reset_n),.sample_ce,.pcm_x,.pcm_y,
  .render_start(start),.display_gain(gain_hold),.capture_ready,.render_busy,.render_done,.render_bank,
  .clk_pix,.rst_pix_n(pix_reset_n),.read_bank(front_bank),.read_addr,.read_valid,.pixel(trace_pixel));
 always_ff@(posedge clk_audio or negedge audio_reset_n)begin
  if(!audio_reset_n)begin req<=0;ack_sync<=0;inflight<=0;start<=0;period<=0;display_peak<=0;
   levels_hold<=0;state_hold<=0;spec_hold<=0;spectrum_history<=0;gain_hold<=0;
   fft_start<=0;fft_addr<=0;copying<=0;copy_phase<=0;
   for(integer i=0;i<4;i=i+1)peaks[i]<=0;
  end else begin
   ack_sync<={ack_sync[0],ack};start<=0;fft_start<=0;
   if(render_done && inflight)begin req<=~req;inflight<=0;end
   if(fft_ready)begin copying<=1;fft_addr<=0;copy_phase<=0;end
   else if(copying)begin
    if(copy_phase!=2)copy_phase<=copy_phase+2'd1;
    else begin copy_phase<=0;spectrum_history[fft_addr[6:0]*8+:8]<=log_mag(fft_mag);
     if(fft_addr==127)copying<=0;else fft_addr<=fft_addr+10'd1;
    end
   end
   if(sample_ce)begin
    if(current_peak>display_peak)display_peak<=current_peak;
    for(integer v=0;v<4;v=v+1)if(abs16(voice_samples[v*16+:16])>peaks[v])peaks[v]<=abs16(voice_samples[v*16+:16]);
    if(period==0)fft_start<=1;
    if(period==1599)begin
     period<=0;
     if(req==ack_sync[1] && capture_ready && !inflight && !start && !copying)begin
      start<=1;inflight<=1;gain_hold<=choose_gain(peak_now,gain_hold);display_peak<=0;spec_hold<=spectrum_history;
      for(integer i=0;i<4;i=i+1)begin levels_hold[i*16+:16]<=abs16(voice_samples[i*16+:16])>peaks[i]?abs16(voice_samples[i*16+:16]):peaks[i];peaks[i]<=0;end
      state_hold<={transport,score_valid,octave,probe_valid,probe_us,mode,preset,step,target,wrong};
     end
    end else period<=period+11'd1;
   end
  end
 end
 always_ff@(posedge clk_pix or negedge pix_reset_n)begin
  if(!pix_reset_n)begin req_sync<=0;ack<=0;front_bank<=0;video_ready<=0;video_spectrum<=0;video_gain<=0;video_levels<=0;
   video_transport<=0;video_score_valid<=0;video_octave<=0;video_mode<=0;video_preset<=0;video_step<=0;video_target<=0;video_wrong<=0;video_latency_valid<=0;video_latency_us<=0;video_regions<=0;video_group<=0;
  end else begin
   req_sync<={req_sync[0],req};
   if(frame_start && req_sync[1]!=ack)begin
    front_bank<=render_bank;video_ready<=1;video_spectrum<=spec_hold;video_gain<=gain_hold;video_levels<=levels_hold;
    {video_transport,video_score_valid,video_octave,video_latency_valid,video_latency_us,video_mode,video_preset,video_step,video_target,video_wrong}<=state_hold;
    video_regions<=voice_regions;video_group<=group_b;
    ack<=req_sync[1];
   end
  end
 end
endmodule
