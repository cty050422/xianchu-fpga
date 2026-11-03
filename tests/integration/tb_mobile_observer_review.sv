`timescale 1ns/1ps
module tb_mobile_observer_review;
 reg clk=0;always #5 clk=~clk;reg rst_n=0,ce=0,take=0;reg signed[15:0]pcm=0;
 wire ready;wire[7:0]kind;wire[5:0]length;wire[303:0]body;
 mobile_observer #(.STATE_CLOCKS(97),.WAVE_CLOCKS(199),.BIN_SAMPLES(8))dut(.clk,.rst_n,.sample_ce(ce),.pcm,.state_payload(248'habcdef),.ready,.kind,.length,.body,.take);
 integer ref_lo[0:127],ref_hi[0:127];integer n=0,col=0,p,windows=0,chunks=0,cycle=0,seed=32'h12575,quiet=0;reg cap_d=0;reg[303:0]held;reg holding=0;
 always@(negedge clk)begin
  cycle=cycle+1;ce=cycle%4==0;seed=(seed*1664525+1013904223);pcm=16'(seed>>8);
  take=ready && cycle%9==0 && cycle>5000;
 end
 always@(posedge clk)if(rst_n)begin
  if(dut.capturing&&!cap_d)begin n=0;col=0;for(integer k=0;k<128;k++)begin ref_lo[k]=127;ref_hi[k]=-128;end end
  cap_d=dut.capturing;
  if(dut.capturing&&ce)begin p=$signed(pcm)>>>8;if(p<ref_lo[col])ref_lo[col]=p;if(p>ref_hi[col])ref_hi[col]=p;n=n+1;if(n%8==0)col=col+1;end
  if(holding && body!==held)$fatal(1,"pending frame changed under backpressure");
  holding=ready&&!take;held=body;
  if(ready&&take)begin
   if(kind==8'h82)begin if(length!=31||body[247:0]!==248'habcdef)$fatal(1,"state mismatch");end
   else if(kind==8'h83)begin
    if(length!=38||body[15:0]!==16'h0101||body[47:40]!=8||body[39:32]!=(chunks%8))$fatal(1,"wave header/chunk mismatch");
    for(integer k=0;k<16;k++)begin
     if($signed(body[48+k*16+:8])!==8'(ref_lo[(chunks%8)*16+k]) || $signed(body[56+k*16+:8])!==8'(ref_hi[(chunks%8)*16+k]))$fatal(1,"min/max mismatch chunk=%0d col=%0d",chunks,k);
    end
    chunks=chunks+1;
    if(chunks==16)begin $display("PASS tb_mobile_observer_review 2 coherent 1024-sample windows, 16 chunks, state priority, long backpressure immutable");$finish;end
   end else $fatal(1,"unknown kind");
  end
  if(cycle>40000)$fatal(1,"timeout");
 end
 initial begin repeat(4)@(negedge clk);rst_n=1;end
endmodule
