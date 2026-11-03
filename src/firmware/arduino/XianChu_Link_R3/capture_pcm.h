#pragma once
#include <cstddef>
#include <cstdint>
namespace xc {
inline bool captureGPIO(int pin){return pin==4||pin==5||pin==6||pin==7||(pin>=10&&pin<=16)||pin==21;}
inline bool safeCapturePins(int bclk,int ws,int data){return captureGPIO(bclk)&&captureGPIO(ws)&&captureGPIO(data)&&bclk!=ws&&bclk!=data&&ws!=data;}
// Current DAC: two identical mono samples, each in the LOW 16 bits of a
// zero-padded 32-bit MSB-aligned slot. No conversion from 16-bit Philips I2S.
inline std::size_t unpackDacFrames(const uint32_t* words,std::size_t count,uint8_t* out,std::size_t capacity){
  if(!words||!out||(count&1u)||count/2>capacity)return 0;
  for(std::size_t i=0;i<count;i+=2){if((words[i]&0xffff0000u)||(words[i+1]&0xffff0000u)||words[i]!=words[i+1])return 0;out[i]=uint8_t(words[i]);out[i+1]=uint8_t(words[i]>>8);}
  return count/2;
}
}
