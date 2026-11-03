#pragma once
#include "link_protocol.h"
#include "oled_guidance.h"
#include "performance_glyphs.h"
#include <math.h>
namespace xc {
// One bounded parser owns framing. Payload bytes cannot become nested frames.
struct WireParser{
 uint8_t data[55]{},count=0;uint32_t bad=0;
 void reset(){count=0;}
 bool feed(uint8_t b){
  if(count==0){if(b==0xa5)data[count++]=b;return false;}
  if(count==1){if(b==0x5a)data[count++]=b;else count=b==0xa5?1:0;return false;}
  data[count++]=b;
  if((count==3&&b!=1)||(count==5&&b>48)){bad++;reset();return false;}
  if(count>=7&&count==data[4]+7){const bool ok=crc8(data+2,count-3)==b;reset();if(!ok)bad++;return ok;}return false;
 }
};
struct MobileView{
 bool valid=false,octave=false;uint8_t mode=0,transport=0,length=0,preset=0,voices=0,held=0,expression=0,step=0,target=0,health=0;
 uint16_t session=0,request=0,bendRatio=32768,depth=0;int16_t dx=0,dy=0,j2x=0,j2y=0;
 uint8_t partials=0,wet=0,fx=0;
};
inline MobileView mobileView(const uint8_t*p){
 MobileView v;if(!p||p[2]!=1||p[3]!=0x82||p[4]!=31||p[6]!=1)return v;
 auto u=[&](int i){return uint16_t(p[6+i]|(uint16_t(p[7+i])<<8));};
 v.valid=true;v.mode=p[7];v.transport=p[8];v.length=p[9];v.session=u(4);v.request=u(6);v.preset=p[14];v.octave=p[15]&2;
 v.voices=p[16];v.held=p[17];v.expression=p[18];v.step=p[19];v.target=p[20];v.bendRatio=u(15);v.depth=u(17);
 v.dx=int16_t(u(19));v.dy=int16_t(u(21));v.partials=p[29];v.wet=p[30];v.health=p[31];v.j2x=int16_t(u(26));v.j2y=int16_t(u(28));v.fx=p[36];return v;
}
inline Arrow rodArrow(char axis,int16_t delta){if(delta>-64&&delta<64)return Arrow::NONE;return axis=='X'?(delta>0?Arrow::DOWN:Arrow::UP):(delta>0?Arrow::RIGHT:Arrow::LEFT);}
// Bounded whole-frame relay. State is coalesced. Wave overflow discards a whole
// pending window; the phone accepts only 8 chunks from one generation.
class TelemetryRelay{
 uint8_t control_[55]{},voices_[55]{},waves_[8][55]{},active_[55]{};
 uint8_t events_[8][15]{},eventHead_=0,eventCount_=0;
 uint8_t controlN_=0,voiceN_=0,lengths_[8]{},head_=0,size_=0,offset_=0,activeN_=0;
 bool preferWave_=false,waveIdValid_=false;uint16_t waveId_=0;
 public:uint32_t dropped=0;
 void reset(){controlN_=voiceN_=size_=head_=offset_=activeN_=eventHead_=eventCount_=0;preferWave_=waveIdValid_=false;}
 bool inProgress()const{return offset_<activeN_;}bool pending()const{return controlN_||voiceN_||eventCount_||size_;}
 bool offer(const uint8_t*p,uint8_t n){if(n>55||n<7)return false;
  if(p[3]==0x82){memcpy(control_,p,n);controlN_=n;return true;}
  if(p[3]==0x84){memcpy(voices_,p,n);voiceN_=n;return true;}
  if(p[3]==0x85){
   if(n!=15)return false;
   if(eventCount_==8){dropped++;return false;}
   memcpy(events_[(eventHead_+eventCount_)%8],p,15);eventCount_++;return true;
  }
  if(p[3]!=0x83)return false;
  // Finish the queued generation. Replacing its tail with a newer window can
  // otherwise prevent the phone from ever collecting all eight chunks.
  const uint16_t id=uint16_t(p[8])|(uint16_t(p[9])<<8);
  if(size_ && waveIdValid_ && id!=waveId_){dropped++;return false;}
  if(!size_){if((!waveIdValid_||id!=waveId_)&&p[10]!=0){dropped++;return false;}waveId_=id;waveIdValid_=true;}
  if(size_==8){dropped++;return false;}
  const uint8_t at=(head_+size_)%8;memcpy(waves_[at],p,n);lengths_[at]=n;size_++;return true;
 }
 uint8_t next(uint8_t*out){
  if(!inProgress()){
   offset_=0;if(controlN_){activeN_=controlN_;memcpy(active_,control_,activeN_);controlN_=0;}
   else if(eventCount_){activeN_=15;memcpy(active_,events_[eventHead_],15);eventHead_=(eventHead_+1)%8;eventCount_--;}
   else if(voiceN_ && (!size_||!preferWave_)){activeN_=voiceN_;memcpy(active_,voices_,activeN_);voiceN_=0;preferWave_=true;}
   else if(size_){activeN_=lengths_[head_];memcpy(active_,waves_[head_],activeN_);head_=(head_+1)%8;size_--;preferWave_=false;}
   else{activeN_=0;return 0;}
  }
  const uint8_t n=(activeN_-offset_>20)?20:uint8_t(activeN_-offset_);memcpy(out,active_+offset_,n);offset_+=n;return n;
 }
};
inline bool renderPerformance(const MobileView&v,uint8_t*b){
 if(!b||!v.valid)return false;memset(b,0,1024);using namespace performance_font;
 text(b,0,0,v.mode==1?"引导":v.mode==2?"挑战":v.mode==3?"示范":"自由");
 const char*timbres[]={"拨弦","吹管","钟声","贝斯"};text(b,36,0,timbres[v.preset&3]);
 text(b,72,0,v.mode==3?"谱定":v.octave?"高八度":"原八度");
 char line[48];
 if(v.mode==0){snprintf(line,sizeof(line),"四声部  %u音",unsigned(__builtin_popcount(v.voices&15)));text(b,0,16,line);}
 else if(v.mode==3){snprintf(line,sizeof(line),"曲谱演奏 %02u",unsigned(v.step+1));text(b,0,16,line);}
 else if(!v.length){text(b,0,16,"未选曲");}
 else if(v.transport==6){text(b,0,16,"准备开始");}
 else if(v.transport==3){text(b,0,16,"已暂停");}
 else if(v.transport==4){text(b,0,16,(v.health&32)?"完成·中断":"本曲完成");}
 else if(v.transport!=2){text(b,0,16,v.transport==5?"松开压力键":"待开始");}
 else {
  char keys[8];unsigned n=0;for(unsigned i=0;i<4;i++)if(v.target&(1<<i)){if(n)keys[n++]='+';keys[n++]=char('1'+i);}keys[n]=0;
  int x=text(b,0,16,v.target?"目标":"休止");if(v.target)x=text(b,x,16,keys);
  if(v.expression && x<80)x=text(b,x+4,16,v.expression==1?"滑↕":"颤↔");
  snprintf(line,sizeof(line),"%02u/%02u",unsigned(v.step+1),unsigned(v.length));if(x<94)text(b,98,20,line,1,5);
 }
 int x=text(b,0,32,"滑音");
 if(!(v.health&1)){text(b,x+4,32,"失鲜");}
 else {x=text(b,x+4,36,"J1X");oled_detail::arrow(b,x,33,rodArrow('X',v.dx));
  if(v.mode==3)text(b,x+16,32,"谱定");else if(!v.voices)text(b,x+16,32,"待用");else if(v.bendRatio==32768)text(b,x+16,32,"回中");
  else {const int cents=int(lroundf(1200.0f*log2f(float(v.bendRatio)/32768.0f)));snprintf(line,sizeof(line),"%+04dc",cents);text(b,x+16,36,line);}}
 x=text(b,0,48,"颤音");
 if(!(v.health&2)){text(b,x+4,48,"失鲜");}
 else {x=text(b,x+4,52,"J1Y");oled_detail::arrow(b,x,49,rodArrow('Y',v.dy));
  if(!v.voices)text(b,x+16,48,"待用");else if(v.depth<=32)text(b,x+16,48,"关");
  else {snprintf(line,sizeof(line),"%u%%",unsigned(v.depth)*100/2048);text(b,x+16,52,line);}}
 return true;
}
}
