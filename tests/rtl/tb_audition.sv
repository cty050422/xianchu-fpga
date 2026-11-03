`timescale 1ns/1ps
module tb_audition;
 reg clk=0;always #5 clk=~clk;reg rst=0,ce=0,valid=0,abort=0,blocked=0;
 reg[7:0]op=0,seq=0;reg[3:0]len=0;reg[63:0]body=0;
 wire[7:0]result;wire active,loaded,ev,on;wire[5:0]step;
 wire[1:0]region,preset;wire[6:0]note;wire[7:0]generation;
 wire[31:0]inc;wire[63:0]pressure;integer ons=0,offs=0;
 audition_sequencer #(.WATCHDOG_CLOCKS(20_000)) dut(.clk,.rst_n(rst),.sample_ce(ce),.abort_playback(abort),.blocked,
 .command_valid(valid),.command_op(op),.command_seq(seq),.command_len(len),.command_body(body),
 .result,.active,.loaded,.step,.event_valid(ev),.event_on(on),.event_region(region),
 .event_note(note),.event_preset(preset),.event_generation(generation),.event_phase_inc(inc),.pressure);
 always@(negedge clk)if(ev)begin
 if(on)begin ons=ons+1;if(note!=60||inc!=32'h016533c1||preset!=2)$fatal(1,"musical identity");end
 else offs=offs+1;
 end
 task cmd(input[7:0]o,input[3:0]n,input[63:0]p,input[7:0]want);
 begin @(negedge clk);op=o;len=n;body=p;seq=seq+1;valid=1;#1;
 if(result!==want)$fatal(1,"opcode %h result %h expected %h",o,result,want);
 @(negedge clk);valid=0;end endtask
 reg[7:0]crc;
 function[7:0]crc8(input[7:0]c0,input[7:0]b);reg[7:0]c;begin c=c0^b;repeat(8)c=c[7]?(c<<1)^7:c<<1;crc8=c;end endfunction
 reg[63:0]p;
 initial begin
 #30;rst=1;cmd(8'h1f,0,0,0);cmd(8'h1e,3,64'h010201,8'he3);
 cmd(8'h1b,2,64'h0101,0); // song1 count1
 cmd(8'h1d,2,64'h0001,8'he3); // incomplete cannot publish
 p={24'd1000,8'd0,8'd0,8'd0,8'd60,8'd0};cmd(8'h1c,8,p,0);
 crc=0;for(integer i=0;i<8;i=i+1)crc=crc8(crc,p[i*8+:8]);
 cmd(8'h1d,2,{48'd0,crc^8'h01,8'd1},8'he3);
 cmd(8'h1d,2,{48'd0,crc,8'd1},0);if(!loaded)$fatal(1,"not published");
 blocked=1;cmd(8'h1e,3,64'h010201,8'he5);blocked=0;
 cmd(8'h1e,3,64'h010201,0);repeat(16)@(negedge clk);
 // Exact retry must not restart active playback or clear it.
 valid=1;#1;if(result!=0)$fatal(1,"same request retry");@(negedge clk);valid=0;
 for(integer t=0;t<1050;t=t+1)begin @(negedge clk);ce=1;@(negedge clk);ce=0;repeat(14)@(negedge clk);end
 if(active||ons!=1||offs!=1)$fatal(1,"sample schedule / bounded gate: active %d on/off %d/%d",active,ons,offs);
 cmd(8'h1e,3,64'h010201,0);repeat(10)@(negedge clk);abort=1;@(negedge clk);abort=0;
 if(active)$fatal(1,"panic priority");
 cmd(8'h1e,3,64'h010201,0);
 repeat(19000)@(negedge clk);if(!active)$fatal(1,"early watchdog");
 cmd(8'h1f,0,0,0);repeat(19000)@(negedge clk);if(!active)$fatal(1,"heartbeat failed");
 repeat(1100)@(negedge clk);if(active || ev)$fatal(1,"lost heartbeat failed to stop");
 $display("PASS AUDITION: atomic commit, CRC, busy, replay, exact sample scheduling, note identity, panic");$finish;
 end
endmodule
