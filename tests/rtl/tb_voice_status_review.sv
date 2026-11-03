`timescale 1ns/1ps
module tb_voice_status_review;
reg clk=0;always #5 clk=~clk;reg rst_n=0,ce=0,take=0;
wire ready;wire[7:0]kind;wire[5:0]length;wire[359:0]body;
voice_status_stream #(.STATUS_CLOCKS(4))dut(.clk,.rst_n,.sample_ce(ce),
 .lane_pcm(64'h8000_7fff_0002_0001),.voice_partials(24'h820820),.voice_gains(32'h01020304),
 .voice_generation(32'h01020304),.voice_gates(4'hf),.voice_note_active(4'hf),
 .voice_presets(8'he4),.voice_phase_incs(128'd0),.grant_count(16'h1234),
 .effect_family(1'b1),.budget_violation(1'b1),.ready,.kind,.length,.body,.take);
reg[359:0]held;
initial begin repeat(3)@(negedge clk);rst_n=1;repeat(10)@(negedge clk);
 if(ready)$fatal(1,"snapshot must wait for sample boundary");
 ce=1;@(negedge clk);ce=0;@(negedge clk);
 if(!ready||length!=45||body[7:0]!=2)$fatal(1,"missing schema2 45-byte frame");
 if(body[15:8]!=3 || body[39:24]!=16'h1234)$fatal(1,"flags or grants mismatch");
 if(body[56+:16]!=16'h0001 || body[40+3*80+16+:16]!=16'h8000)$fatal(1,"PCM endian");
 held=body;repeat(10)@(negedge clk);if(body!==held)$fatal(1,"torn in-flight frame");
 take=1;@(negedge clk);take=0;
 $display("PASS voice schema2, sample-boundary snapshot, flags, endian, immutable frame");$finish;
end
endmodule
