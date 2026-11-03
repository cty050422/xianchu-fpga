module tb_mobile_observer;
 reg clk=0;always #5 clk=~clk;reg rst_n=0,ce=0,take=0;reg signed[15:0]pcm=0;
 wire ready;wire[7:0]kind;wire[5:0]len;wire[303:0]body;integer chunks=0,states=0;
 mobile_observer #(.STATE_CLOCKS(30),.WAVE_CLOCKS(90),.BIN_SAMPLES(2))dut(
 .clk,.rst_n,.sample_ce(ce),.pcm,.state_payload(248'h1234),.ready,.kind,.length(len),.body,.take);
 initial begin repeat(3)@(negedge clk);rst_n=1;
 for(integer i=0;i<1500;i++)begin @(negedge clk);ce=1;pcm=i[0]?-16'sd12000:16'sd16000;take=0;
 if(ready)begin
  if(kind==8'h82)begin if(len!=31||body[15:0]!=16'h1234)$fatal(1,"state");states++;end
  else if(kind==8'h83)begin
   if(len!=38 || body[47:40]!=8 || body[39:32]!=(chunks%8))$fatal(1,"chunk metadata");
   for(integer j=6;j<38;j+=2)if($signed(body[j*8+:8])!=-47 || $signed(body[(j+1)*8+:8])!=62)$fatal(1,"not final PCM min/max");chunks++;
  end else $fatal(1,"kind");take=1;
 end
 end
 if(chunks<8 || states<2)$fatal(1,"missing");$display("PASS final PCM min/max, immutable 8 chunks, state priority");$finish;end
endmodule
