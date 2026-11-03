#include <cstdio>
#include <cstdint>
#include <cassert>
#include <initializer_list>
#if defined(__has_include)
#if __has_include("../capture_pcm.h")
#include "../capture_pcm.h"
#define HAVE_CAPTURE_PCM 1
#endif
#endif
int main(){
#ifndef HAVE_CAPTURE_PCM
  std::fprintf(stderr,"FAIL capture packing implementation missing\n");return 1;
#else
  unsigned checks=0;
  // Independent serial fixture: 16 leading zero bits then signed PCM16 in
  // each 32-bit WS half, assembled MSB-first exactly like the current DAC RTL.
  for(unsigned i=0;i<10000;++i){const int16_t expected=int16_t((i*7919u)^0x8000u);uint32_t words[2]={0,0};for(unsigned channel=0;channel<2;++channel)for(int bit=31;bit>=0;--bit){const bool din=bit<16&&((uint16_t(expected)>>bit)&1u);words[channel]=(words[channel]<<1)|unsigned(din);}uint8_t pcm[2]={0,0};assert(xc::unpackDacFrames(words,2,pcm,1)==1);assert(pcm[0]==uint8_t(expected));assert(pcm[1]==uint8_t(uint16_t(expected)>>8));++checks;}
  uint32_t malformed[2]={0x10001,1};uint8_t out[2];assert(xc::unpackDacFrames(malformed,2,out,1)==0);++checks;malformed[0]=2;assert(xc::unpackDacFrames(malformed,2,out,1)==0);++checks;assert(!xc::unpackDacFrames(malformed,1,out,1));++checks;
  assert(xc::safeCapturePins(11,12,13));++checks;for(int pin: {0,3,8,9,17,18,19,20,26,33,45,46}){assert(!xc::safeCapturePins(pin,12,13));++checks;}assert(!xc::safeCapturePins(11,11,13));++checks;
  std::printf("PASS capture packing %u checks\n",checks);return 0;
#endif
}
