#pragma once
#include <stdint.h>
#include <stddef.h>

namespace xc {
inline uint8_t crc8(const uint8_t *p, size_t n) {
  uint8_t c=0;
  while(n--) { c^=*p++; for(int i=0;i<8;i++) c=(c&128)?uint8_t((c<<1)^7):uint8_t(c<<1); }
  return c;
}
struct Parser {
  uint8_t data[32]={}, count=0;
  uint32_t valid=0, bad=0;
  void reset() { count=0; }
  bool feed(uint8_t b) {
    if(count==0) { if(b==0xA5) data[count++]=b; return false; }
    if(count==1) { if(b==0x5A) data[count++]=b; else count=(b==0xA5)?1:0; return false; }
    data[count++]=b;
    if((count==3 && b!=1) || (count==5 && b>20)) { ++bad; reset(); return false; }
    if(count>=7 && count==uint8_t(data[4]+7)) {
      // Since S03 the 0x81 config reply is owned by config_bridge.h's ConfigParser;
      // a CRC-valid frame of another type is neither a valid status nor an error
      // for THIS parser, so it is ignored without touching either counter. A CRC
      // failure or a malformed header still counts bad whatever the type is.
      const bool crc_ok=crc8(data+2,count-3)==b;
      const bool is_status=data[3]==0x80 && data[4]==15;
      const bool was_status_frame=data[3]==0x80;
      reset();
      if(crc_ok && is_status) { ++valid; return true; }
      if(!crc_ok || was_status_frame) ++bad;
      return false;
    }
    return false;
  }
};
enum class View { WAIT, STALE, PANIC, TEST, CAL_REQUIRED, GUIDE, CAL_OK };
inline bool canTransmit(bool have, uint32_t age) { return have && age<=700; }
inline View view(bool have, uint32_t age, uint8_t flags) {
  if(!have) return View::WAIT;
  if(age>700) return View::STALE;
  if(flags&8) return View::PANIC;
  if(flags&4) return View::TEST;
  if(!(flags&16)) return View::CAL_REQUIRED;
  if(flags&2) return View::GUIDE;
  return View::CAL_OK;
}
inline const char *label(View v) {
  switch(v) {
    case View::WAIT:return "WAIT FPGA"; case View::STALE:return "FPGA STALE";
    case View::PANIC:return "PANIC / MUTED"; case View::TEST:return "32-PART TEST";
    case View::CAL_REQUIRED:return "CAL REQUIRED"; case View::GUIDE:return "GUIDE ACTIVE";
    default:return "CAL OK";
  }
}
inline bool commandOK(const uint8_t *p, size_t n) {
  if(n<7 || n>15 || p[0]!=0xA5 || p[1]!=0x5A || p[2]!=1 || p[4]+7u!=n || crc8(p+2,n-3)!=p[n-1]) return false;
  switch(p[3]) {
    case 0x10:return p[4]==2 && p[7]>=1 && p[7]<=32;
    case 0x11:return p[4]==5 && p[6]<32 && (p[7]&0xF0)==0 && (p[7]>>2)<=2 && (p[8]||p[9]||p[10]);
    case 0x12:return p[4]==1;
    case 0x13:return p[4]==1 && p[6]<=2;
    case 0x14:return p[4]==0;
    case 0x20:return p[4]==4 && p[6]<=2 && p[7]<=4;
    case 0x15:return p[4]==8 && p[6]<=5;   // S03: config requests relay, the FPGA policy engine still judges every field
    case 0x16:return p[4]==4 && p[7]>=1 && p[7]<=64 && p[9]>=1 && p[8]<p[9];  // S04 BEGIN2: song, count, seg_idx, seg_count
    case 0x17:return p[4]==5 && p[6]<64 && p[7]<0x40 && ((p[7]>>4)&3)!=3 && (p[8]||p[9]||p[10]);  // STEP2
    case 0x18:return p[4]==2;              // COMMIT2: song + steps CRC
    case 0x19:return p[4]==1 && p[6]<=3;   // S08 FX_CONTROL: effect mode select
    case 0x1B:return p[4]==2 && p[7]>=1 && p[7]<=64;
    case 0x1C:{if(p[4]!=8 || p[6]>=64)return false;for(int i=7;i<11;i++)if(p[i]!=0 && (p[i]<36 || p[i]>96))return false;const uint32_t d=p[11]|(uint32_t(p[12])<<8)|(uint32_t(p[13])<<16);return d>=960 && d<=2880000;}
    case 0x1D:return p[4]==2;
    case 0x1E:return p[4]==3 && p[6]<=2 && p[7]<=3;
    case 0x1F:return p[4]==0;
    default:return false;
  }
}
inline size_t ping(uint8_t seq, uint8_t *p) {
  const uint8_t first[]={0xA5,0x5A,1,0x14,0,seq};
  for(size_t i=0;i<6;i++) p[i]=first[i];
  p[6]=crc8(p+2,4);
  return 7;
}
} // namespace xc
