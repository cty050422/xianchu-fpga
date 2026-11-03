#include "mobile_view.h"
#include <cassert>
#include <cstdio>
#undef assert
#define assert(x) do { if(!(x)) { std::fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#x); return 1; } } while(0)
int main(){xc::WireParser p;uint8_t f[38]={0xa5,0x5a,1,0x82,31,9};
 f[6]=1;f[7]=2;f[8]=2;f[14]=1;f[15]=2;f[16]=1;f[21]=0x00;f[22]=0x90;f[23]=0x00;f[24]=0x04;
 f[25]=0x00;f[26]=0x02;f[27]=0x00;f[28]=0xfe;f[31]=31;f[37]=xc::crc8(f+2,35);
 for(int i=0;i<38;i++){bool done=p.feed(f[i]);assert(done==(i==37));}
 auto v=xc::mobileView(p.data);assert(v.mode==2&&v.preset==1&&v.octave&&v.dx==512&&v.dy==-512&&v.bendRatio==0x9000);
 assert(xc::rodArrow('X',v.dx)==xc::Arrow::DOWN);assert(xc::rodArrow('Y',v.dy)==xc::Arrow::LEFT);
 uint8_t buffer[1026]={};buffer[0]=0x42;buffer[1025]=0x24;assert(xc::renderPerformance(v,buffer+1));assert(buffer[0]==0x42&&buffer[1025]==0x24);
 f[37]^=1;bool bad=false;for(auto b:f)bad=p.feed(b)||bad;assert(!bad);
 xc::TelemetryRelay q;assert(q.offer(f,38));uint8_t fragment[20];int n=0;while(q.inProgress()||q.pending())n+=q.next(fragment);assert(n==38);
 // The production loop offers 0x84 to this same queue. It must not silently
 // reject the new four-voice status, and all three ATT20 fragments stay whole.
 uint8_t vf[44]={0xa5,0x5a,1,0x84,37,10};vf[6]=1;vf[43]=xc::crc8(vf+2,41);
 assert(q.offer(vf,44));n=0;int fragments=0;
 while(q.inProgress()||q.pending()){n+=q.next(fragment);fragments++;}
 assert(n==44 && fragments==3);
}
