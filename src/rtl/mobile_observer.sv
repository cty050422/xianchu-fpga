// Passive final-PCM observation. A slow consumer drops new windows rather than
// ever backpressuring the synthesizer. 128 signed min/max columns, 8 chunks.
module mobile_observer #(
 parameter integer STATE_CLOCKS=2_457_600,WAVE_CLOCKS=12_288_000,BIN_SAMPLES=8
)(input logic clk,rst_n,sample_ce,input logic signed[15:0]pcm,
 input logic[247:0]state_payload,output logic ready,output logic[7:0]kind,
 output logic[5:0]length,output logic[303:0]body,input logic take);
 logic[31:0]state_ticks,wave_ticks;logic state_due,capturing,wave_pending;
 // One synchronous 128x16 bank, not 16 parallel read ports. Serializing the
 // 16-column packet copy costs 17 clocks per telemetry chunk, never audio cycles.
 (* syn_ramstyle="block_ram" *)logic[15:0]wave[0:127];
 logic[15:0]wave_q;logic building;logic[4:0]read_count;
 logic[6:0]column;logic[15:0]within_bin,window_id;
 logic signed[7:0]low,high;wire signed[7:0]point=pcm[15:8];
 logic[2:0]chunk;integer j;
 always_ff@(posedge clk)begin
  if(capturing && sample_ce && within_bin==BIN_SAMPLES-1)
   wave[column]<={point>high?point:high,point<low?point:low};
  wave_q<=wave[{chunk,read_count[3:0]}];
 end
 always_ff@(posedge clk or negedge rst_n)begin
  if(!rst_n)begin ready<=0;kind<=0;length<=0;body<=0;state_ticks<=0;wave_ticks<=0;state_due<=0;
   capturing<=0;wave_pending<=0;building<=0;read_count<=0;column<=0;within_bin<=0;window_id<=0;low<=127;high<=-128;chunk<=0;end
  else begin
   if(state_ticks>=STATE_CLOCKS-1)begin state_ticks<=0;state_due<=1;end else state_ticks<=state_ticks+32'd1;
   if(wave_ticks<WAVE_CLOCKS)wave_ticks<=wave_ticks+32'd1;
   if(wave_ticks>=WAVE_CLOCKS-1 && !capturing && !wave_pending && !building && !(ready && kind==8'h83))begin
    wave_ticks<=0;capturing<=1;column<=0;within_bin<=0;low<=127;high<=-128;window_id<=window_id+16'd1;
   end
   if(capturing && sample_ce)begin
    if(within_bin==BIN_SAMPLES-1)begin
     within_bin<=0;low<=127;high<=-128;
     if(column==127)begin capturing<=0;wave_pending<=1;chunk<=0;end else column<=column+7'd1;
    end else begin within_bin<=within_bin+16'd1;if(point<low)low<=point;if(point>high)high<=point;end
   end
   if(ready && take)ready<=0;
   if(building)begin
    if(read_count!=0)body[48+(read_count-1)*16+:16]<=wave_q;
    if(read_count==16)begin
     ready<=1;building<=0;
     if(chunk==7)wave_pending<=0;else chunk<=chunk+3'd1;
    end else read_count<=read_count+5'd1;
   end else if(!ready)begin
    if(state_due)begin ready<=1;kind<=8'h82;length<=31;body<={56'd0,state_payload};state_due<=0;end
    else if(wave_pending)begin
     building<=1;read_count<=0;kind<=8'h83;length<=38;body<=0;
     body[7:0]<=1;body[15:8]<=1; // schema 1, window=1024 samples at default BIN_SAMPLES=8
     body[23:16]<=window_id[7:0];body[31:24]<=window_id[15:8];body[39:32]<={5'd0,chunk};body[47:40]<=8;
    end
   end
  end
 end
endmodule
