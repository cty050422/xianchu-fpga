#include <cstdio>
#include <cstring>
#include <vector>
#include "mobile_view.h"
#define CHECK(x) do{if(!(x)){std::printf("FAIL line %d: %s\n",__LINE__,#x);return 1;}}while(0)
int main(){
 xc::TelemetryRelay relay;uint8_t event[15]={0xa5,0x5a,1,0x85,8,0,0,0x80,60,1,0,0,0,0,0};
 for(unsigned i=0;i<8;i++){event[5]=event[6]=i;event[14]=xc::crc8(event+2,12);CHECK(relay.offer(event,15));}
 CHECK(!relay.offer(event,15));CHECK(relay.dropped>=1);
 uint8_t control[38]={0xa5,0x5a,1,0x82,31,0,1,2,1,8};control[37]=xc::crc8(control+2,35);CHECK(relay.offer(control,38));
 xc::WireParser parser;uint8_t chunk[20];unsigned controls=0,events=0;
 for(unsigned guard=0;guard<60;guard++){
  unsigned n=relay.next(chunk);if(!n)break;CHECK(n<=20);
  for(unsigned i=0;i<n;i++)if(parser.feed(chunk[i])){
   if(parser.data[3]==0x82){controls++;CHECK(events==0);CHECK(parser.data[7]==2);}
   if(parser.data[3]==0x85){CHECK(parser.data[6]==events);events++;}
  }
 }
 CHECK(controls==1);CHECK(events==8);CHECK(parser.bad==0);
 std::puts("PASS BLE relay: state priority, eight ordered event frames, bounded overflow, ATT20 CRC");return 0;
}
