// Single-port synchronous complex RAM, one shared signed 16x16 multiplier.
// Natural samples -> bit-reversed input; radix2 DIT, scale1/2 each stage.
// Two reads and two writes per butterfly are scheduled in separate clocks.
// LOGN=10: 1024 samples at48k (21.33ms) + <5ms compute, <=30fps budget.
module fft_fixed_engine #(parameter LOGN=10)(
 input wire clk,rst_n,sample_ce,input wire signed [15:0] sample,
 input wire capture_start,output reg frame_ready,
 input wire [LOGN-1:0] mag_addr,output reg [15:0] mag_data
);
 localparam N=1<<LOGN;
 typedef enum logic [3:0] {IDLE,FILL,FETCH_A,FETCH_B,LATCH_B,M0,M1,M2,M3,WRITE_A,WRITE_B,MAG_FETCH,MAG_WRITE,DONE} st_t;
 st_t st;
 (* syn_ramstyle="block_ram" *) reg [31:0] mem[0:N-1];reg [31:0] ram_q,ram_w;reg ram_we;
 reg [LOGN-1:0] ram_addr,fill_n,butterfly,mag_n;
 reg [3:0] stage;
 reg signed [15:0] ar,ai,br,bi;
 reg signed [31:0] p0,p1,p2,p3;
 wire [LOGN-1:0] span=LOGN'(1)<<stage;
 wire [LOGN-1:0] j=butterfly&(span-1);
 wire [LOGN-1:0] a=((butterfly>>stage)<<(stage+1))+j;
 wire [LOGN-1:0] b=a+span;
 wire [LOGN-1:0] k=j<<(LOGN-1-stage);
 wire [LOGN-1:0] coeff_addr=st==FILL?fill_n:k;
 wire [47:0] coeff;
 fft_coeff_rom #(.LOGN(LOGN)) rom(.clk,.addr(coeff_addr),.q(coeff));
 wire signed [15:0] hann=coeff[47:32],co=coeff[31:16],si=coeff[15:0];
 reg signed [15:0] mul_a,mul_b;
 wire signed [31:0] product=mul_a*mul_b;
 wire signed [32:0] tr=$signed({p0[31],p0})-$signed({p1[31],p1});
 wire signed [32:0] ti=$signed({p2[31],p2})+$signed({p3[31],p3});
 wire signed [17:0] tq=tr[32:15],uq=ti[32:15];
 wire signed [18:0] sum_r=$signed(ar)+tq,sum_i=$signed(ai)+uq;
 wire signed [18:0] dif_r=$signed(ar)-tq,dif_i=$signed(ai)-uq;
 reg [LOGN-1:0] reverse_n;
 wire signed [15:0] mr=ram_q[31:16],mi=ram_q[15:0];
 wire [15:0] abr=mr[15]?(~mr+16'd1):mr;
 wire [15:0] abi=mi[15]?(~mi+16'd1):mi;
 wire [16:0] magnitude=(abr>abi)?({1'b0,abr}+{2'b0,abi[15:1]}):({1'b0,abi}+{2'b0,abr[15:1]});
 (* syn_ramstyle="block_ram" *) reg [15:0] mags[0:N-1];
 always @(posedge clk) begin
   if(ram_we)mem[ram_addr]<=ram_w;
   else ram_q<=mem[ram_addr];
   if(st==MAG_WRITE)mags[mag_n]<=magnitude[16]?16'hffff:magnitude[15:0];
   else mag_data<=mags[mag_addr];
 end
 always_comb begin
   for(integer i=0;i<LOGN;i=i+1)reverse_n[i]=fill_n[LOGN-1-i];
   mul_a=br;mul_b=co;
   if(st==FILL)begin mul_a=sample;mul_b=hann;end
   else if(st==M1)begin mul_a=bi;mul_b=si;end
   else if(st==M2)begin mul_a=br;mul_b=si;end
   else if(st==M3)begin mul_a=bi;mul_b=co;end
   ram_we=0;ram_addr=a;ram_w=0;
   case(st)
    FILL:begin ram_addr=reverse_n;ram_we=sample_ce;ram_w={product[30:15],16'd0};end
    FETCH_B:ram_addr=b;
    WRITE_A:begin ram_addr=a;ram_we=1;ram_w={sum_r[16:1],sum_i[16:1]};end
    WRITE_B:begin ram_addr=b;ram_we=1;ram_w={dif_r[16:1],dif_i[16:1]};end
    MAG_FETCH,MAG_WRITE:ram_addr=mag_n;
    default:begin end
   endcase
 end
 always_ff @(posedge clk or negedge rst_n) begin
   if(!rst_n)begin st<=IDLE;fill_n<=0;butterfly<=0;stage<=0;mag_n<=0;frame_ready<=0;ar<=0;ai<=0;br<=0;bi<=0;p0<=0;p1<=0;p2<=0;p3<=0;end
   else begin
     frame_ready<=0;
     case(st)
       IDLE:if(capture_start)begin st<=FILL;fill_n<=0;end
       FILL:if(sample_ce)begin
         fill_n<=fill_n+{{(LOGN-1){1'b0}},1'b1};
         if(fill_n==N-1)begin st<=FETCH_A;stage<=0;butterfly<=0;end
       end
       FETCH_A:st<=FETCH_B;
       FETCH_B:begin {ar,ai}<=ram_q;st<=LATCH_B;end
       LATCH_B:begin {br,bi}<=ram_q;st<=M0;end
       M0:begin p0<=product;st<=M1;end
       M1:begin p1<=product;st<=M2;end
       M2:begin p2<=product;st<=M3;end
       M3:begin p3<=product;st<=WRITE_A;end
       WRITE_A:st<=WRITE_B;
       WRITE_B:begin
         if(butterfly==N/2-1)begin
           butterfly<=0;
           if(stage==LOGN-1)begin st<=MAG_FETCH;mag_n<=0;end
           else begin stage<=stage+4'd1;st<=FETCH_A;end
         end else begin butterfly<=butterfly+{{(LOGN-1){1'b0}},1'b1};st<=FETCH_A;end
       end
       MAG_FETCH:st<=MAG_WRITE;
       MAG_WRITE:if(mag_n==N-1)st<=DONE;else begin mag_n<=mag_n+{{(LOGN-1){1'b0}},1'b1};st<=MAG_FETCH;end
       DONE:begin frame_ready<=1;st<=IDLE;end
       default:st<=IDLE;
     endcase
   end
 end
endmodule
