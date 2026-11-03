// Qualified internal latency observation. NOT physical/control-to-analog latency.
// Origin = one accepted note-on after >=8 silent SERIAL words and no held
// voices. End = first subsequent nonzero final PT8211 wire word. Concurrent
// onsets, active baseline and timeout invalidate the observation. No feedback.
module digital_latency_probe(
 input logic clk,rst_n,enable,
 input logic [3:0] note_on,voice_gates,
 input logic bck,ws,din,
 output logic valid,output logic [15:0] latency_us,
 output logic [1:0] slot,output logic [15:0] invalid_count
);
 reg [10:0] phase;reg [31:0] micros,started;
 reg prev_bck,prev_ws,pending;reg [3:0] prev_gates;
 reg [5:0] bits;reg [15:0] shift;reg [3:0] quiet_words;
 wire [15:0] next_word={shift[14:0],din};
 wire one_note=note_on!=0 && (note_on & (note_on-4'd1))==0;
 always_ff @(posedge clk or negedge rst_n)begin
   if(!rst_n)begin
     phase<=0;micros<=0;started<=0;prev_bck<=0;prev_ws<=1;prev_gates<=0;
     pending<=0;bits<=0;shift<=0;quiet_words<=0;valid<=0;latency_us<=0;slot<=0;invalid_count<=0;
   end else begin
     // 50MHz /2 *29 /59 audio PLL ->118/1450 microsecond per clock.
     if(phase>=11'd1332)begin phase<=phase-11'd1332;micros<=micros+32'd1;end
     else phase<=phase+11'd118;
     prev_bck<=bck;prev_gates<=voice_gates;
     if(!enable)begin pending<=0;valid<=0;quiet_words<=0;end
     else begin
       if(note_on!=0)begin
         valid<=0;
         if(!pending && one_note && prev_gates==0 && quiet_words>=8)begin
           pending<=1;started<=micros;
           slot<=note_on[0]?2'd0:note_on[1]?2'd1:note_on[2]?2'd2:2'd3;
         end else begin
           pending<=0;
           if(invalid_count!=16'hffff)invalid_count<=invalid_count+16'd1;
         end
       end
       if(pending && micros-started>=20000)begin
         pending<=0;valid<=0;if(invalid_count!=16'hffff)invalid_count<=invalid_count+16'd1;
       end
       if(bck && !prev_bck)begin
         if(ws!=prev_ws)begin bits<=1;shift<={15'd0,din};prev_ws<=ws;end
         else begin
           shift<=next_word;if(bits<32)bits<=bits+6'd1;
           if(bits==31)begin
             if(next_word==0)begin if(quiet_words<15)quiet_words<=quiet_words+4'd1;end
             else begin
               quiet_words<=0;
               if(pending && note_on==0)begin
                 latency_us<=16'(micros-started);pending<=0;valid<=1;
               end
             end
           end
         end
       end
     end
   end
 end
endmodule
