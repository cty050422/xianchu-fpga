module tb_audition_prefetch;
 reg clk=0;always #5 clk=~clk;reg rst_n=0,ce=0,valid=0;reg[7:0]op=0,seq=0;reg[3:0]len=0;reg[63:0]body=0;
 wire[7:0]result,song;wire[6:0]count;wire active,loaded;
 audition_sequencer #(.WATCHDOG_CLOCKS(5000))dut(.clk,.rst_n,.sample_ce(ce),.abort_playback(1'b0),.blocked(1'b0),
 .command_valid(valid),.command_op(op),.command_seq(seq),.command_len(len),.command_body(body),.result,.active,.loaded,.playing_song(song),.playing_count(count));
 function[7:0]crc8(input[7:0]c0,input[7:0]b);reg[7:0]c;begin c=c0^b;repeat(8)c=c[7]?(c<<1)^7:c<<1;crc8=c;end endfunction
 task cmd(input[7:0]o,input[3:0]l,input[63:0]b);begin @(negedge clk);op=o;len=l;body=b;seq++;valid=1;#1;if(result!==0)$fatal(1,"cmd %h=%h",o,result);@(negedge clk);valid=0;end endtask
 task load(input[7:0]id);reg[63:0]p;reg[7:0]c;begin cmd('h1b,2,{48'd0,8'd1,id});p={24'd960,8'd0,8'd0,8'd0,8'd60,8'd0};cmd('h1c,8,p);c=0;for(integer i=0;i<8;i++)c=crc8(c,p[i*8+:8]);cmd('h1d,2,{48'd0,c,id});end endtask
 initial begin repeat(3)@(negedge clk);rst_n=1;load(1);cmd('h1e,3,64'h010001);load(2);ce=1;
 repeat(1100)@(negedge clk);if(!active||song!=2||count!=1)$fatal(1,"prefetch not atomic");
 repeat(1000)@(negedge clk);if(active)$fatal(1,"finite phrase did not end");
 load(3);cmd('h1e,3,64'h030002);ce=0;repeat(5200)@(negedge clk);if(!active)$fatal(1,"explicit finite offline still watchdog");
 cmd('h1e,3,0);if(active)$fatal(1,"local stop");$display("PASS double-bank prefetch, finite offline, explicit stop");$finish;end
endmodule
