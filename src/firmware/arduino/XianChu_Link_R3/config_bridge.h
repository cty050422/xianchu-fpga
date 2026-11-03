#pragma once
// S3 configuration bridge (task S03): an independent 0x15/0x81 path beside the
// 0x80 status parser. Contract highlights, all testable on a host:
//   * ConfigParser accepts ONLY the 18-byte 0x81 reply frame. It never touches
//     the score-status freshness clock: the application advances frameMs from
//     the 0x80 parser only, so a config reply can never make stale audio state
//     look fresh (PROTOCOL_SPEC_V1 authority_rules.freshness_separation).
//   * The bridge keeps at most ONE request in flight. A request whose reply
//     does not arrive within its timeout is resent ONCE with the identical
//     bytes: the FPGA replay cache answers a repeat (same sequence + same body)
//     with the cached result, so the retry is idempotent and can never re-apply
//     or corrupt a commit. A second timeout fails the request for good.
//   * A 0x81 whose echoed sequence does not match the request in flight is
//     counted and dropped - it belongs to nobody.
//   * All counters are bounded and exposed for the status JSON.
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include "link_protocol.h"

namespace xc {

struct ConfigReply {
  uint8_t  sequence=0;   // low 8 bits of the request_seq
  uint8_t  op=0, field=0, result=0;
  uint16_t value=0, epoch=0;
  uint32_t supported_mask=0;
  uint8_t  first_field=0;
};

// Build a 0x15 CONFIG request frame (15 bytes total) into out; returns 15.
// Payload is 8 bytes: op, field, value LE16, token LE16, request_seq LE16.
inline size_t config_request(uint8_t op, uint8_t field, uint16_t value,
                             uint16_t token, uint16_t request_seq, uint8_t *out) {
  const uint8_t frame[14]={0xA5,0x5A,1,0x15,8,uint8_t(request_seq),
    op,field,uint8_t(value&0xFF),uint8_t(value>>8),
    uint8_t(token&0xFF),uint8_t(token>>8),
    uint8_t(request_seq&0xFF),uint8_t(request_seq>>8)};
  memcpy(out,frame,14);
  out[14]=crc8(out+2,12);
  return 15;
}

class ConfigParser {
  uint8_t data_[18]={};
  uint8_t count_=0;
  ConfigReply last_{};
 public:
  uint32_t replies=0, bad=0, unmatched=0;
  // Track the request sequence expected next, so a reply can be matched to the
  // request in flight. 0 = nobody is waiting (all replies then count unmatched).
  uint8_t expected_seq=0;
  bool waiting=false;

  void reset() { count_=0; waiting=false; expected_seq=0; }
  // Call when a request is sent; seq_low8 is the low byte of its request_seq.
  void expect(uint16_t request_seq) { expected_seq=uint8_t(request_seq); waiting=true; count_=0; }
  // Call when the request in flight is abandoned (disarm, BLE disconnect).
  void abandon() { waiting=false; }

  bool have() const { return last_seen_; }
  const ConfigReply& last() const { return last_; }
  // Raw bytes of the last completed 0x81 frame (18 bytes) for relaying.
  const uint8_t* raw() const { return data_; }
  static constexpr size_t RAW_LEN = 18;
  // A UART stall must abandon a half-received frame without dropping the
  // waiting state or the counters (mirrors the 0x80 parser's byte timeout).
  void reset_partial() { count_=0; }

  // Feed one UART byte. Returns true exactly when a complete 0x81 frame with a
  // valid CRC was decoded this call.
  bool feed(uint8_t b) {
    if(count_==0) { if(b==0xA5) data_[count_++]=b; return false; }
    if(count_==1) { if(b==0x5A) data_[count_++]=b; else count_=(b==0xA5)?1:0; return false; }
    data_[count_++]=b;
    if(count_==3 && b!=1) { ++bad; reset_count(); return false; }        // version gate
    if(count_==4 && b!=0x81) { ++bad; reset_count(); return false; }     // type gate
    if(count_==5 && b!=11) { ++bad; reset_count(); return false; }       // length gate
    if(count_>=7 && count_==uint8_t(data_[4]+7)) {
      const bool ok=crc8(data_+2,count_-3)==b;
      reset_count();
      if(!ok) { ++bad; return false; }
      ConfigReply r;
      r.sequence=data_[5]; r.op=data_[6]; r.field=data_[7]; r.result=data_[8];
      r.value=uint16_t(data_[9] | (uint16_t(data_[10])<<8));
      r.epoch=uint16_t(data_[11] | (uint16_t(data_[12])<<8));
      r.supported_mask=uint32_t(data_[13]) | (uint32_t(data_[14])<<8) |
                       (uint32_t(data_[15]&0x3F)<<16);
      r.first_field=data_[16];
      last_=r; last_seen_=true;
      if(waiting && r.sequence==expected_seq) { waiting=false; ++replies; return true; }
      ++unmatched;   // nobody waiting, or a stale/duplicate reply
      return false;
    }
    return false;
  }
 private:
  bool last_seen_=false;
  void reset_count() { count_=0; }
};

// One-in-flight retry state for requests the BRIDGE itself sends (the phone
// drives its own session; the bridge uses this for its release-on-disconnect).
class ConfigTransaction {
 public:
  enum class State { IDLE, WAIT, RETRY, FAILED, DONE };
  State state=State::IDLE;
  uint8_t frame[15]={};
  size_t n=0;
  uint32_t sent_at=0;
  uint32_t timeout_ms=300;

  void start(uint8_t op, uint8_t field, uint16_t value, uint16_t token,
             uint16_t request_seq, uint32_t now_ms) {
    n=config_request(op,field,value,token,request_seq,frame);
    state=State::WAIT; sent_at=now_ms;
  }
  void on_reply() { state=State::DONE; }
  // Returns true when the frame must be (re)sent now.
  bool on_tick(uint32_t now_ms) {
    if(state==State::WAIT && uint32_t(now_ms-sent_at)>timeout_ms) {
      state=State::RETRY; sent_at=now_ms; return true;      // first retry, same bytes
    }
    if(state==State::RETRY && uint32_t(now_ms-sent_at)>timeout_ms) {
      state=State::FAILED; return false;                    // give up honestly
    }
    return false;
  }
};

} // namespace xc
