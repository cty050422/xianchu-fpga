module tb_practice_controller;
 reg clk=0;always #5 clk=~clk;reg rst_n=0,valid=0,safe=1,demo=0,cycle_mode=0,toggle=0,stop=0,done=0,request=0;
 reg[1:0]req_mode=0;reg[2:0]action=0;reg[15:0]rid=0;reg[3:0]held=0;
 wire[1:0]mode;wire[2:0]transport;wire run,reset_engine;wire[15:0]session,last_request;wire[7:0]result;
 practice_controller #(.RESUME_SAMPLES(8))dut(.clk,.rst_n,.score_valid(valid),.safe,.demo_active(demo),.held,
 .cycle_mode,.toggle_run(toggle),.stop,.phrase_done(done),.request,.request_mode(req_mode),.action,.request_id(rid),
 .mode,.transport,.run,.reset_engine,.session,.last_request,.result);
 task tick;begin @(posedge clk);#1;end endtask
 task cmd(input[1:0]m,input[2:0]a,input[15:0]id,input[7:0]expected);begin
 @(negedge clk);req_mode=m;action=a;rid=id;request=1;#1;if(result!==expected)$fatal(1,"result %h expected %h",result,expected);tick();@(negedge clk);request=0;tick();end endtask
 initial begin tick();rst_n=1;tick();cmd(1,0,1,0);if(mode!=1||run)$fatal(1,"empty guide must idle");
 cmd(1,1,2,8'he8);if(run)$fatal(1,"empty started");valid=1;cmd(1,1,3,0);if(!run||session!=1)$fatal(1,"start");
 cmd(1,1,3,0);if(session!=1)$fatal(1,"duplicate start");cmd(2,1,3,8'he7);
 cmd(2,1,4,0);if(mode!=2||session!=2||!run)$fatal(1,"direct switch");
 cmd(2,2,5,0);if(run||transport!=3)$fatal(1,"pause");cmd(2,3,6,0);if(run||transport!=6)$fatal(1,"count in");repeat(8)tick();if(!run||!dut.interrupted)$fatal(1,"resume/interruption");
 held=1;cmd(1,1,7,0);if(run||transport!=5)$fatal(1,"must release");held=0;tick();if(!run)$fatal(1,"rearm");
 valid=0;tick();if(run||mode!=1)$fatal(1,"invalidated score");valid=1;cmd(1,1,8,0);done=1;tick();done=0;tick();
 if(run||transport!=4)$fatal(1,"finish");cmd(0,4,9,0);if(mode||run)$fatal(1,"stop");
 $display("PASS practice no-score/direct-mode/lease-independent/session/replay/pause/rest-arm/finish");$finish;end
endmodule
