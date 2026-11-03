#include "../oled_guidance.h"
#include "../link_protocol.h"
#include <stdlib.h>
#include <fstream>
#include <string>
#include <iostream>
static unsigned checks=0;
static void check(bool ok,const char*message){++checks;if(!ok){std::cerr<<message<<"\n";exit(1);}}
static void frame(uint8_t*p,unsigned mode,unsigned expr,unsigned mask){
  memset(p,0,22);p[0]=0xa5;p[1]=0x5a;p[2]=1;p[3]=0x80;p[4]=15;p[5]=3;
  p[6]=1;p[7]=uint8_t(0x93|(mode<<5));p[8]=2;p[9]=uint8_t((mask<<4)|(expr<<2));
  p[12]=2;p[14]=1;p[16]=64;p[21]=xc::crc8(p+2,19);
}
static bool pixel(const uint8_t*b,int x,int y){return (b[(y>>3)*128+x]>>(y&7))&1;}
static bool empty(const uint8_t*b){for(int i=0;i<1024;i++)if(b[i])return false;return true;}
static void dump(const std::string&dir,const char*name,const xc::GuidanceView&v){
  if(dir.empty())return;
  uint8_t b[1024];xc::renderGuidance(v,b);
  std::ofstream f(dir+"/"+name,std::ios::binary);f<<"P5\n128 64\n255\n";
  for(int y=0;y<64;y++)for(int x=0;x<128;x++){const char c=pixel(b,x,y)?char(255):char(0);f.write(&c,1);}
  check(bool(f),"preview write failed");
}
int main(int argc,char**argv){
  using namespace xc;const std::string dir=argc>1?argv[1]:"";
  // Pinned OFL glyph rows: upper/lower asymmetry detects accidental vertical flips.
  check(oled_detail::cnGlyphs[0][1]==0x3f88 && oled_detail::cnGlyphs[0][13]==0x0f08,"Chinese YIN glyph top must not be vertically mirrored");
  check(oled_detail::cnGlyphs[1][1]==0x1ff8 && oled_detail::cnGlyphs[1][13]==0x00e0,"Chinese DAO upper component must stay above lower component");
  check(!pairingDisplayReady(false,false,true),"missing local OLED cannot show PIN");
  check(pairingDisplayReady(false,true,false),"local OLED may pair before FPGA link is ready");
  check(pairingDisplayReady(true,false,true),"FPGA-owned display uses fresh metadata link");
  check(!pairingDisplayReady(true,true,false),"stale FPGA cannot show PIN even if old local init was true");
  for(unsigned j=1;j<=2;j++){
    const auto x=axisDirections(uint8_t(j),'X'),y=axisDirections(uint8_t(j),'Y');
    check(x.positive==Arrow::DOWN && x.negative==Arrow::UP,"both X sticks must be down+/up-");
    check(y.positive==Arrow::RIGHT && y.negative==Arrow::LEFT,"both Y sticks must be right+/left-");
  }
  check(axisDirections(0,'X').positive==Arrow::NONE,"invalid joystick");
  check(axisDirections(1,'Z').positive==Arrow::NONE,"invalid axis");
  uint8_t p[22],guard[1026];frame(p,1,1,1);
  Parser parser;bool accepted=false;for(auto b:p)accepted=parser.feed(b)||accepted;
  check(accepted,"wire parser accepts full valid status");
  auto v=guidanceView(parser.data,true,28);
  check(v.visible && v.mode==1 && v.step==3 && v.cue,"guided step is authoritative");
  check(v.joystick==1 && v.axis=='X' && v.positive==Arrow::DOWN && v.negative==Arrow::UP,"bend polarity");
  check(v.wrong==2 && v.misses==1,"wrong/miss LE offsets");
  memset(guard,0xa5,sizeof(guard));check(renderGuidance(v,guard+1),"guided rendering");
  check(guard[0]==0xa5 && guard[1025]==0xa5,"framebuffer bounds");
  check(pixel(guard+1,83,44) && pixel(guard+1,113,34),"actual down+ and up- arrow tips");
  dump(dir,"guide_bend.pgm",v);
  uint8_t prior[1024];memcpy(prior,guard+1,1024);
  frame(p,2,2,9);v=guidanceView(p,true,0);
  check(v.mode==2 && v.targetMask==9 && v.axis=='Y',"challenge chord and vibrato");
  check(v.positive==Arrow::RIGHT && v.negative==Arrow::LEFT,"vibrato polarity");
  renderGuidance(v,guard+1);
  check(pixel(guard+1,88,39) && pixel(guard+1,108,39),"actual right+ and left- arrow tips");
  check(memcmp(prior,guard+1,1024)!=0,"mode/step cue pixels change");dump(dir,"challenge_vibrato.pgm",v);
  frame(p,1,0,15);v=guidanceView(p,true,0);renderGuidance(v,guard+1);
  check(!v.cue && v.targetMask==15,"all four chord targets without gesture");
  for(int y=32;y<48;y++)for(int x=0;x<128;x++)check(!pixel(guard+1,x,y),"ordinary step clears prior arrows");
  dump(dir,"guide_chord.pgm",v);
  frame(p,1,2,0);v=guidanceView(p,true,700);check(v.visible && !v.cue && !v.targetMask,"rest suppresses stale expression");
  dump(dir,"guide_rest.pgm",v);
  p[16]=0;v=guidanceView(p,true,0);check(v.visible && !v.mappingReady && !v.cue,"mapping requires score retransmit");
  dump(dir,"mapping_wait.pgm",v);
  frame(p,1,1,1);p[7]=0x13;p[9]=uint8_t(1<<2|2);v=guidanceView(p,true,0);
  check(v.visible && v.legacy && v.mode==1 && v.targetMask==4,"legacy lowest target is not rest");
  for(unsigned bits: {0x91u,0xbbu,0xb7u,0xa3u,0xf3u}){
    frame(p,1,1,1);p[7]=uint8_t(bits);v=guidanceView(p,true,0);
    check(!v.visible && !v.cue,"free/panic/test/uncalibrated/reserved mode hides cue");
    memset(guard+1,0xff,1024);renderGuidance(v,guard+1);check(empty(guard+1),"inactive state fully clears stale pixels");
  }
  frame(p,1,1,1);check(!guidanceView(p,true,701).visible,"stale 701ms");
  check(!guidanceView(p,false,0).visible && !guidanceView(nullptr,true,0).visible,"missing status");
  p[8]=64;check(!guidanceView(p,true,0).visible,"invalid step");
  frame(p,2,3,15);v=guidanceView(p,true,0);check(v.visible && !v.cue,"reserved expression never invents a direction");
  frame(p,2,1,15);p[8]=63;p[12]=p[13]=p[14]=p[15]=255;v=guidanceView(p,true,0);
  check(v.step==64 && v.wrong==65535 && v.misses==65535,"max counters and step");
  renderGuidance(v,guard+1);check(guard[0]==0xa5 && guard[1025]==0xa5,"max target/counter bounds");
  std::cout<<"PASS OLED guidance "<<checks<<" checks; real page-buffer renderer, wire parser and polarity\n";
}
