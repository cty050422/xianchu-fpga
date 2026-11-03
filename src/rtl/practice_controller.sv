// Only authority for practice mode/transport. No audio arithmetic lives here.
// Actions: SELECT=0 START=1 PAUSE=2 RESUME=3 STOP=4. START is idempotent by
// request_id + body. All transitions wait for released keys before new input.
module practice_controller #(parameter integer RESUME_SAMPLES=48000)(
 input logic sample_ce=1'b1,
 input logic clk,rst_n,score_valid,safe,demo_active,
 input logic[3:0]held,input logic cycle_mode,toggle_run,stop,phrase_done,
 input logic legacy_start=0,input logic[1:0]legacy_mode=0,
 input logic request,input logic[1:0]request_mode,input logic[2:0]action,input logic[15:0]request_id,
 output logic[1:0]mode,output logic[2:0]transport,output wire run,
 output logic interrupted,output logic reset_engine,output logic[15:0]session,last_request,output logic[7:0]result
);
 localparam[2:0]IDLE=0,READY=1,RUNNING=2,PAUSED=3,FINISHED=4,ARMING=5,COUNT_IN=6;
 logic blocked_d;logic[15:0]resume_ticks;wire blocked_now=!safe||demo_active;
 logic seen;logic[1:0]last_mode;logic[2:0]last_action;logic[7:0]last_result;
 wire replay=seen && request_id==last_request;
 assign run=transport==RUNNING && score_valid && safe && !demo_active && mode!=0;
 always_comb begin
  result=0;
  if(replay)result=(last_mode==request_mode && last_action==action)?last_result:8'he7;
  else if(action>4 || request_mode>2)result=8'he2;
  else if(demo_active && action!=4)result=8'he5;
  else if(action==1 || action==3)begin
   if(request_mode==0)result=8'he2;
   else if(!score_valid)result=8'he8;
   else if(!safe || demo_active)result=8'he5;
   else if(action==3 && (transport!=PAUSED || request_mode!=mode))result=8'he4;
  end else if(action==2 && (transport!=RUNNING || request_mode!=mode))result=8'he4;
 end
 always_ff@(posedge clk or negedge rst_n)begin
  if(!rst_n)begin mode<=0;transport<=IDLE;reset_engine<=1;session<=0;last_request<=0;
   blocked_d<=0;resume_ticks<=0;interrupted<=0;seen<=0;last_mode<=0;last_action<=0;last_result<=0;end
  else begin
   reset_engine<=0;blocked_d<=blocked_now;
   if(blocked_now)begin transport<=IDLE;reset_engine<=!blocked_d;if(demo_active)mode<=0;end
   else if(!score_valid && transport!=IDLE)begin transport<=IDLE;reset_engine<=1;end
   else if(transport==COUNT_IN && sample_ce)begin
    if(resume_ticks==0)transport<=held==0?RUNNING:ARMING;else resume_ticks<=resume_ticks-16'd1;
   end
   else if(transport==ARMING && held==0)transport<=RUNNING;
   else if(phrase_done && run)transport<=FINISHED;
   if(legacy_start && safe && !demo_active)begin
    mode<=legacy_mode;reset_engine<=1;
    if(legacy_mode==0)transport<=IDLE;
    else if(score_valid)begin session<=session+16'd1;transport<=held==0?RUNNING:ARMING;end
    else transport<=IDLE;
   end else if(stop)begin mode<=0;transport<=IDLE;reset_engine<=1;end
   else if(cycle_mode && !demo_active)begin mode<=mode==2?2'd0:mode+2'd1;
    transport<=(mode==2 || !score_valid)?IDLE:READY;reset_engine<=1;end
   else if(toggle_run && mode!=0 && safe && !demo_active)begin
    if(transport==RUNNING)begin transport<=PAUSED;if(mode==2)interrupted<=1;end
    else if(transport==PAUSED)begin transport<=mode==2?COUNT_IN:held==0?RUNNING:ARMING;resume_ticks<=RESUME_SAMPLES-1;end
    else if(score_valid)begin interrupted<=0;session<=session+16'd1;reset_engine<=1;transport<=held==0?RUNNING:ARMING;end
   end else if(request && !replay)begin
    seen<=1;last_request<=request_id;last_mode<=request_mode;last_action<=action;last_result<=result;
    if(result==0)case(action)
     0:begin mode<=request_mode;transport<=(request_mode!=0 && score_valid)?READY:IDLE;reset_engine<=1;end
     1:begin mode<=request_mode;interrupted<=0;session<=session+16'd1;transport<=held==0?RUNNING:ARMING;reset_engine<=1;end
     2:begin transport<=PAUSED;if(mode==2)interrupted<=1;end
     3:begin transport<=mode==2?COUNT_IN:held==0?RUNNING:ARMING;resume_ticks<=RESUME_SAMPLES-1;end
     4:begin mode<=0;transport<=IDLE;reset_engine<=1;end
     default:begin end
    endcase
   end
  end
 end
endmodule
