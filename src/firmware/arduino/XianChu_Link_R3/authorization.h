#pragma once
#include <stdint.h>
#include <atomic>
namespace xc {
// A late authentication/disconnect event from another connection cannot change
// the active peer's authority. The supported firmware admits one phone only.
struct PeerSession {
  static constexpr uint16_t NONE=0xffff;
  std::atomic<uint16_t> handle{NONE};
  bool claim(uint16_t incoming){
    if(incoming==NONE)return false;
    uint16_t empty=NONE;
    return handle.compare_exchange_strong(empty,incoming);
  }
  bool matches(uint16_t incoming) const {return incoming!=NONE && handle.load()==incoming;}
  bool release(uint16_t incoming){
    if(incoming==NONE)return false;
    return handle.compare_exchange_strong(incoming,NONE);
  }
};
// A successful GATT write is not a transmission grant. BLE additionally needs
// authenticated encryption and an explicit ARM for this connection generation.
struct Authorization {
  enum Owner : uint8_t { NONE, USB, BLE } owner=NONE;
  uint32_t epoch=0, touched=0;
  static constexpr uint32_t LEASE_MS=60000;
  void disarm(){owner=NONE;}
  bool armUSB(uint32_t now,bool fresh,uint32_t currentEpoch){
    if(!fresh)return false;
    owner=USB;epoch=currentEpoch;touched=now;return true;
  }
  bool armBLE(uint32_t now,bool fresh,bool authenticated,uint32_t currentEpoch){
    if(!fresh || !authenticated)return false;
    owner=BLE;epoch=currentEpoch;touched=now;return true;
  }
  bool check(uint32_t now,bool fresh,bool connected,bool authenticated,uint32_t currentEpoch){
    if(owner==NONE)return false;
    if(!fresh || uint32_t(now-touched)>=LEASE_MS || epoch!=currentEpoch ||
       (owner==BLE && (!connected || !authenticated))){disarm();return false;}
    return true;
  }
  bool permitsBLE(uint32_t now,bool fresh,bool connected,bool authenticated,
                  uint32_t currentEpoch,uint32_t queuedEpoch){
    return check(now,fresh,connected,authenticated,currentEpoch) && owner==BLE && connected &&
           authenticated && queuedEpoch==currentEpoch;
  }
  void activity(uint32_t now){touched=now;}
};
}
