#include <cstdio>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>
#include "mobile_view.h"
int main(int argc,char**argv){
 if(argc!=3)return 2;std::ifstream in(argv[1]);std::ofstream out(argv[2]);if(!in||!out)return 3;
 xc::WireParser parser;xc::TelemetryRelay relay;std::string line;unsigned frames=0;
 std::getline(in,line);
 while(std::getline(in,line)){
  auto comma=line.find(',');if(comma==std::string::npos)return 4;
  unsigned value=std::stoul(line.substr(comma+1),nullptr,16);
  if(parser.feed(uint8_t(value))){
   if(parser.data[3]!=0x82)return 5;auto view=xc::mobileView(parser.data);
   if(!view.valid||view.mode!=2||view.transport!=1||view.held!=5||view.request!=9)return 6;
   if(!relay.offer(parser.data,parser.data[4]+7))return 7;frames++;
  }
 }
 if(frames!=1||parser.bad)return 8;
 out<<'[';bool first=true;uint8_t chunk[20];
 for(unsigned n;(n=relay.next(chunk));){if(!first)out<<',';first=false;out<<'[';for(unsigned i=0;i<n;i++){if(i)out<<',';out<<unsigned(chunk[i]);}out<<']';}
 out<<']';std::puts("PASS actual FPGA UART bytes -> S3 parser/view/relay -> ATT20 chunks");return 0;
}
