`timescale 1ns/1ps
// RTL_SIMULATION_ONLY. Sine coefficients are independently recomputed with $sin;
// no reference waveform or expected value is read from a DUT or its ROM.
module tb_additive_interpolation;
    localparam logic [31:0] LIMIT = 32'h7000_0000;
    logic clk=0, rst_n=0, sample_ce=0;
    always #5 clk=~clk;
    logic [31:0] base_inc=0, mask=0;
    logic [3:0] level_shift=4;
    logic signed [15:0] legacy_pcm, exact_pcm, smooth_pcm;
    logic legacy_busy, exact_busy, smooth_busy;
    logic [5:0] legacy_count, exact_count, smooth_count;
    logic [255:0] exact_diag, smooth_diag;
    additive_bank_32 legacy (
        .clk,.rst_n,.sample_ce,.base_inc,.partial_enable(mask),.level_shift,
        .sample(legacy_pcm),.partials_active(legacy_count),.busy(legacy_busy));
    additive_bank_32 #(.SINE_INTERPOLATION(1)) exact (
        .clk,.rst_n,.sample_ce,.base_inc,.partial_enable(mask),.level_shift,
        .sample(exact_pcm),.partials_active(exact_count),.busy(exact_busy),
        .diag_snapshot(exact_diag));
    additive_bank_32 #(.SINE_INTERPOLATION(1),.MASK_FADE_STEP(4)) smooth (
        .clk,.rst_n,.sample_ce,.base_inc,.partial_enable(mask),.level_shift,
        .sample(smooth_pcm),.partials_active(smooth_count),.busy(smooth_busy),
        .diag_snapshot(smooth_diag));
    logic [31:0] phase_model[0:31];
    logic [31:0] fade_from=0, fade_to=0;
    integer fade_alpha=256, checks=0, tested_samples=0, fd, expected_exact,
            expected_legacy, expected_smooth, expected_count, expected_smooth_count;
    integer maximum_cycles=0, exact_accepts=0, smooth_accepts=0;
    bit tear_mid=0, inject_busy=0;
    integer observed_overrun=0, observed_exact_complete=0;
    longint tick_count=0, exact_start_tick=0, smooth_start_tick=0;
    bit capture_enable=0;
    integer gao_fd=0;
    reg [4095:0] gao_path;
    reg [4095:0] output_path;

    function automatic integer coefficient(input integer idx);
        real x;
        begin
            x=$sin(6.28318530717958647693*(idx%1024)/1024.0)*32767.0;
            coefficient=$rtoi(x+(x>=0?0.5:-0.5));
        end
    endfunction
    function automatic integer sh(input integer k);
        integer p;
        begin p=k;sh=0;while(p>1)begin sh=sh+1;p=p/2;end end
    endfunction
    function automatic integer lookup(input logic [31:0] p, input bit interp);
        integer a,b,f;
        begin
            a=coefficient(p>>22);b=coefficient(((p>>22)+1)%1024);f=(p>>14)&255;
            lookup=interp?(a+(((b-a)*f+128)>>>8)):a;
        end
    endfunction
    function automatic integer sat(input longint signed x);
        begin sat=x>32767?32767:(x< -32768?-32768:x);end
    endfunction
    task automatic check(input bit condition,input string message);
        begin checks++;if(!condition)$fatal(1,"%s at sample %0d",message,tested_samples);end
    endtask
    // GAO samples a registered completion flag on the following rising edge.
    // Thus captured start->done is 97/99 ticks while work itself is 96/98 ticks.
    always @(posedge clk) begin
        tick_count++;
        if(rst_n)begin
            if(exact_diag[1])exact_start_tick=tick_count;
            if(smooth_diag[1])smooth_start_tick=tick_count;
            if(exact_diag[3])check(tick_count-exact_start_tick==97,"GAO hard done latency");
            if(smooth_diag[3])check(tick_count-smooth_start_tick==99,"GAO fading done latency");
        end
        if(capture_enable)begin
            $fdisplay(gao_fd,"%0d,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h",
                tick_count,smooth_diag[0],smooth_diag[1],smooth_diag[2],smooth_diag[3],
                smooth_diag[4],smooth_diag[5],smooth_diag[7],smooth_diag[13:8]+6'd1,
                smooth_diag[37:14],smooth_diag[61:38],smooth_diag[85:62],smooth_diag[91:86],
                smooth_diag[97:92],smooth_diag[129:98],smooth_diag[161:130],smooth_diag[166:162],
                smooth_diag[231:200],smooth_diag[199:196],smooth_diag[182:167],32'hffffffff,
                1'b1,1'b0,smooth_diag[194],smooth_diag[195],1'b1,1'b1,16'h0000,
                smooth_diag[1],smooth_diag[2],1'b1);
        end
    end
    task automatic reset_case;
        begin
            @(negedge clk);rst_n=0;sample_ce=0;
            repeat(3)@(negedge clk);
            for(integer k=0;k<32;k++)phase_model[k]=0;
            fade_from=0;fade_to=0;fade_alpha=256;
            rst_n=1;@(negedge clk);
            check(exact_pcm==0&&smooth_pcm==0&&!exact_busy&&!smooth_busy,"reset silence");
        end
    endtask
    task automatic oracle;
        integer old_sum,new_sum,x,y,legacy_sum,exact_sum;
        longint unsigned inc;
        longint signed faded;
        begin
            if(fade_alpha==256)begin
                fade_from=fade_to;
                if(mask!=fade_to)begin fade_to=mask;fade_alpha=0;end
            end else if(fade_alpha>=252)fade_alpha=256;else fade_alpha+=4;
            old_sum=0;new_sum=0;legacy_sum=0;exact_sum=0;
            expected_count=0;expected_smooth_count=0;
            for(integer k=0;k<32;k++)begin
                inc=(64'(k+1))*base_inc;
                x=lookup(phase_model[k],1)>>>sh(k+1);
                y=lookup(phase_model[k],0)>>>sh(k+1);
                if(inc<LIMIT)begin
                    if(mask[k])begin exact_sum+=x;legacy_sum+=y;expected_count++;end
                    if(fade_from[k])old_sum+=x;
                    if(fade_to[k])new_sum+=x;
                    if((fade_from[k]&&fade_alpha!=256)||(fade_to[k]&&fade_alpha!=0))
                        expected_smooth_count++;
                end
                phase_model[k]=phase_model[k]+inc[31:0];
            end
            faded=longint'(old_sum)+((longint'(new_sum-old_sum)*fade_alpha)>>>8);
            expected_legacy=sat(legacy_sum>>>level_shift);
            expected_exact=sat(exact_sum>>>level_shift);
            expected_smooth=sat(faded>>>level_shift);
        end
    endtask
    task automatic next_sample(input bit save_audio);
        integer cycles,accepted_a,accepted_b,idx_a,idx_b;
        logic signed[23:0] before_a,after_a,term_a,before_b,after_b,term_b;
        begin
            oracle();
            @(negedge clk);sample_ce=1;
            @(negedge clk);sample_ce=0;
            cycles=0;accepted_a=0;accepted_b=0;
            while(exact_busy||smooth_busy||legacy_busy)begin
                if(exact_diag[3])observed_exact_complete++;
                if(tear_mid&&cycles==17)begin
                    base_inc=32'h0645_0000;mask=32'h0000_ffff;level_shift=2;
                end
                if(inject_busy&&cycles==32)sample_ce=1;
                if(inject_busy&&cycles==33)sample_ce=0;
                #1; // observe combinational debug taps after input changes settle
                if(exact_diag[7])observed_overrun++;
                if(exact_diag[2])begin
                    idx_a=exact_diag[13:8];
                    before_a=exact_diag[61:38];after_a=exact_diag[85:62];term_a=exact_diag[37:14];
                    check(idx_a==accepted_a,"exact accepted index sequence");
                    check(after_a==before_a+term_a,"exact accepted arithmetic");
                    accepted_a++;
                end
                if(smooth_diag[2])begin
                    idx_b=smooth_diag[13:8];
                    before_b=smooth_diag[61:38];after_b=smooth_diag[85:62];term_b=smooth_diag[37:14];
                    check(idx_b==accepted_b,"smooth accepted index sequence");
                    check(after_b==before_b+term_b,"smooth accepted arithmetic");
                    accepted_b++;
                end
                @(negedge clk);cycles++;
                if(cycles>128)$fatal(1,"sample budget exceeded");
            end
            check(cycles==98,"fade completion must take 98 clocks");
            check(accepted_a==32&&accepted_b==32,"32 accepted computations");
            check(legacy_pcm===expected_legacy,"legacy sine integer reference");
            check(exact_pcm===expected_exact,"interpolated sine integer reference");
            check(smooth_pcm===expected_smooth,"interpolated mask fade reference");
            check(legacy_count==expected_count&&exact_count==expected_count,"hard count");
            check(smooth_count==expected_smooth_count,"fading count");
            if(cycles>maximum_cycles)maximum_cycles=cycles;
            exact_accepts+=accepted_a;smooth_accepts+=accepted_b;
            if(save_audio)$fdisplay(fd,"%0d,%0d,%0d,%0d,%0d",tested_samples,base_inc,mask,$signed(legacy_pcm),$signed(exact_pcm));
            tested_samples++;
            // There are two explicit edge waits around the start pulse; account
            // for both so successive accepted starts are exactly 256 clocks.
            repeat(256-cycles-2)@(negedge clk);
        end
    endtask
    initial begin
        if(!$value$plusargs("output=%s",output_path))output_path="additive_interpolation.csv";
        fd=$fopen(output_path,"w");if(!fd)$fatal(1,"cannot open output");
        if(!$value$plusargs("gao_output=%s",gao_path))gao_path="additive_gao_SIMULATION_NOT_HARDWARE.csv";
        gao_fd=$fopen(gao_path,"w");if(!gao_fd)$fatal(1,"cannot open GAO fixture");
        $fdisplay(gao_fd,"SIMULATION_NOT_HARDWARE -- actual RTL clocks; not a board capture");
        $fdisplay(gao_fd,"cycle,sample_ce,gao_start,gao_accept,gao_done,busy,stage,gao_overrun,gao_index[5:0],gao_term[23:0],gao_sum_before[23:0],gao_sum_after[23:0],partials_active[5:0],used_count[5:0],base_latch[31:0],inc_running[31:0],amp_shift[4:0],gao_phase[31:0],gao_level_shift[3:0],gao_pcm[15:0],gao_target_mask[31:0],gao_test_mode,gao_single,gao_interpolated,gao_mask_fade,gao_reset_n,gao_pll_locked,gao_overrun_count[15:0],gao_trigger32,gao_target_accept,gao_steady");
        $fdisplay(fd,"sample,base_inc,mask,legacy,interpolated");
        reset_case();base_inc=32'h0248_0000;mask=1;level_shift=0;
        // Coherent N=8192, bin73 single sine: exercises every fractional phase bucket.
        for(integer n=0;n<8192;n++)next_sample(1);
        reset_case();base_inc=32'h004B_17E5;mask=32'hffff_ffff;level_shift=4;
        for(integer n=0;n<2048;n++)next_sample(1);
        // Mask fade reversals, saturation, signed endpoints, zero and guard/wrap.
        for(integer n=0;n<700;n++)begin
            case(n)
                0:mask=32'h1;
                17:mask=32'h8000_0000;
                100:mask=32'hffff_ffff;
                180:begin base_inc=32'h0645_0000;level_shift=0;end
                220:base_inc=32'h7000_0000;
                260:base_inc=32'hffff_ffff;
                300:begin base_inc=0;mask=0;end
                380:begin base_inc=32'h0400_0000;mask=32'hffff_ffff;end
                450:begin base_inc=32'h0258_BF25;level_shift=4;end
                520:mask=32'h5555_5555;
                600:mask=32'haaaa_aaaa;
            endcase
            next_sample(0);
        end
        // Mid-flight reset cancels work, clears phases, and must permit a clean restart.
        @(negedge clk);sample_ce=1;@(negedge clk);sample_ce=0;
        repeat(30)@(negedge clk);reset_case();base_inc=32'hffff_c001;mask=32'hffff_ffff;
        next_sample(0);
        reset_case();base_inc=32'h004b_17e5;mask=32'hffff_ffff;level_shift=4;
        for(integer n=0;n<65;n++)next_sample(0);
        tear_mid=1;next_sample(0);tear_mid=0;next_sample(0);
        inject_busy=1;next_sample(0);inject_busy=0;next_sample(0);
        check(observed_overrun==1,"busy sample is reported and ignored");
        // A completed hard/interpolated sample becomes available at clock96,
        // two clocks before the fade result, and emits exactly one done pulse.
        check(observed_exact_complete==tested_samples,"one hard completion per sample");
        reset_case();base_inc=32'h004b17e5;mask=32'hffffffff;level_shift=4;
        for(integer n=0;n<130;n++)next_sample(0);
        capture_enable=1;
        for(integer n=0;n<4;n++)next_sample(0);
        capture_enable=0;$fclose(gao_fd);
        $fclose(fd);
        $display("PASS tb_additive_interpolation: samples=%0d checks=%0d max_cycles=%0d exact_accepts=%0d smooth_accepts=%0d evidence=RTL_SIMULATION_ONLY",tested_samples,checks,maximum_cycles,exact_accepts,smooth_accepts);
        $finish;
    end
    initial begin #100000000;$fatal(1,"watchdog");end
endmodule
