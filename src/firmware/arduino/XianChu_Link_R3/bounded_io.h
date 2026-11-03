#pragma once
#include <stdint.h>
#include <stddef.h>
#include <string.h>

namespace xc {
// The application never waits for a USB reader. Configure its USB driver with
// a zero TX timeout before using this pump. Whole lines own their queue slots;
// a short write resumes at its byte offset instead of interleaving JSON lines.
template <size_t Slots=4, size_t Capacity=768> class UsbLines {
  char data_[Slots][Capacity]{};
  size_t lengths_[Slots]{}, head_=0, count_=0, offset_=0;
 public:
  uint32_t dropped=0, short_writes=0;
  size_t pending() const { return count_; }
  bool offer(const char* text,size_t n) {
    if(!n || n>Capacity || count_==Slots) { ++dropped; return false; }
    size_t tail=(head_+count_)%Slots;
    memcpy(data_[tail],text,n); lengths_[tail]=n; ++count_; return true;
  }
  template<class Port> size_t pump(Port& port) {
    if(!count_) return 0;
    int room=port.availableForWrite();
    if(room<=0) return 0;
    size_t n=lengths_[head_]-offset_;
    if(n>64) n=64;
    if(n>size_t(room)) n=size_t(room);
    size_t sent=port.write(reinterpret_cast<const uint8_t*>(data_[head_]+offset_),n);
    if(sent>n) sent=n;
    if(sent<n) ++short_writes;
    offset_+=sent;
    if(offset_==lengths_[head_]) { head_=(head_+1)%Slots; --count_; offset_=0; }
    return sent;
  }
};

// An active 22-byte status frame is immutable until both ATT fragments finish.
// Incoming status may replace only the pending frame, never half a sent frame.
class StatusFragments {
  uint8_t active_[22]{}, pending_[22]{};
  uint8_t offset_=22;
  bool have_pending_=false;
 public:
  void reset() { offset_=22; have_pending_=false; }
  void offer(const uint8_t* p) {
    if(offset_==22) { memcpy(active_,p,22); offset_=0; have_pending_=false; }
    else { memcpy(pending_,p,22); have_pending_=true; }
  }
  bool in_progress() const { return offset_!=22; }
  uint8_t next(uint8_t* p) {
    if(offset_==22) {
      if(!have_pending_) return 0;
      memcpy(active_,pending_,22); have_pending_=false; offset_=0;
    }
    uint8_t n=(22-offset_>20)?20:uint8_t(22-offset_);
    memcpy(p,active_+offset_,n); offset_+=n; return n;
  }
};
} // namespace xc
