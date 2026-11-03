// Four-line stereo spatial effect, 48 kHz samples / 12.288 MHz processing.
// RAM holds Q16.2 signed samples. 13 explicit 1024x18 synchronous banks avoid
// wasting a block for every separate allpass / reflection / feedback delay.
// Offline candidate topology: AP223/AP379, FDN1493/1789/2111/2381, six early taps.
// Arithmetic is integer; Q15 products truncate symmetrically toward zero.
// This makes sub-LSB feedback decay to exact zero instead of retaining -1 states.
// This is real-time synthesis/processing, not stored PCM playback.
module spatial_reverb_reference #(
    parameter integer ROOM_WET_Q15 = 37976,
    parameter integer HALL_WET_Q15 = 59859
)(
    input logic clk, rst_n, sample_ce,
    input logic signed [15:0] pcm_in,
    input logic [7:0] wet_target_q8,
    input logic [1:0] mode,
    output logic signed [15:0] pcm_left, pcm_right, pcm_mono,
    output logic ready, busy,
    output logic [15:0] overrun_count, clip_count, state_clip_count,
    output logic [7:0] wet_actual
);
    localparam integer BANKS=13, TOTAL=13312;
    localparam integer AP1=0, AP2=223, F0=602, F1=2095, F2=3884, F3=5995;
    localparam integer EARLY=8376, EARLY_LEN=4273;
    logic [5:0] state;
    logic [13:0] clear_addr, rd_addr, wr_addr;
    logic rd_en, wr_en;
    logic signed [17:0] wr_data;
    logic signed [31:0] wr_full;
    logic signed [17:0] bank_q[0:BANKS-1];
    logic [3:0] bank_sel;
    wire signed [17:0] rd_data=bank_q[bank_sel];
    genvar b;
    generate for(b=0;b<BANKS;b=b+1) begin: sample_bank
        (* ram_style="block" *) logic signed [17:0] mem[0:1023];
        always_ff @(posedge clk) begin
            if(wr_en && wr_addr[13:10]==b) mem[wr_addr[9:0]]<=wr_data;
            if(rd_en && rd_addr[13:10]==b) bank_q[b]<=mem[rd_addr[9:0]];
        end
    end endgenerate
    always_ff @(posedge clk) if(rd_en) bank_sel<=rd_addr[13:10];

    logic [10:0] p_ap1,p_ap2;
    logic [11:0] p0,p1,p2,p3;
    logic [12:0] p_early;
    logic signed [31:0] x,ap1_y,ap2_y;
    logic signed [31:0] tap[0:3],lp[0:3],feedback[0:3];
    logic signed [31:0] early_l,early_r,wet_l,wet_r;
    logic signed [31:0] ap1_value,ap1_store,ap2_value,ap2_store;
    logic signed [31:0] lp_next[0:3];
    logic signed [31:0] damped[0:3];
    logic signed [31:0] fdn_write[0:3];
    logic signed [31:0] raw_l,raw_r,mid,side,wide_l,wide_r;
    logic signed [31:0] mix_l,mix_r,mono_value;
    logic signed [17:0] decay[0:3],width_q15,wet_q15,dry_q15;
    logic [7:0] wet_goal,wet_latched;
    logic [1:0] mode_latched;
    integer j;
    function automatic logic signed [31:0] mul(input logic signed[31:0] a,input logic signed[17:0] c);
        // All operands are sums of <=four 18-bit states and a bounded PCM
        // injection: magnitude <2^21. Keep 24 signed bits (two guard bits).
        // Narrowing here avoids oversized DSP cascades without changing values.
        logic signed[41:0] product;
        begin product=$signed(a[23:0])*c;mul=(product<0)?-((-product)>>>15):(product>>>15);end
    endfunction
    function automatic logic signed[31:0] half(input logic signed[31:0] a);
        half=(a<0)?-((-a)>>>1):(a>>>1);
    endfunction
    function automatic logic signed[31:0] pcm_units(input logic signed[31:0] a);
        pcm_units=(a<0)?-((-a)>>>2):(a>>>2);
    endfunction
    function automatic logic signed[17:0] sat18(input logic signed[31:0] a);
        if(a>32'sd131071)sat18=18'sd131071;
        else if(a< -32'sd131072)sat18= -18'sd131072;
        else sat18=a[17:0];
    endfunction
    function automatic logic signed[15:0] sat16(input logic signed[31:0] a);
        if(a>32'sd32767)sat16=16'sd32767;
        else if(a< -32'sd32768)sat16= -16'sd32768;
        else sat16=a[15:0];
    endfunction
    function automatic logic[13:0] early_addr(input logic[12:0] pos,input integer delay_samples);
        integer v;
        begin v=$unsigned(pos)+EARLY_LEN-delay_samples;if(v>=EARLY_LEN)v=v-EARLY_LEN;early_addr=14'(EARLY+v);end
    endfunction
    function automatic logic signed[17:0] interp_decay(input integer room_g,input integer hall_g,input logic[7:0] w);
        integer temp;
        begin temp=room_g;if(w>32)temp=room_g+((hall_g-room_g)*($unsigned(w)-32))/32;interp_decay=18'(temp);end
    endfunction
    always_comb begin
        wet_goal=(mode==0)?8'd0:((wet_target_q8>64)?8'd64:wet_target_q8);
        decay[0]=interp_decay(22905,29846,wet_latched);
        decay[1]=interp_decay(21335,29298,wet_latched);
        decay[2]=interp_decay(19749,28713,wet_latched);
        decay[3]=interp_decay(18511,28232,wet_latched);
        width_q15=(wet_latched<=32)?18'sd26214:18'sd26214+18'(($unsigned(wet_latched)-32)*358);
        if(wet_latched<=32)wet_q15=18'((ROOM_WET_Q15*$unsigned(wet_latched))/32);
        else wet_q15=18'(ROOM_WET_Q15+((HALL_WET_Q15-ROOM_WET_Q15)*($unsigned(wet_latched)-32))/32);
        // Increase effect audibility while reserving headroom continuously.
        dry_q15=18'sd32768-18'($unsigned(wet_latched)*256);
        ap1_value=$signed(rd_data)-mul(x,18'sd20316);
        ap1_store=x+mul($signed(sat18(ap1_value)),18'sd20316);
        ap2_value=$signed(rd_data)-mul(ap1_y,18'sd19005);
        ap2_store=ap1_y+mul($signed(sat18(ap2_value)),18'sd19005);
        for(integer k=0;k<4;k=k+1)begin
            lp_next[k]=$signed(sat18(mul(lp[k],18'sd9175)+mul(tap[k],18'sd23593)));
            damped[k]=mul(lp[k],decay[k]);
        end
        fdn_write[0]=mul(ap2_y,18'sd16384)+feedback[0];
        fdn_write[1]=mul(ap2_y,18'sd14746)+feedback[1];
        fdn_write[2]=mul(ap2_y,-18'sd13107)+feedback[2];
        fdn_write[3]=mul(ap2_y,-18'sd10650)+feedback[3];
        raw_l=(half(tap[0]+tap[1]+tap[2]-tap[3]))+early_l;
        raw_r=(half(tap[0]-tap[1]+tap[2]+tap[3]))+early_r;
        mid=half(wet_l+wet_r);side=half(wet_l-wet_r);
        wide_l=mid+mul(side,width_q15);wide_r=mid-mul(side,width_q15);
        mix_l=pcm_units(mul(x+mul(wide_l,wet_q15),dry_q15));
        mix_r=pcm_units(mul(x+mul(wide_r,wet_q15),dry_q15));
        mono_value=($signed(sat16(mix_l))*32'sd1+$signed(sat16(mix_r))*32'sd1)>>>1;
        rd_en=0;wr_en=0;rd_addr=0;wr_addr=0;wr_data=0;wr_full=0;
        if(!ready) begin wr_en=1;wr_addr=clear_addr;wr_data=0;end
        else case(state)
            1:begin rd_en=1;rd_addr=14'(AP1)+p_ap1;end
            2:begin wr_en=1;wr_addr=14'(AP1)+p_ap1;wr_full=ap1_store;wr_data=sat18(wr_full);end
            3:begin rd_en=1;rd_addr=14'(AP2)+p_ap2;end
            4:begin wr_en=1;wr_addr=14'(AP2)+p_ap2;wr_full=ap2_store;wr_data=sat18(wr_full);end
            5:begin rd_en=1;rd_addr=14'(F0)+p0;end
            6:begin rd_en=1;rd_addr=14'(F1)+p1;end
            7:begin rd_en=1;rd_addr=14'(F2)+p2;end
            8:begin rd_en=1;rd_addr=14'(F3)+p3;end
            12:begin wr_en=1;wr_addr=14'(F0)+p0;wr_full=fdn_write[0];wr_data=sat18(wr_full);end
            13:begin wr_en=1;wr_addr=14'(F1)+p1;wr_full=fdn_write[1];wr_data=sat18(wr_full);end
            14:begin wr_en=1;wr_addr=14'(F2)+p2;wr_full=fdn_write[2];wr_data=sat18(wr_full);end
            15:begin wr_en=1;wr_addr=14'(F3)+p3;wr_full=fdn_write[3];wr_data=sat18(wr_full);end
            16:begin rd_en=1;rd_addr=early_addr(p_early,816);end
            17:begin rd_en=1;rd_addr=early_addr(p_early,1776);end
            18:begin rd_en=1;rd_addr=early_addr(p_early,3408);end
            19:begin rd_en=1;rd_addr=early_addr(p_early,1104);end
            20:begin rd_en=1;rd_addr=early_addr(p_early,2352);end
            21:begin rd_en=1;rd_addr=early_addr(p_early,4272);end
            23:begin wr_en=1;wr_addr=14'(EARLY)+p_early;wr_full=x;wr_data=sat18(wr_full);end
            default:begin end
        endcase
    end
    assign busy=ready && state!=0;
    always_ff @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            ready<=0;clear_addr<=0;state<=0;wet_actual<=0;wet_latched<=0;mode_latched<=0;
            pcm_left<=0;pcm_right<=0;pcm_mono<=0;overrun_count<=0;clip_count<=0;state_clip_count<=0;
            p_ap1<=0;p_ap2<=0;p0<=0;p1<=0;p2<=0;p3<=0;p_early<=0;
            x<=0;ap1_y<=0;ap2_y<=0;early_l<=0;early_r<=0;wet_l<=0;wet_r<=0;
            for(j=0;j<4;j=j+1)begin tap[j]<=0;lp[j]<=0;feedback[j]<=0;end
        end else if(!ready)begin
            pcm_left<=0;pcm_right<=0;pcm_mono<=0;
            if(clear_addr==TOTAL-1)begin ready<=1;clear_addr<=0;end
            else clear_addr<=clear_addr+1'b1;
        end else begin
            if(((wr_en && (wr_full>131071 || wr_full< -131072)) ||
               (state==2 && (ap1_value>131071 || ap1_value< -131072)) ||
               (state==4 && (ap2_value>131071 || ap2_value< -131072))) && state_clip_count!=16'hffff)
                state_clip_count<=state_clip_count+1'b1;
            if(sample_ce && state!=0 && overrun_count!=16'hffff)overrun_count<=overrun_count+1'b1;
            if(state!=0)state<=state+1'b1;
            case(state)
                0:if(sample_ce)begin
                    x<=$signed(pcm_in)*32'sd4;mode_latched<=mode;
                    if(wet_actual<wet_goal)begin wet_actual<=wet_actual+1'b1;wet_latched<=wet_actual+1'b1;end
                    else if(wet_actual>wet_goal)begin wet_actual<=wet_actual-1'b1;wet_latched<=wet_actual-1'b1;end
                    else wet_latched<=wet_actual;
                    early_l<=0;early_r<=0;state<=1;
                end
                2:ap1_y<=$signed(sat18(ap1_value));
                4:ap2_y<=$signed(sat18(ap2_value));
                6:tap[0]<=$signed(rd_data);
                7:tap[1]<=$signed(rd_data);
                8:tap[2]<=$signed(rd_data);
                9:tap[3]<=$signed(rd_data);
                10:for(j=0;j<4;j=j+1)lp[j]<=lp_next[j];
                11:begin
                    feedback[0]<=half(damped[0]+damped[1]+damped[2]+damped[3]);
                    feedback[1]<=half(damped[0]-damped[1]+damped[2]-damped[3]);
                    feedback[2]<=half(damped[0]+damped[1]-damped[2]-damped[3]);
                    feedback[3]<=half(damped[0]-damped[1]-damped[2]+damped[3]);
                end
                17:early_l<=mul($signed(rd_data),18'sd14746);
                18:early_l<=early_l+mul($signed(rd_data),18'sd9830);
                19:early_l<=early_l+mul($signed(rd_data),18'sd6881);
                20:early_r<=mul($signed(rd_data),18'sd14090);
                21:early_r<=early_r+mul($signed(rd_data),18'sd10486);
                22:early_r<=early_r+mul($signed(rd_data),18'sd6554);
                24:begin wet_l<=raw_l;wet_r<=raw_r;end
                25:begin
                    if(mode_latched==0 || wet_latched==0)begin
                        pcm_left<=x>>>2;pcm_right<=x>>>2;pcm_mono<=x>>>2;
                    end else begin
                        pcm_left<=sat16(mix_l);pcm_right<=sat16(mix_r);pcm_mono<=sat16(mono_value);
                        if((mix_l>32767||mix_l< -32768||mix_r>32767||mix_r< -32768)&&clip_count!=16'hffff)clip_count<=clip_count+1'b1;
                    end
                    p_ap1<=(p_ap1==222)?0:p_ap1+1'b1;p_ap2<=(p_ap2==378)?0:p_ap2+1'b1;
                    p0<=(p0==1492)?0:p0+1'b1;p1<=(p1==1788)?0:p1+1'b1;
                    p2<=(p2==2110)?0:p2+1'b1;p3<=(p3==2380)?0:p3+1'b1;
                    p_early<=(p_early==4272)?0:p_early+1'b1;state<=0;
                end
                default:begin end
            endcase
        end
    end
endmodule
