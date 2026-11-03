`timescale 1ns/1ps
module tb_poly_gao_review;
 reg clk=0;always #5 clk=~clk;reg rst_n=0;reg[7:0]divider=0;wire ce=divider==255;reg[3:0]accept=0;
 always@(posedge clk)if(!rst_n)divider<=0;else divider<=divider+1'b1;
 wire[255:0]d0,d1,d;wire overrun;integer count=0,f;
 poly_additive_engine dut(.clk,.rst_n,.sample_ce(ce),.voice_gates(4'hf),.voice_expression(64'hffffffffffffffff),.voice_envelopes(64'hffffffffffffffff),
 .voice_phase_incs({32'h02ca6782,32'h021732d3,32'h01c20be9,32'h016533c1}),.voice_presets(8'he4),
 .accepted_on(accept),.event_accepted(4'd0),.stolen(4'd0),.force_free(1'b0),.partial_target(6'd32),.budget_violation(overrun),.diag_lane0(d0),.diag_lane1(d1));
 assign d=d0[132]?d1:d0;
 always@(posedge clk)if(rst_n&&ce)count<=count+1;
 always@(negedge clk)if(rst_n)begin
  if(overrun)$fatal(1,"overrun");
  if(count>=100&&count<105)$fwrite(f,"%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h\n",
    d[255:248],d[241],d[240:239],d[155:148],d[147:132],d[13:8]+6'd1,d[3],d[3]&&d[2:0]==2,d[247],d[7],d[214:206],d[244],d[245],d[173:156],d[197:190],d[205:198],d[43:20],d[67:44],d[131:100],d[230:215],d[6]);
  if(count==105)begin $fclose(f);$display("PASS tb_poly_gao_review model52 tagged export, no overrun");$finish;end
 end
 initial begin f=$fopen("poly_GAO_SIMULATION_NOT_HARDWARE.csv","w");
 $fwrite(f,"SIMULATION_NOT_HARDWARE\ngao_model,gao_lane,gao_voice,gao_generation,gao_sample,gao_index,busy,gao_accept,gao_done,gao_overrun,gao_alpha,gao_from,gao_to,gao_phase18,gao_weight,gao_gain,gao_term,gao_sum_before,base_latch,gao_pcm,sample_ce\n");
 repeat(4)@(negedge clk);rst_n=1;accept=15;@(negedge clk);accept=0;end
endmodule
