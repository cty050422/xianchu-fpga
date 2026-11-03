#pragma once
// Optional, RECEIVE-ONLY DAC tap. Compiled in but completely inactive until
// explicit USB REC_WIFI / REC_SERVER / REC_PAIR / REC_PINS / REC_ON setup.
// Credentials stay in RAM. No arbitrary command is sent to FPGA. No paid API.
#ifndef XC_RECORDING_BRIDGE
#define XC_RECORDING_BRIDGE 1
#endif
#include "capture_pcm.h"
#if XC_RECORDING_BRIDGE
#include <WiFi.h>
#include <HTTPClient.h>
#include <driver/i2s_std.h>
#include <atomic>
namespace xc_record {
struct Configuration {char ssid[33]{},password[65]{},server[121]{},pairCode[7]{};int bclk=-1,ws=-1,din=-1;};
struct Block {uint32_t offset=0;uint16_t frames=0;uint8_t pcm[1024]{};};
static Configuration config;
static std::atomic<bool> enabled{false},workerLive{false},readerLive{false},stopReader{false},readFault{false};
static QueueHandle_t packets=nullptr;
static void (*logLine)(const char*)=nullptr;
static void log(const char* text){if(logLine)logLine(text);}
static bool privateServer(const String& url){
  if(!url.startsWith("http://")||url.length()>120)return false;String host=url.substring(7);int colon=host.indexOf(':');if(colon>=0){String port=host.substring(colon+1);if(!port.length())return false;for(size_t i=0;i<port.length();i++)if(!isDigit(port[i]))return false;int n=port.toInt();if(n<1||n>65535)return false;host=host.substring(0,colon);}IPAddress ip;if(!ip.fromString(host))return false;return ip[0]==10||(ip[0]==172&&ip[1]>=16&&ip[1]<=31)||(ip[0]==192&&ip[1]==168);
}
static String jsonString(const String& json,const char* key){String needle=String('"')+key+'"';int at=json.indexOf(needle);if(at<0)return String();at=json.indexOf(':',at+needle.length());if(at<0)return String();at++;while(at<int(json.length())&&json[at]==' ')at++;if(json[at]!='"')return String();int end=json.indexOf('"',at+1);return end<0?String():json.substring(at+1,end);}
static int request(const char* method,const String& route,const uint8_t* body,size_t length,const String& token,String& response,bool captureToken=false,uint32_t offset=0){
  if(WiFi.status()!=WL_CONNECTED)return -1;HTTPClient http;http.setConnectTimeout(500);http.setTimeout(1500);if(!http.begin(String(config.server)+route))return -2;
  if(token.length())http.addHeader(captureToken?"x-capture-token":"x-device-token",token);
  http.addHeader("content-type",route.indexOf("/chunks/")>=0?"application/octet-stream":"application/json");if(route.indexOf("/chunks/")>=0)http.addHeader("x-sample-offset",String(offset));
  // The pinned Arduino HTTPClient has a mutable-pointer signature but only
  // reads this payload. Responses without a bounded length are not buffered.
  int code=http.sendRequest(method,const_cast<uint8_t*>(body),length);if(code>0&&http.getSize()>=0&&http.getSize()<=8192)response=http.getString();else response=String();http.end();return code;
}
static bool IRAM_ATTR dmaOverflow(i2s_chan_handle_t,i2s_event_data_t*,void*){readFault.store(true);return false;}
static void reader(void*){
  i2s_chan_handle_t rx=nullptr;const uint32_t maximumFrames=48000u*120u;uint32_t offset=0;bool running=false;
  i2s_chan_config_t channel=I2S_CHANNEL_DEFAULT_CONFIG(I2S_NUM_AUTO,I2S_ROLE_SLAVE);channel.dma_desc_num=12;channel.dma_frame_num=256;
  if(i2s_new_channel(&channel,nullptr,&rx)!=ESP_OK){readFault=true;readerLive=false;vTaskDelete(nullptr);return;}
  i2s_std_config_t cfg{};cfg.clk_cfg=I2S_STD_CLK_DEFAULT_CONFIG(48000);cfg.slot_cfg=I2S_STD_MSB_SLOT_DEFAULT_CONFIG(I2S_DATA_BIT_WIDTH_32BIT,I2S_SLOT_MODE_STEREO);cfg.gpio_cfg.mclk=I2S_GPIO_UNUSED;cfg.gpio_cfg.bclk=gpio_num_t(config.bclk);cfg.gpio_cfg.ws=gpio_num_t(config.ws);cfg.gpio_cfg.dout=I2S_GPIO_UNUSED;cfg.gpio_cfg.din=gpio_num_t(config.din);
  i2s_event_callbacks_t callbacks{};callbacks.on_recv_q_ovf=dmaOverflow;
  if(i2s_channel_init_std_mode(rx,&cfg)!=ESP_OK||i2s_channel_register_event_callback(rx,&callbacks,nullptr)!=ESP_OK||i2s_channel_enable(rx)!=ESP_OK){readFault=true;}else running=true;
  uint32_t raw[1024]{};const uint32_t began=millis();
  while(running&&!stopReader.load()&&!readFault.load()&&offset<maximumFrames){size_t bytes=0;esp_err_t result=i2s_channel_read(rx,raw,sizeof(raw),&bytes,100);if(result!=ESP_OK||!bytes||bytes%8){readFault=true;break;}Block block;block.frames=uint16_t(xc::unpackDacFrames(raw,bytes/4,block.pcm,512));if(!block.frames){readFault=true;break;}if(offset+block.frames>maximumFrames)block.frames=uint16_t(maximumFrames-offset);block.offset=offset;if(xQueueSend(packets,&block,0)!=pdTRUE){readFault=true;break;}offset+=block.frames;if(offset>=48000){const uint32_t elapsed=uint32_t(millis()-began);if(!elapsed||uint64_t(offset)*1000u<uint64_t(elapsed)*43200u||uint64_t(offset)*1000u>uint64_t(elapsed)*52800u){readFault=true;break;}}}
  if(running)i2s_channel_disable(rx);i2s_del_channel(rx);readerLive=false;vTaskDelete(nullptr);
}
static void capture(const String& id,const String& ticket){
  packets=xQueueCreate(24,sizeof(Block));if(!packets){log("REC_NO_BUFFER");return;}stopReader=false;readFault=false;readerLive=true;
  if(xTaskCreatePinnedToCore(reader,"xc-pcm-rx",8192,nullptr,2,nullptr,1)!=pdPASS){readerLive=false;readFault=true;}
  uint8_t batch[8192];uint32_t sequence=0,frames=0;bool networkOK=true;String response;log("REC_STARTED");
  while((readerLive.load()||uxQueueMessagesWaiting(packets)>0)&&networkOK){
    if(!enabled.load())stopReader=true;
    size_t used=0;Block block;for(unsigned n=0;n<8;n++){if(xQueueReceive(packets,&block,pdMS_TO_TICKS(20))!=pdTRUE)break;if(block.offset!=frames+used/2){readFault=true;stopReader=true;break;}memcpy(batch+used,block.pcm,size_t(block.frames)*2);used+=size_t(block.frames)*2;}
    if(used){int code=request("POST","/performances/v1/capture/"+id+"/chunks/"+String(sequence),batch,used,ticket,response,true,frames);if(code<0){code=request("POST","/performances/v1/capture/"+id+"/chunks/"+String(sequence),batch,used,ticket,response,true,frames);}if(code!=200){networkOK=false;stopReader=true;break;}frames+=used/2;sequence++;}
    if(sequence%6==0){int code=request("GET","/performances/v1/capture/"+id+"/status",nullptr,0,ticket,response,true);if(code!=200){networkOK=false;stopReader=true;}else if(response.indexOf("\"stopRequested\":true")>=0)stopReader=true;}
  }
  stopReader=true;while(readerLive.load())vTaskDelay(pdMS_TO_TICKS(20));
  const bool complete=networkOK&&!readFault.load()&&enabled.load()&&frames>0;String finish=String("{\"complete\":")+(complete?"true":"false")+",\"frames\":"+String(frames)+",\"reason\":\"capture interrupted or overflow\"}";
  int status=request("POST","/performances/v1/capture/"+id+"/finish",reinterpret_cast<const uint8_t*>(finish.c_str()),finish.length(),ticket,response,true);
  log(complete&&status==200?"REC_FINISHED":"REC_INCOMPLETE");vQueueDelete(packets);packets=nullptr;
}
static void worker(void*){
  WiFi.persistent(false);WiFi.mode(WIFI_STA);WiFi.begin(config.ssid,config.password);uint32_t began=millis();while(enabled.load()&&WiFi.status()!=WL_CONNECTED&&uint32_t(millis()-began)<15000)vTaskDelay(pdMS_TO_TICKS(100));
  String token,response;if(enabled.load()&&WiFi.status()==WL_CONNECTED){String body=String("{\"code\":\"")+config.pairCode+"\"}";int code=request("POST","/assistant/v1/pair",reinterpret_cast<const uint8_t*>(body.c_str()),body.length(),String(),response);if(code==200)token=jsonString(response,"access_token");}
  memset(config.pairCode,0,sizeof(config.pairCode));if(!token.length()){enabled=false;log("REC_PAIR_OR_WIFI_FAILED");}
  while(enabled.load()){int code=request("GET","/performances/v1/capture/next",nullptr,0,token,response);if(code==200){String id=jsonString(response,"takeId"),ticket=jsonString(response,"ticket");if(id.length()==29&&id.startsWith("take-")&&ticket.length()==48)capture(id,ticket);else log("REC_JOB_FORMAT");}else if(code==401){enabled=false;log("REC_AUTH_EXPIRED");}vTaskDelay(pdMS_TO_TICKS(400));}
  token=String();workerLive=false;log("REC_OFF");vTaskDelete(nullptr);
}
inline bool command(const String& input,void(*logger)(const char*)){
  if(!input.startsWith("REC_"))return false;logLine=logger;
  if(input=="REC_OFF"){enabled=false;stopReader=true;log("REC_STOP_REQUESTED");return true;}
  if(input=="REC_STATUS"){log(enabled.load()?readerLive.load()?"REC_RECORDING":"REC_ENABLED":"REC_DISABLED");return true;}
  if(workerLive.load()){log("REC_OFF_BEFORE_CONFIG");return true;}
  if(input.startsWith("REC_WIFI ")){String args=input.substring(9);int split=args.indexOf('|');if(split<1||split>32||args.length()-split-1>64){log("REC_WIFI_FORMAT");return true;}args.substring(0,split).toCharArray(config.ssid,sizeof(config.ssid));args.substring(split+1).toCharArray(config.password,sizeof(config.password));log("REC_WIFI_CONFIGURED");return true;}
  if(input.startsWith("REC_SERVER ")){String url=input.substring(11);while(url.endsWith("/"))url.remove(url.length()-1);if(!privateServer(url)){log("REC_PRIVATE_HTTP_SERVER_REQUIRED");return true;}url.toCharArray(config.server,sizeof(config.server));log("REC_SERVER_CONFIGURED");return true;}
  if(input.startsWith("REC_PAIR ")){String code=input.substring(9);bool valid=code.length()==6;for(size_t i=0;i<code.length();i++)valid=valid&&isDigit(code[i]);if(valid){code.toCharArray(config.pairCode,sizeof(config.pairCode));log("REC_PAIR_CONFIGURED");}else log("REC_PAIR_FORMAT");return true;}
  if(input.startsWith("REC_PINS ")){int a=-1,b=-1,c=-1;char extra=0;int fields=sscanf(input.c_str()+9,"%d %d %d %c",&a,&b,&c,&extra);if(fields==3&&xc::safeCapturePins(a,b,c)){config.bclk=a;config.ws=b;config.din=c;log("REC_PINS_CONFIGURED");}else log("REC_PINS_REJECTED");return true;}
  if(input=="REC_ON"){if(!config.ssid[0]||!config.server[0]||strlen(config.pairCode)!=6||!xc::safeCapturePins(config.bclk,config.ws,config.din)){log("REC_CONFIG_INCOMPLETE");return true;}enabled=true;workerLive=true;if(xTaskCreatePinnedToCore(worker,"xc-record-net",16384,nullptr,1,nullptr,0)!=pdPASS){enabled=false;workerLive=false;log("REC_TASK_FAILED");}else log("REC_CONNECTING");return true;}
  log("REC_COMMAND_REJECTED");return true;
}
}
#else
namespace xc_record {inline bool command(const String& input,void(*logger)(const char*)){if(!input.startsWith("REC_"))return false;logger("REC_NOT_COMPILED");return true;}}
#endif
