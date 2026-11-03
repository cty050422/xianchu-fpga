#include <cstdio>
#include <cstring>
#include <algorithm>
#include "mobile_view.h"
#include "bounded_io.h"
static void make(uint8_t*p,unsigned kind,unsigned len,unsigned seq){memset(p,0,55);p[0]=0xa5;p[1]=0x5a;p[2]=1;p[3]=kind;p[4]=len;p[5]=seq;p[6]=1;}
static void seal(uint8_t*p){p[p[4]+6]=xc::crc8(p+2,p[4]+4);}
int main(int argc,char**argv){
 FILE*capture=argc>1?std::fopen(argv[1],"w"):nullptr;if(capture)std::fputs("ms,period,bytes_hex\n",capture);
 for(unsigned period:{15u,10u}){
  xc::StatusFragments status;xc::TelemetryRelay relay;xc::WireParser parser;
  unsigned voices=0,controls=0,windows=0,index=0,window=0,windowStart=0,maxVoiceGap=0,lastVoice=0;uint8_t p[55],fragment[20];
  for(unsigned ms=1;ms<=8000;ms++){
   if(ms%100==0){make(p,0x80,15,ms/100);seal(p);status.offer(p);make(p,0x84,45,ms/100);p[6]=2;p[7]=1;
    for(unsigned v=0;v<4;v++){unsigned o=11+10*v;p[o]=ms/100;p[o+1]=32;p[o+2]=ms/100;p[o+4]=128;p[o+5]=192;p[o+6]=60+v*2+((ms/1000)%2)*12;p[o+7]=v;p[o+8]=255;p[o+9]=127;}seal(p);relay.offer(p,52);}
   if(ms%200==0){make(p,0x82,31,ms/200);p[7]=1+(ms/2000)%2;p[8]=2;p[9]=8;p[16]=p[17]=5;p[18]=1+(ms/1000)%2;p[20]=5;p[22]=128;p[31]=31;seal(p);relay.offer(p,38);}
   if(ms%1000==1){for(unsigned c=0;c<8;c++){make(p,0x83,38,0);p[7]=1;p[8]=ms/1000;p[9]=0;p[10]=c;p[11]=8;for(unsigned k=12;k<44;k++)p[k]=(k%2)?12:244;seal(p);relay.offer(p,45);}}
   if(ms%period || ms%200<28)continue; // measured-class OLED blocking budget
   unsigned n=0;if(relay.inProgress())n=relay.next(fragment);else if(status.in_progress())n=status.next(fragment);else {n=status.next(fragment);if(!n)n=relay.next(fragment);}
   if(capture&&n){std::fprintf(capture,"%u,%u,",ms,period);for(unsigned i=0;i<n;i++)std::fprintf(capture,"%02x",fragment[i]);std::fputc('\n',capture);}
   for(unsigned i=0;i<n;i++)if(parser.feed(fragment[i])){
    if(parser.data[3]==0x84){voices++;maxVoiceGap=std::max(maxVoiceGap,ms-lastVoice);lastVoice=ms;}
    if(parser.data[3]==0x82)controls++;
    if(parser.data[3]==0x83){unsigned id=parser.data[8]|(parser.data[9]<<8),ix=parser.data[10];if(ix==0){index=0;window=id;windowStart=ms;}if(id==window&&ix==index&&ms-windowStart<=2500){if(++index==8){windows++;index=0;}}else index=0;}
   }
  }
  std::printf("period=%u voices=%u controls=%u complete_windows=%u max_voice_gap_ms=%u crc_bad=%u drops=%u\n",period,voices,controls,windows,maxVoiceGap,parser.bad,relay.dropped);
  if(windows<2||voices<15||controls<20||parser.bad||maxVoiceGap>700)return 1;
 }
 if(capture)std::fclose(capture);
 std::puts("PASS sustained production cadence: status/control/voice/wave all progress without torn frames");
}
