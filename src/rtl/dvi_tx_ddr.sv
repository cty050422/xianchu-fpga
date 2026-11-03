// 5x DDR serializer. ODDR has no runtime asynchronous reset: it loads EVERY
// clock edge. All framing/shift state resets synchronously in the fast domain.
// A pixel toggle is observed through two fast FFs, then loads the held 30-bit
// encoded bundle on the THIRD fast edge (24ns after the source pixel edge).
// Source words change once per 40ns. SDC constrains ONLY this bundle load to
// three cycles; toggle synchronizers and all shift/ODDR data remain one-cycle.
module dvi_tx_ddr(input wire clk_pix,clk_serial,rst_pix_n,
 input wire hs,vs,de,input wire [7:0] r,g,b,
 output wire [2:0] data_p,data_n,output wire clock_p,clock_n);
 wire [9:0] er,eg,eb;
 tmds_encoder encode_r(.clk(clk_pix),.rst_n(rst_pix_n),.de,.data(r),.c0(1'b0),.c1(1'b0),.code(er));
 tmds_encoder encode_g(.clk(clk_pix),.rst_n(rst_pix_n),.de,.data(g),.c0(1'b0),.c1(1'b0),.code(eg));
 tmds_encoder encode_b(.clk(clk_pix),.rst_n(rst_pix_n),.de,.data(b),.c0(hs),.c1(vs),.code(eb));
 reg request=0;
 always_ff @(posedge clk_pix)if(!rst_pix_n)request<=0;else request<=~request;
 (* ASYNC_REG="TRUE" *) reg [1:0] request_sync=0,run_sync=0;
 reg seen=0;reg [29:0] shift_words=0;reg [9:0] shift_clock=0;
 always_ff @(posedge clk_serial)begin
  request_sync<={request_sync[0],request};run_sync<={run_sync[0],rst_pix_n};
  if(!run_sync[1])begin seen<=request_sync[1];shift_words<=0;shift_clock<=0;end
  else if(request_sync[1]!=seen)begin
   seen<=request_sync[1];shift_words<={er,eg,eb};shift_clock<=10'b1111100000;
  end else begin
   shift_words<={2'd0,shift_words[29:22],2'd0,shift_words[19:12],2'd0,shift_words[9:2]};
   shift_clock<={2'd0,shift_clock[9:2]};
  end
 end
 wire [3:0] serial;
 for(genvar i=0;i<3;i=i+1)begin:lanes
  ODDR outddr(.CLK(clk_serial),.D0(shift_words[i*10]),.D1(shift_words[i*10+1]),.TX(1'b0),.Q0(serial[i]),.Q1());
  TLVDS_OBUF obuf(.I(serial[i]),.O(data_p[i]),.OB(data_n[i]));
 end
 ODDR clockddr(.CLK(clk_serial),.D0(shift_clock[0]),.D1(shift_clock[1]),.TX(1'b0),.Q0(serial[3]),.Q1());
 TLVDS_OBUF clockbuf(.I(serial[3]),.O(clock_p),.OB(clock_n));
endmodule
