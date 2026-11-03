#include "../authorization.h"
#include <cstdio>
#include <cstdlib>
int checks=0;
void require(bool c,const char *s){++checks;if(!c){std::fprintf(stderr,"FAIL %s\n",s);std::exit(1);}}
int main(){
 xc::PeerSession p;
 require(!p.matches(1),"boot has no peer");
 require(!p.claim(xc::PeerSession::NONE),"invalid peer refused");
 require(p.claim(7),"first phone accepted");
 require(!p.claim(8),"second phone refused");
 require(!p.matches(8),"second phone cannot authenticate or write");
 require(!p.release(8),"second phone disconnect cannot drop first");
 require(p.matches(7),"first peer retained");
 require(p.release(7),"active disconnect clears peer");
 require(p.claim(8),"replacement phone accepted after disconnect");
 require(!p.matches(7),"old authentication callback refused");
 xc::Authorization a;
 require(!a.permitsBLE(1,true,true,true,1,1),"boot must be disarmed");
 require(!a.armBLE(2,false,true,1),"stale FPGA cannot ARM");
 require(!a.armBLE(2,true,false,1),"unauthenticated peer cannot ARM");
 require(a.armBLE(10,true,true,1),"paired explicit ARM");
 require(a.permitsBLE(20,true,true,true,1,1),"current peer command");
 require(!a.permitsBLE(21,true,true,true,1,0),"old queued command rejected");
 require(a.owner==xc::Authorization::BLE,"old queue must not revoke valid owner");
 require(!a.permitsBLE(22,true,false,true,1,1),"disconnect must disarm");
 require(!a.permitsBLE(23,true,true,true,2,2),"reconnect needs explicit ARM");
 require(a.armBLE(30,true,true,2),"new epoch ARM");
 require(!a.check(31,true,true,true,3),"epoch replacement disarms");
 require(a.armUSB(50,true,3),"USB ARM preserved");
 require(!a.check(51,false,false,false,3),"stale FPGA revokes USB TX too");
 require(a.armBLE(100,true,true,3),"lease start");
 require(a.check(60099,true,true,true,3),"lease last millisecond");
 require(!a.check(60100,true,true,true,3),"lease boundary expires");
 require(a.armBLE(0xfffffff0u,true,true,4),"wrap start");
 require(a.check(20,true,true,true,4),"wrap subtraction does not expire early");
 a.activity(30);require(a.check(60029,true,true,true,4),"activity renews bounded lease");
 require(!a.check(60030,true,true,true,4),"renewed lease expires");
 require(a.armBLE(70000,true,true,5),"last ARM");a.disarm();
 require(!a.check(70001,true,true,true,5),"manual DISARM");
 std::printf("PASS authorization %d checks: fresh/authentication/epochs/disconnect/lease/wrap/USB\n",checks);
}
