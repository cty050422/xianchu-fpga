// Symbolic score player. No audio storage, CPU, or sample playback.
// 64 chord/rest steps, 36..96 MIDI, 4 fixed regions, 48k sample-clock schedule.
// Commands 1B begin(id,count),1C step(index,4 notes,duration LE24),
// 1D commit(id,CRC8(all ordered STEP bodies)),1E control(0/1,preset,id),1F probe.
// Strict order + exact last-request replay. STOP and abort always win.
module audition_sequencer #(
 parameter integer WATCHDOG_CLOCKS=36_864_000,
 parameter integer TAIL_MAX_SAMPLES=48000,
 parameter integer TAIL_QUIET_SAMPLES=16
)(
 input logic tail_quiet=1'b1,
 input logic clk,rst_n,sample_ce,abort_playback,blocked,
 input logic command_valid,input logic [7:0] command_op,command_seq,
 input logic [3:0] command_len,input logic [63:0] command_body,
 output logic [7:0] result,
 output wire[7:0]playing_song,output wire[6:0]playing_count,
 output logic active,loaded,output logic [5:0] step,
 output logic event_valid,event_on,output logic [1:0] event_region,event_preset,
 output logic [6:0] event_note,output logic [7:0] event_generation,
 output logic [31:0] event_phase_inc,output logic [63:0] pressure
);
 reg [55:0] bank_a[0:63],bank_b[0:63];
 reg active_bank,txn,txn_bank;reg[7:0]song,txn_song;reg[6:0]count,txn_count,written;
 assign playing_song=song;assign playing_count=count;
 reg next_ready,next_bank,offline,draining;
 reg[$clog2(TAIL_MAX_SAMPLES+1)-1:0]tail_samples;
 reg[$clog2(TAIL_QUIET_SAMPLES+1)-1:0]quiet_samples;
 reg[7:0]next_song;reg[6:0]next_count;
 reg[31:0]txn_samples,published_samples,next_samples;
 reg[7:0]steps_crc;reg[23:0]remaining;reg[7:0]generation;
 reg[31:0]notes;reg[1:0]preset;reg[3:0]dispatch;reg dispatch_on;
 reg[25:0]watchdog;reg[3:0]guard;
 reg replay_seen;reg[7:0]last_seq,last_op,last_result;reg[3:0]last_len;reg[63:0]last_body;
 wire retry=replay_seen && command_seq==last_seq;
 wire same=command_op==last_op && command_len==last_len && command_body==last_body;
 wire[23:0]duration=command_body[63:40];
 wire[55:0]current_word=active_bank?bank_b[step]:bank_a[step];
 function automatic [7:0]crc8(input[7:0]old,input[7:0]b);reg[7:0]c;
 begin c=old^b;for(integer i=0;i<8;i=i+1)c=c[7]?(c<<1)^8'h07:c<<1;crc8=c;end endfunction
 function automatic logic [31:0] inc(input logic [6:0] n);
        // Exact offline expansion of the former /12, %12 and variable octave shift.
        // Coefficients are unchanged; this is a lookup, not recorded sound.
        case(n)
            7'd0: inc=32'h000b299e;
            7'd1: inc=32'h000bd38a;
            7'd2: inc=32'h000c8791;
            7'd3: inc=32'h000d464c;
            7'd4: inc=32'h000e105f;
            7'd5: inc=32'h000ee676;
            7'd6: inc=32'h000fc947;
            7'd7: inc=32'h0010b996;
            7'd8: inc=32'h0011b82f;
            7'd9: inc=32'h0012c5eb;
            7'd10: inc=32'h0013e3b1;
            7'd11: inc=32'h00151276;
            7'd12: inc=32'h0016533c;
            7'd13: inc=32'h0017a714;
            7'd14: inc=32'h00190f22;
            7'd15: inc=32'h001a8c99;
            7'd16: inc=32'h001c20be;
            7'd17: inc=32'h001dccec;
            7'd18: inc=32'h001f928f;
            7'd19: inc=32'h0021732d;
            7'd20: inc=32'h0023705e;
            7'd21: inc=32'h00258bd7;
            7'd22: inc=32'h0027c763;
            7'd23: inc=32'h002a24ed;
            7'd24: inc=32'h002ca678;
            7'd25: inc=32'h002f4e29;
            7'd26: inc=32'h00321e44;
            7'd27: inc=32'h00351932;
            7'd28: inc=32'h0038417d;
            7'd29: inc=32'h003b99d8;
            7'd30: inc=32'h003f251f;
            7'd31: inc=32'h0042e65a;
            7'd32: inc=32'h0046e0bd;
            7'd33: inc=32'h004b17ae;
            7'd34: inc=32'h004f8ec7;
            7'd35: inc=32'h005449da;
            7'd36: inc=32'h00594cf0;
            7'd37: inc=32'h005e9c52;
            7'd38: inc=32'h00643c89;
            7'd39: inc=32'h006a3264;
            7'd40: inc=32'h007082fa;
            7'd41: inc=32'h007733b1;
            7'd42: inc=32'h007e4a3f;
            7'd43: inc=32'h0085ccb4;
            7'd44: inc=32'h008dc17a;
            7'd45: inc=32'h00962f5c;
            7'd46: inc=32'h009f1d8f;
            7'd47: inc=32'h00a893b4;
            7'd48: inc=32'h00b299e0;
            7'd49: inc=32'h00bd38a4;
            7'd50: inc=32'h00c87912;
            7'd51: inc=32'h00d464c8;
            7'd52: inc=32'h00e105f4;
            7'd53: inc=32'h00ee6762;
            7'd54: inc=32'h00fc947f;
            7'd55: inc=32'h010b9969;
            7'd56: inc=32'h011b82f4;
            7'd57: inc=32'h012c5eb9;
            7'd58: inc=32'h013e3b1f;
            7'd59: inc=32'h01512769;
            7'd60: inc=32'h016533c1;
            7'd61: inc=32'h017a7148;
            7'd62: inc=32'h0190f225;
            7'd63: inc=32'h01a8c990;
            7'd64: inc=32'h01c20be9;
            7'd65: inc=32'h01dccec4;
            7'd66: inc=32'h01f928ff;
            7'd67: inc=32'h021732d3;
            7'd68: inc=32'h023705e9;
            7'd69: inc=32'h0258bd73;
            7'd70: inc=32'h027c763f;
            7'd71: inc=32'h02a24ed2;
            7'd72: inc=32'h02ca6782;
            7'd73: inc=32'h02f4e290;
            7'd74: inc=32'h0321e44a;
            7'd75: inc=32'h03519320;
            7'd76: inc=32'h038417d2;
            7'd77: inc=32'h03b99d88;
            7'd78: inc=32'h03f251fe;
            7'd79: inc=32'h042e65a6;
            7'd80: inc=32'h046e0bd2;
            7'd81: inc=32'h04b17ae6;
            7'd82: inc=32'h04f8ec7e;
            7'd83: inc=32'h05449da4;
            7'd84: inc=32'h0594cf04;
            7'd85: inc=32'h05e9c520;
            7'd86: inc=32'h0643c894;
            7'd87: inc=32'h06a32640;
            7'd88: inc=32'h07082fa4;
            7'd89: inc=32'h07733b10;
            7'd90: inc=32'h07e4a3fc;
            7'd91: inc=32'h085ccb4c;
            7'd92: inc=32'h08dc17a4;
            7'd93: inc=32'h0962f5cc;
            7'd94: inc=32'h09f1d8fc;
            7'd95: inc=32'h0a893b48;
            7'd96: inc=32'h0b299e08;
            7'd97: inc=32'h0bd38a40;
            7'd98: inc=32'h0c879128;
            7'd99: inc=32'h0d464c80;
            7'd100: inc=32'h0e105f48;
            7'd101: inc=32'h0ee67620;
            7'd102: inc=32'h0fc947f8;
            7'd103: inc=32'h10b99698;
            7'd104: inc=32'h11b82f48;
            7'd105: inc=32'h12c5eb98;
            7'd106: inc=32'h13e3b1f8;
            7'd107: inc=32'h15127690;
            7'd108: inc=32'h16533c10;
            7'd109: inc=32'h17a71480;
            7'd110: inc=32'h190f2250;
            7'd111: inc=32'h1a8c9900;
            7'd112: inc=32'h1c20be90;
            7'd113: inc=32'h1dccec40;
            7'd114: inc=32'h1f928ff0;
            7'd115: inc=32'h21732d30;
            7'd116: inc=32'h23705e90;
            7'd117: inc=32'h258bd730;
            7'd118: inc=32'h27c763f0;
            7'd119: inc=32'h2a24ed20;
            7'd120: inc=32'h2ca67820;
            7'd121: inc=32'h2f4e2900;
            7'd122: inc=32'h321e44a0;
            7'd123: inc=32'h35193200;
            7'd124: inc=32'h38417d20;
            7'd125: inc=32'h3b99d880;
            7'd126: inc=32'h3f251fe0;
            7'd127: inc=32'h42e65a60;
            default: inc=32'd0;
        endcase
    endfunction
 reg valid_notes;reg[7:0]new_crc;reg[7:0]n;
 always_comb begin
 valid_notes=1;new_crc=steps_crc;n=0;
 for(integer i=1;i<5;i=i+1)begin n=command_body[i*8+:8];if(n!=0 && (n<36 || n>96))valid_notes=0;end
 for(integer i=0;i<8;i=i+1)new_crc=crc8(new_crc,command_body[i*8+:8]);
 result=0;
 if(retry)result=same?last_result:8'he7;
 else case(command_op)
 8'h1b:if(command_len!=2 || command_body[15:8]<1 || command_body[15:8]>64)result=8'he2;
        else if(blocked || txn || next_ready || draining || (active && offline))result=8'he5;
 8'h1c:if(blocked || next_ready || draining || (active && offline))result=8'he5;else if(!txn)result=8'he6;
        else if(command_len!=8 || command_body[7:0]!=written || written>=txn_count || !valid_notes || duration<960 || duration>24'd2_880_000 || txn_samples+{8'd0,duration}>32'd5760000)result=8'he2;
 8'h1d:if(blocked || next_ready || draining || (active && offline))result=8'he5;
        else if(command_len!=2 || !txn || command_body[7:0]!=txn_song || written!=txn_count || command_body[15:8]!=steps_crc)result=8'he3;
 8'h1e:if(command_len!=3 || command_body[7:0]>2 || command_body[15:8]>3)result=8'he2;
        else if(command_body[7:0]!=0)begin
         if(active || blocked)result=8'he5;
         else if(!loaded || command_body[23:16]!=song)result=8'he3;
        end
 8'h1f:if(command_len!=0)result=8'he2;
 default:result=8'he0;
 endcase
 end
 assign pressure=active?{4{16'hc000}}:64'd0;
 always_ff@(posedge clk or negedge rst_n)begin
 if(!rst_n)begin
 active<=0;loaded<=0;active_bank<=0;txn<=0;txn_bank<=1;song<=0;txn_song<=0;count<=0;txn_count<=0;written<=0;steps_crc<=0;
 next_ready<=0;next_bank<=0;offline<=0;draining<=0;tail_samples<=0;quiet_samples<=0;next_song<=0;next_count<=0;txn_samples<=0;published_samples<=0;next_samples<=0;
 step<=0;remaining<=0;generation<=0;notes<=0;preset<=0;dispatch<=0;dispatch_on<=0;watchdog<=0;guard<=0;
 replay_seen<=0;last_seq<=0;last_op<=0;last_len<=0;last_body<=0;last_result<=0;
 event_valid<=0;event_on<=0;event_region<=0;event_preset<=0;event_note<=0;event_generation<=0;event_phase_inc<=0;
 end else begin
 event_valid<=0;
 if(guard!=0)guard<=guard-4'd1;
 if(active)begin
  if(command_valid && result==0)watchdog<=0;else if(watchdog<WATCHDOG_CLOCKS)watchdog<=watchdog+26'd1;
  if(dispatch!=0)begin
   if(notes[(dispatch-1)*8+:8]!=0)begin
    event_valid<=1;event_on<=dispatch_on;event_region<=dispatch[1:0]-2'd1;
    event_note<=notes[(dispatch-1)*8+:7];event_phase_inc<=inc(notes[(dispatch-1)*8+:7]);
    event_preset<=preset;event_generation<=generation;
   end
   dispatch<=dispatch-4'd1;
  end
  if(draining && sample_ce)begin
   if(tail_quiet && quiet_samples<TAIL_QUIET_SAMPLES)quiet_samples<=quiet_samples+1'b1;else if(!tail_quiet)quiet_samples<=0;
   if((tail_quiet && quiet_samples>=TAIL_QUIET_SAMPLES-1)||tail_samples>=TAIL_MAX_SAMPLES-1)begin active<=0;draining<=0;dispatch<=0;end
   else tail_samples<=tail_samples+1'b1;
  end
  if(!draining && sample_ce && guard==0)begin
   if(remaining==0)begin
    notes<=current_word[31:0];remaining<=current_word[55:32]-24'd1;
    generation<=generation+8'd1;dispatch<=4;dispatch_on<=1;
   end else if(remaining==480)begin dispatch<=4;dispatch_on<=0;remaining<=remaining-24'd1;end
   else if(remaining==1)begin
    if({1'b0,step}+7'd1>=count)begin
     if(next_ready)begin active_bank<=next_bank;song<=next_song;count<=next_count;published_samples<=next_samples;
       step<=0;remaining<=0;next_ready<=0;end
     else begin draining<=1;tail_samples<=0;quiet_samples<=0;dispatch<=0;end
    end
    else begin step<=step+6'd1;remaining<=0;end
   end else remaining<=remaining-24'd1;
  end
 end
 if(command_valid && !retry)begin
  replay_seen<=1;last_seq<=command_seq;last_op<=command_op;last_len<=command_len;last_body<=command_body;last_result<=result;
  if(result==0)case(command_op)
  8'h1b:begin txn<=1;txn_bank<=~active_bank;txn_song<=command_body[7:0];txn_count<=command_body[14:8];written<=0;steps_crc<=0;txn_samples<=0;end
  8'h1c:begin
   if(txn_bank)bank_b[written[5:0]]<=command_body[63:8];else bank_a[written[5:0]]<=command_body[63:8];
   written<=written+7'd1;steps_crc<=new_crc;txn_samples<=txn_samples+{8'd0,duration};
  end
  8'h1d:begin
    if(active)begin next_ready<=1;next_bank<=txn_bank;next_song<=txn_song;next_count<=txn_count;next_samples<=txn_samples;end
    else begin active_bank<=txn_bank;song<=txn_song;count<=txn_count;published_samples<=txn_samples;end
    loaded<=1;txn<=0;
   end
  8'h1e:begin
   if(command_body[7:0]==0)begin active<=0;draining<=0;dispatch<=0;txn<=0;next_ready<=0;offline<=0;end
   else begin active<=1;txn<=0;draining<=0;tail_samples<=0;quiet_samples<=0;offline<=command_body[7:0]==2;next_ready<=0;step<=0;remaining<=0;preset<=command_body[9:8];event_preset<=command_body[9:8];watchdog<=0;guard<=8;dispatch<=0;end
  end
  default:begin end
  endcase
 end
 if(abort_playback || (active && !offline && watchdog>=WATCHDOG_CLOCKS-1))begin active<=0;dispatch<=0;event_valid<=0;txn<=0;draining<=0;next_ready<=0;offline<=0;end
 end end
endmodule
