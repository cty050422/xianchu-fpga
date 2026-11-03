// Native 640x480 dashboard. PCM scaling is DISPLAY ONLY, shared by X and Y.
// FFT1024 at 48kHz: bins 0..127 (46.875Hz/bin), low band 0..6kHz.
// XY is main voice mix versus final DAC DIGITAL sample; it is NOT stereo.
module display_dashboard(
 input logic clk_pix,rst_n,
 input logic [9:0] x,y,input logic visible,
 input logic trace_pixel,input logic [1023:0] spectrum,
 input logic [63:0] levels,
 input logic [7:0] voice_regions=8'd0,input logic group_b=1'b0,
 input logic[2:0]transport=3'd0,input logic score_valid=1'b0,octave=1'b0,
 input logic [1:0] mode,preset,input logic [5:0] step,
 input logic [3:0] target,input logic [15:0] wrong,
 input logic latency_valid=0,input logic [15:0] latency_us=0,
 input logic [1:0] display_gain=0,
 output logic [7:0] r,g,b
);
 reg[95:0]zh_line;integer zh_tx,zh_ty;reg[7:0]zh_id;reg[3:0]zh_xq;reg zh_q;wire[15:0]zh_bits;
 dashboard_zh_font zhfont(.clk(clk_pix),.glyph(zh_id[6:0]),.row(zh_ty[3:0]),.bits(zh_bits));
 reg [6:0] ch,ch_q;reg[5:0]font_bit_q;reg text_q;reg[7:0]bg_r,bg_g,bg_b;reg visible_q; wire [63:0] font;
 vga_font8x8 fontrom(.idx(ch_q),.word(font));
 integer xx,yy,wi,sy,sx,lo,hi,trigger_index,tx,ty;
 reg [7:0] rc,gc,bc; reg signed [7:0] wav,prev; reg[15:0] lv;
 reg [191:0] text_line; reg [7:0] letter;
 function automatic [7:0] digit(input integer n);digit=8'd48+(n%10);endfunction
 always_comb begin
  zh_line=0;zh_tx=0;zh_ty=0;zh_id=0;rc=12;gc=18;bc=21;ch=0;xx=0;yy=0;wi=0;sy=0;sx=0;lo=0;hi=0;
  wav=0;prev=0;lv=0;letter=32;tx=0;ty=0;text_line=0;trigger_index=0;
  // Fixed framing and panels: stable scale and position across all modes.
  if((y>=104 && y<=306 && x>=16 && x<=406) || (y>=104 && y<=306 && x>=422 && x<=624) || (y>=338 && y<=446 && x>=16 && x<=624))begin rc=16;gc=26;bc=29;end
  if(y==100 || y==326 || y==446)begin rc=38;gc=54;bc=56;end
  if(y>=62 && y<78 && x>=20 && x<620)begin
   wi=(x<170)?0:(x<320)?1:(x<470)?2:3;xx=(wi==0)?x-20:(wi==1)?x-170:(wi==2)?x-320:x-470;
   // Zone-keyed meter: card N shows the voice currently bound to KEY N.
   lv=0;
   for(sy=0;sy<4;sy=sy+1)if(voice_regions[sy*2+:2]==wi[1:0]&&levels[sy*16+:16]>lv)lv=levels[sy*16+:16];
   if(xx<140)begin
    rc=30;gc=46;bc=47;
    // ~-24..0dBFS meter span, intentionally independent of waveform auto gain.
    if(xx<(lv>>8))begin rc=108;gc=211;bc=176;end
   end
  end
  // Full-rate, pre-rasterized one-pixel trace. No wide per-pixel sample search.
  if(x>=20 && x<404 && y>=130 && y<302)begin
   if(y==214 || ((x-20)%48)==0 || y==166 || y==262)begin rc=31;gc=47;bc=49;end
   if(trace_pixel)begin rc=233;gc=194;bc=114;end
  end
  // Square XY field uses ONE common gain; shape/slope are not normalized away.
  if(x>=430 && x<=616 && y>=114 && y<=300)begin
   if(x==523 || y==207 || x==430 || x==616 || y==114 || y==300)begin rc=40;gc=55;bc=57;end
   if(trace_pixel)begin rc=183;gc=163;bc=224;end
  end
  if(x>=20 && x<532 && y>=350 && y<434)begin
   wi=(x-20)>>2;sy=433-((spectrum[wi*8+:8]>>2)+(spectrum[wi*8+:8]>>4));
   if(y==393 || y==353 || ((x-20)%128)==0)begin rc=28;gc=43;bc=46;end
   if((x-20)%4<3 && spectrum[wi*8+:8]!=0 && y>=sy)begin rc=91;gc=167;bc=190;end
  end
  // Product labels are Chinese; technical units remain compact ASCII.
  if(y>=4 && y<36 && x>=20 && x<340)begin zh_line=96'h244107130000000000000000;zh_tx=(x-20)>>1;zh_ty=(y-4)>>1;end
  else if(y>=40 && y<56 && x>=20 && x<212)begin
   case(mode)0:zh_line=96'h3c3836150000000000000000;1:zh_line=96'h231d3b050000000000000000;2:zh_line=96'h3d152a280000000000000000;default:zh_line=96'h3042393e0000000000000000;endcase
   zh_tx=x-20;zh_ty=y-40;
  end else if(y>=40 && y<56 && x>=240 && x<432)begin
   case(preset)0:zh_line=96'h292400000000000000000000;1:zh_line=96'h113a00000000000000000000;2:zh_line=96'h491300000000000000000000;default:zh_line=96'h1027432c0000000000000000;endcase
   zh_tx=x-240;zh_ty=y-40;
  end else if(y>=40 && y<56 && x>=448 && x<624)begin
   if(mode==0)zh_line=octave?96'h4b0920000000000000000000:96'h0f0920000000000000000000;else if(mode==3)zh_line=96'h421936150000000000000000;
   else if(!score_valid)zh_line=96'h314730000000000000000000;
   else case(transport)2:zh_line=96'h453f04000000000000000000;3:zh_line=96'h1e2f08000000000000000000;4:zh_line=96'h323018270000000000000000;5:zh_line=96'h33220e0d4a00000000000000;6:zh_line=96'h0b1422160000000000000000;default:zh_line=96'h262216000000000000000000;endcase
   zh_tx=x-448;zh_ty=y-40;
  end else if(y>=82 && y<98 && x>=20 && x<620)begin
   wi=(x<170)?0:(x<320)?1:(x<470)?2:3;
   // Key cards: "1 C4" .. "4 G4" (group B: G4/A4/B4/C5; octave up +1) — ASCII so
   // the note letter and octave digit stay readable on camera; order 1..4 = keys.
   case(wi)
    0:      text_line = (group_b) ? "1 G4" : "1 C4";
    1:      text_line = (group_b) ? "2 A4" : "2 D4";
    2:      text_line = (group_b) ? "3 B4" : "3 E4";
    default:text_line = (group_b) ? "4 C5" : "4 G4";
   endcase
   if(octave)text_line[167:160] = text_line[167:160] + 8'd1; // digit 4->5, 5->6
   tx=(wi==0)?x-20:(wi==1)?x-170:(wi==2)?x-320:x-470;ty=y-82;
  end else if(y>=112 && y<128 && x>=20 && x<116)begin zh_line=96'h2b1735250000000000000000;zh_tx=x-20;zh_ty=y-112;end
  else if(y>=310 && y<326 && x>=430 && x<622)begin zh_line=96'h134803440c00000000000000;zh_tx=x-430;zh_ty=y-310;end
  else if(y>=310 && y<326 && x>=20 && x<212)begin zh_line=96'h370a2b172e39000000000000;zh_tx=x-20;zh_ty=y-310;end
  else if(y>=374 && y<390 && x>=552 && x<624)begin zh_line=96'h1c2b1f200000000000000000;zh_tx=x-552;zh_ty=y-374;end
  else if(y>=460 && y<476 && x>=20 && x<212)begin zh_line=96'h1a2d10272b17401b00000000;zh_tx=x-20;zh_ty=y-460;end
  else if(y>=458 && y<474 && x>=304 && x<400)begin zh_line=96'h2b1734214600000000000000;zh_tx=x-304;zh_ty=y-458;end
  else if(y>=112 && y<120 && x>=116 && x<300)begin text_line="8ms / DISPLAY X1        ";text_line[71:64]=(display_gain==3)?"8":(display_gain==2)?"4":(display_gain==1)?"2":"1";tx=x-116;ty=y-112;end
  else if(y>=16 && y<24 && x>=448 && x<624)begin text_line="4 VOICES / 48kHz        ";tx=x-448;ty=y-16;end
  else if(y>=350 && y<358 && x>=552 && x<624)begin text_line="FFT 1024                ";tx=x-552;ty=y-350;end
  else if(y>=398 && y<406 && x>=552 && x<624)begin text_line="0..6kHz                 ";tx=x-552;ty=y-398;end
  else if(y>=438 && y<446 && x>=20 && x<532)begin
   tx=x-20;ty=y-438;
   if(tx<48)text_line="0 Hz                    ";
   else if(tx>=128 && tx<176)begin text_line="1.5k                    ";tx=tx-128;end
   else if(tx>=256 && tx<304)begin text_line="3k                      ";tx=tx-256;end
   else if(tx>=384 && tx<432)begin text_line="4.5k                    ";tx=tx-384;end
   else if(tx>=496)begin text_line="6k                      ";tx=tx-496;end
  end else if(y>=460 && y<468 && x>=400 && x<616)begin
   text_line="----- us                ";
   if(latency_valid)begin text_line[191:184]=digit(latency_us/10000);text_line[183:176]=digit(latency_us/1000);text_line[175:168]=digit(latency_us/100);text_line[167:160]=digit(latency_us/10);text_line[159:152]=digit(latency_us);end
   tx=x-400;ty=y-460;
  end
  if(zh_line!=0 && zh_tx>=0 && zh_tx<192)zh_id=zh_line[(11-(zh_tx>>4))*8+:8];
  if(text_line!=0 && tx>=0 && tx<192)begin
   letter=text_line[(23-(tx>>3))*8+:8];ch=(letter>=32 && letter<128)?letter[6:0]-7'd32:7'd0;

  end
 end
 always_ff @(posedge clk_pix or negedge rst_n)begin
  if(!rst_n)begin zh_q<=0;zh_xq<=0;r<=0;g<=0;b<=0;ch_q<=0;font_bit_q<=0;text_q<=0;bg_r<=0;bg_g<=0;bg_b<=0;visible_q<=0;end
  else begin
   zh_q<=zh_line!=0 && zh_tx>=0 && zh_tx<192;zh_xq<=zh_tx[3:0];ch_q<=ch;font_bit_q<={ty[2:0],3'b0}+(6'd7-{3'd0,tx[2:0]});text_q<=text_line!=0 && tx>=0 && tx<192;
   bg_r<=rc;bg_g<=gc;bg_b<=bc;visible_q<=visible;
   if(!visible_q)begin r<=0;g<=0;b<=0;end
   else if((text_q && font[font_bit_q]) || (zh_q && zh_bits[15-zh_xq]))begin r<=221;g<=232;b<=225;end
   else begin r<=bg_r;g<=bg_g;b<=bg_b;end
  end
 end
endmodule
