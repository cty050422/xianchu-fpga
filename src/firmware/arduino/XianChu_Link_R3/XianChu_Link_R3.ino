// 0 keeps current S3-master OLED wiring; 1 is the future FPGA-OLED profile.
#ifndef XC_FPGA_OLED
#define XC_FPGA_OLED 0
#endif
// XianChu LINK R3: bounded USB logging; immutable BLE status fragments. Same FPGA wire protocol.
// S3 RX17 <- FPGA J8.5 AA19 TX; S3 TX18 -> FPGA J8.6 AB20 RX.
// TX18 is INPUT until explicit USB ARM or authenticated BLE ARM. No autonomous playback.
// OLED: 3V3/GND/SDA8/SCL9. Logs use native HWCDC (USB GPIO19/20),
// not the UART0 USB bridge. Verify which physical USB connector routes there.
#include <Arduino.h>
#include <Wire.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include <BLESecurity.h>
#include "authorization.h"
#include <atomic>
#include "link_protocol.h"
#include "config_bridge.h"
#include "bounded_io.h"
#include "oled_guidance.h"
#include "oled_status.h"
#include "recording_bridge.h"
#include "mobile_view.h"
#include <stdarg.h>
#if !defined(CONFIG_NIMBLE_ENABLED)
#error "R3 is validated with Arduino ESP32 3.3.12 NimBLE; use the documented board profile"
#endif
#if ARDUINO_USB_CDC_ON_BOOT != 1 || ARDUINO_USB_MODE != 1
#error "XianChu R3 requires USB CDC On Boot=Enabled and USB Mode=Hardware CDC and JTAG"
#endif

static constexpr char BUILD[]="XC-LINK-R3-LIVE-20261101";
static constexpr char LINK_SERVICE_UUID[]="7a330001-4b62-4f70-9f60-66706761736d";
static constexpr char LINK_CMD_UUID[]="7a330002-4b62-4f70-9f60-66706761736d";
static constexpr char LINK_STATUS_UUID[]="7a330003-4b62-4f70-9f60-66706761736d";
static constexpr char LINK_INFO_UUID[]="7a330004-4b62-4f70-9f60-66706761736d";
Adafruit_SSD1306 oled(128,64,&Wire,-1);
BLECharacteristic *statusChr=nullptr,*infoChr=nullptr;
std::atomic<bool> connected{false},restartAdv{false},peerAuthenticated{false};
std::atomic<bool> pairingSinkReady{false};
std::atomic<uint32_t> bleEpoch{0},pairingCode{0};
std::atomic<bool> pairingVisible{false};
xc::Authorization authorization;
xc::PeerSession peerSession;
uint32_t observedEpoch=0;
struct Message { bool local; uint8_t n; uint32_t epoch; uint8_t bytes[32]; };
QueueHandle_t commands=nullptr;
QueueHandle_t recordingLogs=nullptr;
std::atomic<uint32_t> queueDrops{0};
xc::Parser parser;
xc::WireParser wireParser;xc::TelemetryRelay mobileRelay;xc::MobileView mobileLatest;uint32_t mobileMs=0,feedbackAt=0;uint16_t feedbackWrong=0,feedbackMiss=0;uint8_t feedbackKind=0;
xc::ConfigParser cfgParser;
uint8_t cfgNotify[18]{}; bool cfgNotifyPending=false;
bool oledOK=false,haveFrame=false,armed=false,pingPending=false;
uint8_t oledAddress=0,latest[22]={},pingSeq=0;
xc::UsbLines<> usbLines;
xc::StatusFragments statusFragments;
uint32_t loopMaxMs=0,previousLoopMs=0;
uint32_t frameMs=0,byteMs=0,rxBytes=0,commandRejects=0,commandSent=0,pingOK=0,pingTimeout=0,pingAt=0,lastNotify=0;
uint32_t cfgRelayed=0;
char localReply[21]="LOCAL BOOT";
String consoleLine;
void setTransmit(bool enable);
void publishIdentity();

void usbLogf(const char* format, ...) {
  char line[768]; va_list args; va_start(args,format);
  int n=vsnprintf(line,sizeof(line),format,args); va_end(args);
  if(n<0 || size_t(n)>=sizeof(line)) { ++usbLines.dropped; return; }
  usbLines.offer(line,size_t(n));
}

bool fresh() { return xc::canTransmit(haveFrame,uint32_t(millis()-frameMs)); }
uint8_t flags() { return haveFrame?latest[7]:0; }
void localEvent(const char *s) {
  snprintf(localReply,sizeof(localReply),"%s",s);
  usbLogf("LOCAL %s\n",localReply);
  publishIdentity();
}
void postRecordingEvent(const char *s) {
  if(!recordingLogs)return;
  char line[40]{};snprintf(line,sizeof(line),"%s",s);
  xQueueSend(recordingLogs,line,0); // background tasks never touch USB/BLE objects
}
void sendPing() {
  if(!armed || !fresh()) { localEvent("NO FPGA / DISARMED"); return; }
  if(pingPending) { localEvent("PING BUSY"); return; }
  uint8_t frame[7]; pingSeq=uint8_t(latest[19]+1);
  Serial1.write(frame,xc::ping(pingSeq,frame)); Serial1.flush();
  authorization.activity(millis());++commandSent; pingPending=true; pingAt=millis(); localEvent("PING SENT");
}
void localCommand(String s, bool fromBle=false) {
  s.trim(); s.toUpperCase();
  if(s=="HELLO") localEvent("LOCAL HELLO OK");
  else if(s=="ARM" && fromBle) {
    if(authorization.armBLE(millis(),fresh(),peerAuthenticated.load(),bleEpoch.load())) {setTransmit(true);localEvent("BLE UART ARMED");}
    else localEvent("PAIR / FPGA REQUIRED");
  }
  else if(s=="DISARM") {authorization.disarm();setTransmit(false);localEvent("UART TX DISARMED");}
  else if(s=="KEEP" && fromBle) {
    const uint32_t e=bleEpoch.load();
    if(authorization.permitsBLE(millis(),fresh(),connected.load(),peerAuthenticated.load(),e,e)) {
      authorization.activity(millis());localEvent("CONTROL ALIVE");
    } else localEvent("CONTROL EXPIRED");
  }
  else if(s=="STATUS") publishIdentity();
  else if(s=="PING") sendPing();
  else localEvent("USE HELLO OR PING");
}
class ServerCB : public BLEServerCallbacks {
  void onConnect(BLEServer *server,ble_gap_conn_desc *desc) override {
    if(!desc)return;
    if(!peerSession.claim(desc->conn_handle)){server->disconnect(desc->conn_handle);return;}
    peerAuthenticated=false;pairingVisible=false;++bleEpoch;connected=true;
  }
  void onDisconnect(BLEServer*,ble_gap_conn_desc *desc) override {
    if(!desc || !peerSession.release(desc->conn_handle))return;
    connected=false;peerAuthenticated=false;pairingVisible=false;++bleEpoch;restartAdv=true;
    cfgParser.abandon();cfgParser.reset_partial();
  }
};
class WriteCB : public BLECharacteristicCallbacks {
  bool local;
 public:
  explicit WriteCB(bool isLocal):local(isLocal) {}
  void onWrite(BLECharacteristic *c,ble_gap_conn_desc *desc) override {
    if(!desc || !peerSession.matches(desc->conn_handle) || !peerAuthenticated.load()){
      ++queueDrops;return;
    }
    auto s=c->getValue(); Message m{}; m.local=local;m.epoch=bleEpoch.load();
    if(s.length()==0 || s.length()>sizeof(m.bytes)) { ++queueDrops; return; }
    m.n=uint8_t(s.length()); memcpy(m.bytes,s.c_str(),m.n);
    if(xQueueSend(commands,&m,0)!=pdTRUE) ++queueDrops;
  }
};
class SecurityCB : public BLESecurityCallbacks {
 public:
  uint32_t onPassKeyRequest() override {return BLESecurity::getPassKey();}
  void onPassKeyNotify(uint32_t pin) override {pairingCode=pin;pairingVisible=true;}
  bool onSecurityRequest() override {return pairingSinkReady.load();}
  bool onConfirmPIN(uint32_t) override {return false;} // no fake physical yes/no approval
#if defined(CONFIG_NIMBLE_ENABLED)
  void onAuthenticationComplete(ble_gap_conn_desc *desc,int status) override {
    if(!desc || !peerSession.matches(desc->conn_handle))return;
    peerAuthenticated=pairingSinkReady.load() && status==0 && desc->sec_state.encrypted && desc->sec_state.authenticated;
    pairingVisible=false;
  }
#elif defined(CONFIG_BLUEDROID_ENABLED)
  void onAuthenticationComplete(esp_ble_auth_cmpl_t desc) override {
    peerAuthenticated=desc.success && (desc.auth_mode & ESP_LE_AUTH_REQ_MITM);pairingVisible=false;
  }
#endif
};
void setTransmit(bool enable) {
  if(armed==enable)return;
  armed=enable;pingPending=false;cfgParser.abandon();Serial1.end();pinMode(18,INPUT);
  Serial1.begin(115200,SERIAL_8N1,17,(enable || XC_FPGA_OLED)?18:-1);
  if(!enable && !XC_FPGA_OLED)pinMode(18,INPUT);parser.reset();wireParser.reset();
}
void publishIdentity() {
  if(!infoChr)return;
  char identity[128];snprintf(identity,sizeof(identity),"%s armed=%u protocol=1 auth=%u phone_arm=1",
    BUILD,unsigned(armed && authorization.owner==xc::Authorization::BLE),unsigned(peerAuthenticated.load()));
  infoChr->setValue((uint8_t*)identity,strlen(identity));
  // Read identity as one value. Legacy info notifications stay <=20 bytes.
  if(connected){infoChr->setValue(String(localReply));infoChr->notify();infoChr->setValue((uint8_t*)identity,strlen(identity));}
}

void draw() {
  if(!oledOK) return;
  oled.clearDisplay(); oled.setTextSize(1); oled.setTextColor(SSD1306_WHITE);
  const xc::GuidanceView guidance=xc::guidanceView(latest,haveFrame,uint32_t(millis()-frameMs));
  if(mobileLatest.valid && fresh() && uint32_t(millis()-mobileMs)<=700 && !(flags()&12) && (flags()&16)) {
    xc::renderPerformance(mobileLatest,oled.getBuffer());
    if(feedbackKind && uint32_t(millis()-feedbackAt)<800){
      memset(oled.getBuffer()+256,0,256);
      xc::performance_font::text(oled.getBuffer(),0,16,feedbackKind==1?"错按":"漏拍");
    }
  } else if(guidance.visible) {
    xc::renderGuidance(guidance,oled.getBuffer());
  } else {
  xc::renderStatus(latest,haveFrame,uint32_t(millis()-frameMs),connected,armed,false,0,oled.getBuffer());
  }
  if(pairingVisible)xc::renderStatus(latest,haveFrame,0,connected,armed,true,pairingCode.load(),oled.getBuffer());
  oled.display();
}
void logStatus() {
  const uint32_t sampled=millis(),age=sampled-frameMs;
  const bool present=haveFrame,isFresh=xc::canTransmit(present,age);
  const uint8_t f=flags();
  char ageS[16],flagsS[16],seqS[16],resultS[16],songS[16],stepS[16],zoneS[16],hitsS[16],wrongS[16],missS[16];
  auto value=[](char* out,uint32_t n,bool have){if(have)snprintf(out,16,"%lu",(unsigned long)n);else strcpy(out,"null");};
  value(ageS,age,present);value(flagsS,f,present);value(seqS,latest[19],present);value(resultS,latest[20],present);
  value(songS,latest[6],present&&(f&1));value(stepS,latest[8],present&&(f&1));value(zoneS,(latest[9]&3)+1,present&&(f&1));
  value(hitsS,latest[10]|(uint16_t(latest[11])<<8),present);
  value(wrongS,latest[12]|(uint16_t(latest[13])<<8),present);
  value(missS,latest[14]|(uint16_t(latest[15])<<8),present);
  usbLogf(R"json({"build":"%s","uptime_ms":%lu,"oled_addr":%u,"oled_init":%s,"ble":%s,"armed":%s,"rx_bytes":%lu,"valid_frames":%lu,"bad_frames":%lu,"fpga_fresh":%s,"age_ms":%s,"flags":%s,"last_cmd_seq":%s,"last_cmd_result":%s,"remote_song_id":%s,"step_index":%s,"target_zone_1based":%s,"hits":%s,"wrong":%s,"misses":%s,"score_loaded":%s,"guide_active":%s,"state":"%s","sent":%lu,"rejected":%lu,"queue_drops":%lu,"ping_ok":%lu,"ping_timeout":%lu,"usb_log_dropped":%lu,"usb_short_writes":%lu,"loop_max_ms":%lu,"cfg_relayed":%lu,"cfg_replies":%lu,"cfg_bad":%lu,"cfg_unmatched":%lu,"cfg_waiting":%s,"cfg_last_result":%u,"cfg_last_epoch":%u})json" "\n",
    BUILD,(unsigned long)sampled,oledAddress,oledOK?"true":"false",connected?"true":"false",armed?"true":"false",
    (unsigned long)rxBytes,(unsigned long)parser.valid,(unsigned long)parser.bad,isFresh?"true":"false",
    ageS,flagsS,seqS,resultS,songS,stepS,zoneS,hitsS,wrongS,missS,
    present?((f&1)?"true":"false"):"null",present?((f&2)?"true":"false"):"null",
    xc::label(xc::view(present,age,f)),(unsigned long)commandSent,(unsigned long)commandRejects,
    (unsigned long)queueDrops.load(),(unsigned long)pingOK,(unsigned long)pingTimeout,
    (unsigned long)usbLines.dropped,(unsigned long)usbLines.short_writes,(unsigned long)loopMaxMs,
    (unsigned long)cfgRelayed,(unsigned long)cfgParser.replies,(unsigned long)cfgParser.bad,
    (unsigned long)cfgParser.unmatched,cfgParser.waiting?"true":"false",
    unsigned(cfgParser.last().result),unsigned(cfgParser.last().epoch));
}
void setup() {
  recordingLogs=xQueueCreate(4,40);
  Serial.setTxTimeoutMs(0); Serial.begin(115200); delay(300);
  usbLogf("\n%s PROFILE=FUSION-7298699 RX17=J8.5/AA19 TX18=J8.6/AB20\n",BUILD);
  usbLogf("FLASH_BYTES=%lu PSRAM_BYTES=%lu CDC=%d\n",(unsigned long)ESP.getFlashChipSize(),(unsigned long)ESP.getPsramSize(),ARDUINO_USB_CDC_ON_BOOT);
  pinMode(18,INPUT); Serial1.setRxBufferSize(512); Serial1.begin(115200,SERIAL_8N1,17,-1);
  if(XC_FPGA_OLED) Serial1.setPins(17,18);
#if !XC_FPGA_OLED
  Wire.begin(8,9); Wire.setClock(100000); Wire.setTimeOut(50);
  for(uint8_t addr=0x3C;addr<=0x3D;addr++) {
    Wire.beginTransmission(addr);
    if(Wire.endTransmission()==0) { oledAddress=addr; break; }
  }
  if(oledAddress) oledOK=oled.begin(SSD1306_SWITCHCAPVCC,oledAddress,true,false);
#endif
  usbLogf("OLED_ACK=0x%02X INIT=%u (ACK is not controller identification)\n",oledAddress,oledOK);
  pairingSinkReady=xc::pairingDisplayReady(XC_FPGA_OLED,oledOK,fresh());
  commands=xQueueCreate(8,sizeof(Message));
  if(!commands) { usbLogf("FATAL QUEUE_ALLOC\n"); while(true) { usbLines.pump(Serial); delay(10); } }
  BLEDevice::init("XianChu-LINK-R3"); BLEDevice::setMTU(185);
  BLEDevice::setSecurityCallbacks(new SecurityCB());
  BLESecurity::setAuthenticationMode(true,true,true);BLESecurity::setCapability(ESP_IO_CAP_OUT);
  BLESecurity::setPassKey(false);BLESecurity::regenPassKeyOnConnect(true);BLESecurity::setForceAuthentication(true);
  BLEServer *server=BLEDevice::createServer(); server->setCallbacks(new ServerCB());
  BLEService *service=server->createService(LINK_SERVICE_UUID);
  auto *cmd=service->createCharacteristic(LINK_CMD_UUID,BLECharacteristic::PROPERTY_WRITE|BLECharacteristic::PROPERTY_WRITE_ENC|BLECharacteristic::PROPERTY_WRITE_AUTHEN);
  cmd->setCallbacks(new WriteCB(false));
#if defined(CONFIG_BLUEDROID_ENABLED)
  cmd->setAccessPermissions(ESP_GATT_PERM_WRITE_ENC_MITM);
#endif
  statusChr=service->createCharacteristic(LINK_STATUS_UUID,BLECharacteristic::PROPERTY_READ|BLECharacteristic::PROPERTY_NOTIFY);
  statusChr->addDescriptor(new BLE2902());
  infoChr=service->createCharacteristic(LINK_INFO_UUID,BLECharacteristic::PROPERTY_READ|BLECharacteristic::PROPERTY_WRITE|BLECharacteristic::PROPERTY_NOTIFY|BLECharacteristic::PROPERTY_WRITE_ENC|BLECharacteristic::PROPERTY_WRITE_AUTHEN);

#if defined(CONFIG_BLUEDROID_ENABLED)
  infoChr->setAccessPermissions(ESP_GATT_PERM_READ|ESP_GATT_PERM_WRITE_ENC_MITM);
#endif
  infoChr->setCallbacks(new WriteCB(true)); infoChr->addDescriptor(new BLE2902());
  publishIdentity(); service->start();
  auto *adv=BLEDevice::getAdvertising(); adv->addServiceUUID(LINK_SERVICE_UUID); adv->setScanResponse(true); adv->start();
  usbLogf("BLE_READY XianChu-LINK-R3 | USB commands: HELLO, ARM, PING, DISARM, STATUS\n"); draw();
}
void loop() {
  uint32_t now=millis();
  const uint32_t epoch=bleEpoch.load();
  if(epoch!=observedEpoch){observedEpoch=epoch;authorization.disarm();setTransmit(false);}
  if(previousLoopMs && uint32_t(now-previousLoopMs)>loopMaxMs) loopMaxMs=now-previousLoopMs;
  previousLoopMs=now;
  while(Serial1.available()) {
    uint8_t b=uint8_t(Serial1.read()); ++rxBytes;
    if(wireParser.count && uint32_t(now-byteMs)>50) { wireParser.reset(); ++parser.bad; cfgParser.reset_partial(); }
    byteMs=now;
    if(wireParser.feed(b)) {
      const uint8_t*p=wireParser.data;const uint8_t n=p[4]+7;
      if(p[3]==0x80 && p[4]==15){
        memcpy(latest,p,22);frameMs=now;haveFrame=true;++parser.valid;
        const uint16_t w=uint16_t(p[12])|(uint16_t(p[13])<<8),m=uint16_t(p[14])|(uint16_t(p[15])<<8);
        if(w>feedbackWrong){feedbackKind=1;feedbackAt=now;}else if(m>feedbackMiss){feedbackKind=2;feedbackAt=now;}
        feedbackWrong=w;feedbackMiss=m;
        if(connected)statusFragments.offer(latest);
        if(pingPending && latest[19]==pingSeq && latest[20]==0){++pingOK;pingPending=false;localEvent("FPGA PING ACK");}
      } else if(p[3]==0x81 && n==18){
        // Phone owns matching. Forward valid replies even when the bridge has
        // no locally-originated config transaction; never refresh frameMs here.
        ++cfgRelayed;if(connected){memcpy(cfgNotify,p,18);cfgNotifyPending=true;}
      } else if(p[3]==0x82 && p[4]==31 && p[6]==1){
        mobileLatest=xc::mobileView(p);mobileMs=now;
        static uint32_t controlNotifyAt=0;
        if(connected && uint32_t(now-controlNotifyAt)>=200){mobileRelay.offer(p,n);controlNotifyAt=now;}
      } else if(p[3]==0x83 && p[4]==38 && connected){mobileRelay.offer(p,n);}
      else if(p[3]==0x84 && (p[4]==37 || p[4]==45) && connected){mobileRelay.offer(p,n);}
      else if(p[3]==0x85 && p[4]==8 && connected){mobileRelay.offer(p,n);} // T2 event telemetry
    }
  }
  if(armed && !authorization.check(now,fresh(),connected.load(),peerAuthenticated.load(),epoch)){setTransmit(false);localEvent("AUTH / LINK EXPIRED");}
  pairingSinkReady=xc::pairingDisplayReady(XC_FPGA_OLED,oledOK,fresh());
#if XC_FPGA_OLED
  static uint32_t panelAt=0;
  if(fresh() && uint32_t(now-panelAt)>=400 && Serial1.availableForWrite()>=10) {
    const uint32_t code=pairingVisible?pairingCode.load():0;
    uint8_t meta[10]={0xA5,0x5A,1,0x1A,3,0,uint8_t(code),uint8_t(code>>8),uint8_t((code>>16)&15),0};
    if(pairingVisible)meta[8]|=0x80;
    meta[9]=xc::crc8(meta+2,7);Serial1.write(meta,10);panelAt=now;
  }
#endif
  if(pingPending && uint32_t(now-pingAt)>1000) { pingPending=false; ++pingTimeout; localEvent("FPGA PING TIMEOUT"); }
  while(Serial.available()) {
    char c=char(Serial.read());
    if(c=='\r' || c=='\n') {
      consoleLine.trim();
      if(xc_record::command(consoleLine,postRecordingEvent)) {
        // Receive-only recording setup is handled independently of FPGA ARM.
      } else if(consoleLine=="ARM") {
        if(!fresh()) localEvent("ARM NEEDS FPGA DATA");
        else {
          authorization.armUSB(now,true,bleEpoch.load());setTransmit(true);localEvent("UART TX ARMED");
        }
      } else if(consoleLine=="DISARM") {
        authorization.disarm();setTransmit(false);localEvent("UART TX DISARMED");
      } else if(consoleLine=="STATUS") logStatus();
      else if(consoleLine.length()) localCommand(consoleLine);
      consoleLine="";
    } else if(consoleLine.length()<256) consoleLine+=c;
  }
  Message m{};
  char recordingLine[40];
  while(recordingLogs&&xQueueReceive(recordingLogs,recordingLine,0)==pdTRUE)usbLogf("RECORD %s\n",recordingLine);
  if(xQueueReceive(commands,&m,0)==pdTRUE) {
    if(!connected || m.epoch!=bleEpoch.load()){++commandRejects;localEvent("STALE BLE SESSION");}
    else if(m.local && !peerAuthenticated){++commandRejects;localEvent("PAIR FIRST");}
    else if(m.local) { String s; for(uint8_t i=0;i<m.n;i++) s+=char(m.bytes[i]); localCommand(s,true); }
    else if(!authorization.permitsBLE(now,fresh(),connected.load(),peerAuthenticated.load(),bleEpoch.load(),m.epoch) || !xc::commandOK(m.bytes,m.n)) { ++commandRejects; localEvent("CMD REJECTED"); }
    else if((flags()&2) && m.bytes[3]>=0x10 && m.bytes[3]<=0x12) {
      ++commandRejects; localEvent("STOP GUIDE FIRST");
    } else { Serial1.write(m.bytes,m.n); authorization.activity(now);++commandSent;localEvent("CMD FORWARDED"); }
  }
  if(restartAdv.exchange(false)) { BLEDevice::startAdvertising(); statusFragments.reset(); mobileRelay.reset();cfgNotifyPending=false; localEvent("BLE DISCONNECTED"); }
  if(connected && uint32_t(now-lastNotify)>=10) {
    uint8_t fragment[20]; uint8_t n=0;
    // Each selected frame drains completely before another type can start.
    if(mobileRelay.inProgress())n=mobileRelay.next(fragment);
    else if(statusFragments.in_progress())n=statusFragments.next(fragment);
    else if(cfgNotifyPending){memcpy(fragment,cfgNotify,18);n=18;cfgNotifyPending=false;}
    else {n=statusFragments.next(fragment);if(!n)n=mobileRelay.next(fragment);}
    if(n) { statusChr->setValue(fragment,n); statusChr->notify(); lastNotify=now; }
  }
  static uint32_t lastDraw=0,lastLog=0;
  if(uint32_t(now-lastDraw)>=200) { lastDraw=now; draw(); }
  if(uint32_t(now-lastLog)>=1000) { lastLog=now; logStatus(); }
  usbLines.pump(Serial);
  delay(1);
}
