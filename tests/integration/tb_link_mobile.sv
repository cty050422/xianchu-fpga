module tb_link_mobile;
 reg clk=0;always #5 clk=~clk;reg rst_n=0,rx=1;wire tx;wire pr;wire[1:0]pm;wire[2:0]pa;wire[15:0]pid;
 wire[7:0]result;wire[1:0]mode;wire[2:0]transport;wire run,reset_engine;wire[15:0]session,last_request;
 reg signed[15:0]pcm=16000;always@(negedge clk)pcm=-pcm;
 practice_controller manager(.clk,.rst_n,.score_valid(1'b1),.safe(1'b1),.demo_active(1'b0),.held(4'd0),
 .cycle_mode(1'b0),.toggle_run(1'b0),.stop(1'b0),.phrase_done(1'b0),.request(pr),.request_mode(pm),.action(pa),.request_id(pid),
 .mode,.transport,.run,.reset_engine,.session,.last_request,.result);
 esp_score_link #(.CLOCKS_PER_BIT(8),.STATUS_INTERVAL(20000),.ENABLE_MOBILE(1'b1))dut(
 .clk,.rst_n,.uart_rx_i(rx),.uart_tx_o(tx),.audition_sample_ce(1'b1),.mobile_pcm(pcm),.mobile_state(248'h123401),
 .practice_request(pr),.practice_request_mode(pm),.practice_action(pa),.practice_request_id(pid),.practice_result(result),
 .current_step(6'd0),.guide_active(run),.test_mode(1'b0),.panic_mute(1'b0),.calibrated(1'b1),
 .panel_mode(mode),.hit_count(16'd0),.wrong_count(16'd0),.miss_count(16'd0),.note_layout(2'd0),.partial_target(6'd17),.wet_target(8'd32));
 defparam dut.g_mobile.observer.STATE_CLOCKS=30000;
 defparam dut.g_mobile.observer.WAVE_CLOCKS=100000;
 wire[7:0]data;wire dv,fe;
 uart_rx #(.CLOCKS_PER_BIT(8))listener(.clk,.rst_n,.rx(tx),.data,.data_valid(dv),.framing_error(fe));
 integer n=0,total=0,controls=0,waves=0,statuses=0;reg[7:0]crc=0,kind=0;
 function[7:0]c8(input[7:0]c0,input[7:0]b);reg[7:0]c;begin c=c0^b;repeat(8)c=c[7]?(c<<1)^7:c<<1;c8=c;end endfunction
 always@(negedge clk)if(dv)begin
  if(n==0)begin if(data!=8'ha5)$fatal(1,"SOF");crc=0;end
  if(n==1&&data!=8'h5a)$fatal(1,"header interleave");
  if(n==3)kind=data;if(n==4)total=data+7;
  if(n>=2 && n!=total-1)crc=c8(crc,data);
  if(n>=6 && n==total-1)begin
   if(data!=crc)$fatal(1,"CRC");if(kind==8'h82)controls++;else if(kind==8'h83)waves++;else if(kind==8'h80)statuses++;n=0;total=0;
  end else n++;
 end
 task byte_tx(input[7:0]b);begin rx=0;repeat(8)@(negedge clk);for(integer i=0;i<8;i++)begin rx=b[i];repeat(8)@(negedge clk);end rx=1;repeat(8)@(negedge clk);end endtask
 task command(input[7:0]m,input[7:0]a,input[15:0]id);reg[7:0]v[0:10];reg[7:0]c;begin
 v[0]='ha5;v[1]='h5a;v[2]=1;v[3]='h20;v[4]=4;v[5]=id[7:0];v[6]=m;v[7]=a;v[8]=id[7:0];v[9]=id[15:8];c=0;
 for(integer i=2;i<10;i++)c=c8(c,v[i]);v[10]=c;for(integer i=0;i<11;i++)byte_tx(v[i]);repeat(30)@(negedge clk);end endtask
 initial begin repeat(3)@(negedge clk);rst_n=1;
 command(129,0,1);if(mode!=0)$fatal(1,"rejected high bits changed mode");
 command(1,0,1);if(mode!=1||run)$fatal(1,"SELECT");command(1,1,2);if(!run||session!=1)$fatal(1,"START");
 command(1,1,2);if(session!=1)$fatal(1,"duplicate");repeat(220000)@(negedge clk);
 if(statuses<3||controls<2||waves<8)$fatal(1,"missing frames %d %d %d",statuses,controls,waves);
 $display("PASS real UART request guards + session + state/wave/status CRC noninterleave");$finish;end
endmodule
