// Full-rate observation + sequential line rasterizer. No audio ready/backpressure.
// wave: 384*172 bits; XY: 187*187 bits; 101017 valid bits per bank.
// Two banks use 18-bit physical addresses. The owner publishes only after DONE.
module display_trace_engine(
 input logic clk_audio,rst_n,sample_ce,
 input logic signed[15:0]pcm_x,pcm_y,
 input logic render_start,input logic[1:0]display_gain,
 output logic capture_ready,render_busy,render_done,render_bank,
 input logic clk_pix,rst_pix_n,read_bank,
 input logic[16:0]read_addr,input logic read_valid,
 output wire pixel
);
 localparam integer WAVE_PIXELS=66048,TOTAL_PIXELS=101017;
 (* syn_ramstyle="block_ram" *) reg signed[15:0]wave_memory[0:511];
 (* syn_ramstyle="block_ram" *) reg[31:0]xy_memory[0:255];
 (* syn_ramstyle="block_ram" *) reg trace_memory[0:262143];
 reg[8:0]wave_index;reg[9:0]trigger_wait;reg recording,wave_ready,trigger_armed;
 reg[7:0]xy_write,xy_origin;reg[8:0]xy_count;
 reg[1:0]gain;reg[16:0]clear_index;
 reg[8:0]index,lx,ly,target_x,target_y,previous_x,previous_y;
 reg signed[10:0]dx,dy,err;reg signed[1:0]step_x,step_y;
 reg xy_kind;
 wire[8:0]wave_write_addr=recording?wave_index:9'd0;
 wire wave_write_enable=sample_ce && !wave_ready &&
  (recording || (trigger_armed && pcm_y>=0) || trigger_wait==767);
 reg signed[15:0]wave_read;reg[31:0]xy_read;
 typedef enum logic[3:0]{IDLE,CLEAR,FETCH,MAP,DRAW,NEXT_POINT,COMPLETE}state_t;
 state_t state;
 wire signed[11:0]twice_err=$signed({err[10],err})<<<1;
 wire advance_x=twice_err>=$signed(dy),advance_y=twice_err<=$signed(dx);
 assign render_busy=state!=IDLE;
 assign capture_ready=wave_ready && xy_count==256 && !render_busy;

 // Preserve all 16 raw bits until the final display coordinate. Shift/add x5,
 // no general-purpose multiply or early truncation to an 8-bit sample stream.
 function automatic integer coordinate(input signed[15:0]v,input[1:0]g);
  reg signed[31:0]wide;integer result;
  begin wide=$signed(v);wide=wide<<<g;wide=(wide<<<2)+wide;
   result=wide>>>11;coordinate=result>80?80:result< -80?-80:result;
  end
 endfunction
 function automatic[16:0]address(input bit kind,input[8:0]x,input[8:0]y);
  reg[16:0]row;
  begin row={8'd0,y};
   address=kind?17'd66048+(row<<7)+(row<<5)+(row<<4)+(row<<3)+(row<<1)+row+{8'd0,x}
               :(row<<8)+(row<<7)+{8'd0,x};
  end
 endfunction
 integer nx,ny,abs_dx,abs_dy;
 always_comb begin
  nx=xy_kind?93+coordinate($signed(xy_read[31:16]),gain):int'(index);
  ny=xy_kind?93-coordinate($signed(xy_read[15:0]),gain):84-coordinate(wave_read,gain);
  abs_dx=(nx>=int'(previous_x))?nx-int'(previous_x):int'(previous_x)-nx;
  abs_dy=(ny>=int'(previous_y))?ny-int'(previous_y):int'(previous_y)-ny;
 end
 // These memories have NO array reset. Publication prevents unwritten reads.
 always_ff@(posedge clk_audio)begin
  // A single explicit write port is essential: two syntactic addresses here
  // caused Gowin to implement the 512x16 wave store with 8192 flip-flops.
  if(wave_write_enable)wave_memory[wave_write_addr]<=pcm_y;
  if(sample_ce && !render_busy && !render_start)xy_memory[xy_write]<={pcm_x,pcm_y};
  if(state==FETCH)begin wave_read<=wave_memory[index];xy_read<=xy_memory[8'(xy_origin+index[7:0])];end
  if(state==CLEAR)trace_memory[{render_bank,clear_index}]<=1'b0;
  else if(state==DRAW)trace_memory[{render_bank,address(xy_kind,lx,ly)}]<=1'b1;
 end
 always_ff@(posedge clk_audio or negedge rst_n)begin
  if(!rst_n)begin wave_index<=0;trigger_wait<=0;recording<=0;wave_ready<=0;trigger_armed<=0;xy_write<=0;xy_count<=0;end
  else begin
   if(render_done)begin wave_ready<=0;trigger_wait<=0;trigger_armed<=0;recording<=0;end
   if(sample_ce)begin
    if(!render_busy && !render_start)begin xy_write<=xy_write+8'd1;if(xy_count<256)xy_count<=xy_count+9'd1;end
    if(!wave_ready)begin
     if(recording)begin if(wave_index==383)begin recording<=0;wave_ready<=1;end else wave_index<=wave_index+9'd1;end
     else begin
      if(pcm_y<= -16)trigger_armed<=1;
      if((trigger_armed && pcm_y>=0)||trigger_wait==767)begin recording<=1;wave_index<=1;trigger_wait<=0;trigger_armed<=0;end
      else trigger_wait<=trigger_wait+10'd1;
     end
    end
   end
  end
 end
 always_ff@(posedge clk_audio or negedge rst_n)begin
  if(!rst_n)begin state<=IDLE;render_done<=0;render_bank<=0;gain<=0;clear_index<=0;xy_origin<=0;
   index<=0;xy_kind<=0;lx<=0;ly<=0;target_x<=0;target_y<=0;previous_x<=0;previous_y<=0;dx<=0;dy<=0;err<=0;step_x<=1;step_y<=1;
  end else begin
   render_done<=0;
   case(state)
    IDLE:if(render_start && capture_ready)begin render_bank<=~render_bank;gain<=display_gain;xy_origin<=xy_write;clear_index<=0;state<=CLEAR;end
    CLEAR:if(clear_index==TOTAL_PIXELS-1)begin index<=0;xy_kind<=0;state<=FETCH;end else clear_index<=clear_index+17'd1;
    FETCH:state<=MAP;
    MAP:begin
     target_x<=9'(nx);target_y<=9'(ny);previous_x<=9'(nx);previous_y<=9'(ny);
     if(index==0)begin lx<=9'(nx);ly<=9'(ny);dx<=0;dy<=0;err<=0;step_x<=1;step_y<=1;end
     else begin lx<=previous_x;ly<=previous_y;dx<=11'(abs_dx);dy<= -11'(abs_dy);err<=11'(abs_dx-abs_dy);step_x<=nx>=int'(previous_x)?2'sd1:-2'sd1;step_y<=ny>=int'(previous_y)?2'sd1:-2'sd1;end
     state<=DRAW;
    end
    DRAW:if(lx==target_x && ly==target_y)state<=NEXT_POINT;
     else begin
      err<=11'($signed(err)+(advance_x?$signed(dy):11'sd0)+(advance_y?$signed(dx):11'sd0));
      if(advance_x)lx<=9'($signed({1'b0,lx})+$signed(step_x));
      if(advance_y)ly<=9'($signed({1'b0,ly})+$signed(step_y));
     end
    NEXT_POINT:if((!xy_kind && index==383)||(xy_kind && index==255))begin
      if(xy_kind)state<=COMPLETE;else begin xy_kind<=1;index<=0;state<=FETCH;end
     end else begin index<=index+9'd1;state<=FETCH;end
    COMPLETE:begin render_done<=1;state<=IDLE;end
    default:state<=IDLE;
   endcase
  end
 end
 reg trace_read,read_valid_d;
 always_ff@(posedge clk_pix)trace_read<=trace_memory[{read_bank,read_addr}];
 always_ff@(posedge clk_pix or negedge rst_pix_n)begin if(!rst_pix_n)read_valid_d<=0;else read_valid_d<=read_valid;end
 assign pixel=read_valid_d && trace_read;
endmodule
