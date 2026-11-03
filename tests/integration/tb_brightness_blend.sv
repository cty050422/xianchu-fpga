`timescale 1ns/1ps
module tb_brightness_blend;
 reg clk=0;always #5 clk=~clk;
 reg[63:0]base_words=0,layer_words=0;reg signed[15:0]base_mixed=0;reg diagnostic=0;
 instrument_extension_core dut(.clk_audio_12m288(clk),.pll_lock(1'b0),.rst_n_raw(1'b0),.key_n_raw(2'b11),.SENSOR_MISO(1'b0),.ESP_UART_RX(1'b1));
 integer seed=32'h735da,base_sum,layer_sum,wide,expected,checked=0;
 initial begin
 force dut.voice_levels=base_words;force dut.eng_lane_pcm=layer_words;force dut.pcm_voice=base_mixed;force dut.test_mode=diagnostic;
 for(integer n=0;n<2000;n++)begin
  base_sum=0;layer_sum=0;
  for(integer v=0;v<4;v++)begin
   seed=seed*1664525+1013904223;base_words[v*16+:16]=16'(seed>>8);
   seed=seed*1664525+1013904223;layer_words[v*16+:16]=16'(seed>>9);
   base_sum=base_sum+$signed(base_words[v*16+:16]);layer_sum=layer_sum+$signed(layer_words[v*16+:16]);
  end
  base_mixed=16'(base_sum>>>2);diagnostic=n>=1000;#2;
  wide=diagnostic?((base_sum+layer_sum)*3)>>>4:((base_mixed*3)>>>3)+((layer_sum*3)>>>2);
  expected=wide>32767?32767:wide< -32768?-32768:wide;
  if($signed(dut.pcm_mix)!==expected)$fatal(1,"brightness blend n=%0d got=%0d expected=%0d",n,dut.pcm_mix,expected);
  if(dut.mix_clipped!==(wide>32767||wide< -32768))$fatal(1,"clipping marker");checked++;
 end
 $display("PASS tb_brightness_blend %0d random signed vectors, donor blend, diagnostic unchanged, saturation no wrap",checked);$finish;
 end
endmodule
