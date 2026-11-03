`timescale 1ns/1ps
module tb_adsr_stage_observer;
    logic clk=0,rst_n=0,sample_ce=1,gate=0,retrigger=0;
    logic [15:0] attack_step=512,decay_step=8,sustain_level=32768,release_step=4;
    wire [15:0] level; wire [2:0] state;
    wire [15:0] attack_count,decay_count,release_count;
    wire [2:0] valid,overflow;wire [7:0] event_count,captured_model;
    wire [1:0] captured_preset;wire done;
    logic [2:0] forced_state;logic use_forced=0;
    wire [2:0] observed_state=use_forced?forced_state:state;
    integer n;
    always #5 clk=~clk;
    adsr_envelope #(.CURVED_DECAY_RELEASE(1),.CONTINUOUS_RETRIGGER(1),.CURVE_ERROR_FEEDBACK(1)) env (
      .clk,.rst_n,.sample_ce,.gate,.retrigger,.attack_step,.decay_step,.sustain_level,.release_step,.level,.state);
    adsr_stage_observer dut(.clk,.rst_n,.sample_ce,.gate,.retrigger,.state(observed_state),
      .preset(2'd0),.model(8'd2),.attack_count,.decay_count,.release_count,
      .valid,.overflow,.event_count,.done,.captured_preset,.captured_model);
    task automatic step(input integer count);
        repeat(count)begin @(posedge clk);#1;end
    endtask
    initial begin
      step(2);@(negedge clk);rst_n=1;gate=1;
      step(3000);
      if(valid!=3'b011 || attack_count!=128 || decay_count!=1124 || overflow)
        $fatal(1,"Wrong complete A/D: %d %d valid %b",attack_count,decay_count,valid);
      @(negedge clk);gate=0;step(2000);
      if(!done || valid!=7 || release_count!=1450 || overflow || captured_model!=2)
        $fatal(1,"Wrong complete R: count %d valid %b done %b",release_count,valid,done);
      step(30);if(release_count!=1450)$fatal(1,"Snapshot not stable");
      // Note-on resets epoch; early release must not claim completed A/D.
      @(negedge clk);gate=1;step(12);
      @(negedge clk);gate=0;step(2000);
      if(!done || valid!=4 || attack_count!=11 || decay_count!=0 || event_count!=2)
        $fatal(1,"Short-note validity wrong: A %d D %d valid %b events %d",attack_count,decay_count,valid,event_count);
      // Retrigger starts a new timing epoch without counting a skipped update.
      @(negedge clk);gate=1;step(3000);
      @(negedge clk);retrigger=1;step(1);
      if(valid || attack_count || decay_count || release_count || done || event_count!=4)
        $fatal(1,"Retrigger epoch not reset");
      @(negedge clk);retrigger=0;sample_ce=0;step(20);
      if(attack_count)$fatal(1,"Counted clocks without sample_ce");
      @(negedge clk);sample_ce=1;step(1);
      if(attack_count!=1)$fatal(1,"First post-retrigger update not counted");
      // Artificial long state hold checks saturation and explicit overflow.
      @(negedge clk);use_forced=1;forced_state=1;retrigger=1;step(1);
      @(negedge clk);retrigger=0;step(65537);
      if(attack_count!=65535 || overflow!=1 || valid)$fatal(1,"Counter did not saturate");
      @(negedge clk);rst_n=0;step(2);
      if(valid || overflow || attack_count || done || event_count)$fatal(1,"Reset incomplete");
      $display("PASS tb_adsr_stage_observer: full/short/retrigger/CE gaps/saturation/reset");
      $finish;
    end
endmodule
