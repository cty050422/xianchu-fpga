`timescale 1ns/1ps
module tb_brightness_sweep;
 reg clk=0;always #5 clk=~clk;reg rst_n=0,ce=0,ev=0;reg[1:0]region=0,preset=0;reg[6:0]note=60;reg[31:0]inc=32'h016533c1;
 reg[5:0]target=2;wire[63:0]base_words,layer_words,env,expr;wire signed[15:0]base_mixed;wire[7:0]presets;wire[3:0]gates,accepted,stolen;wire[127:0]incs;wire[23:0]counts;wire overrun;
 poly_synth_regions #(.MUSICAL_PRESETS(1),.EXPRESSIVE_ADSR(1),.ADSR_ERROR_FEEDBACK(1),.BALANCED_PRESETS(1))synth(
 .clk,.rst_n,.sample_ce(ce),.event_valid(ev),.event_on(1'b1),.event_region(region),.event_note(note),.event_phase_inc(inc),.event_preset(preset),.event_generation(8'd1),
 .region_pressure(64'hffffffffffffffff),.bend_ratio_q15(16'h8000),.pcm_sample(base_mixed),
 .voice_sample0(base_words[15:0]),.voice_sample1(base_words[31:16]),.voice_sample2(base_words[47:32]),.voice_sample3(base_words[63:48]),
 .voice_expression(expr),.voice_envelopes(env),.voice_phase_incs(incs),.voice_presets(presets),.voice_gates(gates),.event_accepted(accepted),.stolen);
 poly_additive_engine engine(.clk,.rst_n,.sample_ce(ce),.voice_gates(gates),.voice_expression(expr),.voice_envelopes(env),.voice_phase_incs(incs),.voice_presets(presets),
 .accepted_on(accepted),.event_accepted(accepted),.stolen,.force_free(1'b0),.partial_target(target),.lane_pcm(layer_words),.voice_partials(counts),.budget_violation(overrun));
 instrument_extension_core mixer(.clk_audio_12m288(clk),.pll_lock(1'b0),.rst_n_raw(1'b0),.key_n_raw(2'b11),.SENSOR_MISO(1'b0),.ESP_UART_RX(1'b1));
 integer f,layer_sum,base_sum,prior_value,peak=0,clipped=0,ix=0;reg signed[15:0]output_pcm;
 task sample;begin @(negedge clk);ce=1;@(negedge clk);ce=0;repeat(254)@(negedge clk);if(overrun)$fatal(1,"budget overrun");end endtask
 task trigger(input integer z,input integer p);begin
  @(negedge clk);region=2'(z);preset=2'(p);
  case(z)0:begin note=60;inc=32'h016533c1;end 1:begin note=64;inc=32'h01c20be9;end 2:begin note=67;inc=32'h021732d3;end default:begin note=72;inc=32'h02ca6782;end endcase
  ev=1;@(negedge clk);ev=0;repeat(12)@(negedge clk);
 end endtask
 initial begin
 force mixer.voice_levels=base_words;force mixer.eng_lane_pcm=layer_words;force mixer.pcm_voice=base_mixed;force mixer.test_mode=0;
 f=$fopen("brightness_sweep.csv","w");$fwrite(f,"case_id,target,sample,base,layer,output,prior_output,clipped,count0,count1,count2,count3\n");
 for(integer c=0;c<5;c++)begin
  rst_n=0;ev=0;repeat(4)@(negedge clk);rst_n=1;
  if(c<4)trigger(0,c);else for(integer v=0;v<4;v++)trigger(v,v);
  target=2;repeat(256)sample();
  for(integer stage=0;stage<3;stage++)begin target=stage==0?2:stage==1?17:32;
   for(integer n=0;n<1024;n++)begin
    sample();layer_sum=0;base_sum=0;
    for(integer v=0;v<4;v++)begin layer_sum=layer_sum+$signed(layer_words[v*16+:16]);base_sum=base_sum+$signed(base_words[v*16+:16]);end
    prior_value=((base_sum+layer_sum)*3)>>>4;
    prior_value=prior_value>32767?32767:prior_value< -32768?-32768:prior_value;
    output_pcm=mixer.pcm_mix;if(mixer.mix_clipped)clipped++;
    if($signed(output_pcm)<0)begin if(-$signed(output_pcm)>peak)peak=-$signed(output_pcm);end else if(output_pcm>peak)peak=output_pcm;
    $fwrite(f,"%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",c,target,n,base_mixed,layer_sum,output_pcm,prior_value,mixer.mix_clipped,counts[5:0],counts[11:6],counts[17:12],counts[23:18]);
    if(n>128)begin
     if(counts[5:0]!=target)$fatal(1,"voice0 target mismatch");
     if(c==4 && (counts[11:6]!=target||counts[17:12]!=target||counts[23:18]!=target))$fatal(1,"chord partials lost");
    end
   end
  end
 end
 $fclose(f);if(clipped!=0)$fatal(1,"brightness test clipped %0d samples peak=%0d",clipped,peak);
 $display("PASS tb_brightness_sweep 4 actual timbres + four-note chord, 2/17/32, full pressure, peak=%0d clipped=%0d, no overrun",peak,clipped);$finish;
 end
endmodule
