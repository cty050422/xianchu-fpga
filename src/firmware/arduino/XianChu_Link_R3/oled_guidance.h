#pragma once
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "oled_guide_glyphs.h"

namespace xc {
inline bool pairingDisplayReady(bool fpgaOwner,bool localOledReady,bool fpgaFresh){
  return fpgaOwner?fpgaFresh:localOledReady;
}
enum class Arrow:uint8_t { UP,RIGHT,DOWN,LEFT,NONE };
struct DirectionPair {Arrow positive,negative;};
inline DirectionPair axisDirections(uint8_t stick,char axis){
  if((stick!=1 && stick!=2)||(axis!='X' && axis!='Y'))return {Arrow::NONE,Arrow::NONE};
  return axis=='X'?DirectionPair{Arrow::DOWN,Arrow::UP}:DirectionPair{Arrow::RIGHT,Arrow::LEFT};
}
struct GuidanceView {
  bool visible=false,mappingReady=true,legacy=false,cue=false;
  uint8_t mode=0,step=0,targetMask=0,expression=0,joystick=0;
  char axis=' ';
  Arrow positive=Arrow::NONE,negative=Arrow::NONE;
  uint16_t wrong=0,misses=0;
};
// Only call with the parser's accepted 22-byte STATUS; never decode a partial frame.
inline GuidanceView guidanceView(const uint8_t* p,bool have,uint32_t age){
  GuidanceView v;
  if(!p || !have || age>700)return v;
  const uint8_t flags=p[7];
  if(!(flags&16) || !(flags&2) || (flags&12) || p[8]>63)return v;
  v.legacy=!(flags&128);v.mode=v.legacy?1:uint8_t((flags>>5)&3);
  if(v.mode!=1 && v.mode!=2)return GuidanceView{};
  v.visible=true;v.step=uint8_t(p[8]+1);v.expression=uint8_t((p[9]>>2)&3);
  v.targetMask=uint8_t(p[9]>>4);
  if(v.legacy && !v.targetMask)v.targetMask=uint8_t(1u<<(p[9]&3));
  v.mappingReady=v.legacy || (p[16]&64);
  v.wrong=uint16_t(p[12])|(uint16_t(p[13])<<8);
  v.misses=uint16_t(p[14])|(uint16_t(p[15])<<8);
  v.cue=v.mappingReady && v.targetMask && (v.expression==1 || v.expression==2);
  if(v.cue){v.joystick=1;v.axis=v.expression==1?'X':'Y';
    const DirectionPair d=axisDirections(1,v.axis);v.positive=d.positive;v.negative=d.negative;}
  return v;
}
namespace oled_detail {
inline void pixel(uint8_t* b,int x,int y){if(x>=0 && x<128 && y>=0 && y<64)b[(y>>3)*128+x]|=uint8_t(1u<<(y&7));}
inline void cn(uint8_t*b,int x,int y,unsigned id){
  if(id>=20)return;
  for(int r=0;r<16;r++)for(int c=0;c<16;c++)if(cnGlyphs[id][r]&(1u<<(15-c)))pixel(b,x+c,y+r);
}
inline const uint8_t* ascii(char c){
  static const uint8_t g[18][5]={
    {0x3e,0x51,0x49,0x45,0x3e},{0,0x42,0x7f,0x40,0},{0x42,0x61,0x51,0x49,0x46},
    {0x21,0x41,0x45,0x4b,0x31},{0x18,0x14,0x12,0x7f,0x10},{0x27,0x45,0x45,0x45,0x39},
    {0x3c,0x4a,0x49,0x49,0x30},{1,0x71,9,5,3},{0x36,0x49,0x49,0x49,0x36},
    {6,0x49,0x49,0x29,0x1e},{0x20,0x40,0x41,0x3f,1},{0x63,0x14,8,0x14,0x63},
    {7,8,0x70,8,7},{8,8,0x3e,8,8},{8,8,8,8,8},{0x20,0x10,8,4,2},
    {2,1,0x51,9,6},{0,0,0,0,0}};
  unsigned i=17;
  if(c>='0' && c<='9')i=unsigned(c-'0');
  else if(c=='J')i=10;else if(c=='X')i=11;else if(c=='Y')i=12;
  else if(c=='+')i=13;else if(c=='-')i=14;else if(c=='/')i=15;else if(c=='?')i=16;
  return g[i];
}
inline void text(uint8_t*b,int x,int y,const char*s,int scale=1){
  for(;*s;s++,x+=6*scale){const uint8_t*g=ascii(*s);
    for(int c=0;c<5;c++)for(int r=0;r<7;r++)if(g[c]&(1u<<r))
      for(int dx=0;dx<scale;dx++)for(int dy=0;dy<scale;dy++)pixel(b,x+c*scale+dx,y+r*scale+dy);}
}
inline void arrow(uint8_t*b,int x,int y,Arrow a){
  if(a==Arrow::NONE)return;
  const int dx=a==Arrow::RIGHT?1:a==Arrow::LEFT?-1:0;
  const int dy=a==Arrow::DOWN?1:a==Arrow::UP?-1:0;
  for(int t=-5;t<=5;t++)pixel(b,x+6+t*dx,y+6+t*dy);
  for(int t=0;t<5;t++){
    pixel(b,x+6+(5-t)*dx+t*dy,y+6+(5-t)*dy-t*dx);
    pixel(b,x+6+(5-t)*dx-t*dy,y+6+(5-t)*dy+t*dx);
  }
}
}
// Actual SSD1306 page buffer (128 columns x 8 pages), no allocation or I2C.
inline bool renderGuidance(const GuidanceView&v,uint8_t*buffer){
  if(!buffer)return false;
  memset(buffer,0,1024);if(!v.visible)return false;
  using namespace oled_detail;
  cn(buffer,0,0,v.mode==2?2:0);cn(buffer,16,0,v.mode==2?3:1);cn(buffer,40,0,4);
  char n[16];snprintf(n,sizeof(n),"%02u",unsigned(v.step));text(buffer,60,4,n);
  if(v.cue && v.expression==2){cn(buffer,88,0,18);cn(buffer,104,0,19);}
  if(!v.mappingReady){cn(buffer,0,16,14);cn(buffer,16,16,15);cn(buffer,32,16,16);cn(buffer,48,16,17);}
  else {
    cn(buffer,0,16,5);cn(buffer,16,16,6);
    if(!v.targetMask){cn(buffer,40,16,12);cn(buffer,56,16,13);}
    else {char targets[8];unsigned k=0;
      for(unsigned i=0;i<4;i++)if(v.targetMask&(1u<<i)){if(k)targets[k++]='+';targets[k++]=char('1'+i);}
      targets[k]=0;text(buffer,40,17,targets,2);}
  }
  if(v.cue){
    cn(buffer,0,32,v.expression==1?9:11);cn(buffer,16,32,10);
    char axis[4]={'J','1',v.axis,0};text(buffer,38,36,axis);
    text(buffer,68,36,"+");arrow(buffer,77,33,v.positive);
    text(buffer,98,36,"-");arrow(buffer,107,33,v.negative);
  }
  cn(buffer,0,48,7);snprintf(n,sizeof(n),"%05u",unsigned(v.wrong));text(buffer,18,52,n);
  cn(buffer,64,48,8);snprintf(n,sizeof(n),"%05u",unsigned(v.misses));text(buffer,82,52,n);
  return true;
}
}
