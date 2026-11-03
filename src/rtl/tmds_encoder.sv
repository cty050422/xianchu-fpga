// DVI TMDS 8b/10b channel encoder. No image/audio samples are stored.
module tmds_encoder(input wire clk,rst_n,de,input wire [7:0] data,
 input wire c0,c1,output logic [9:0] code);
 logic [8:0] q;integer ones,balance;logic xn;
 logic signed [5:0] disparity;
 always_comb begin
  ones=0;for(integer i=0;i<8;i=i+1)ones=ones+int'(data[i]);
  xn=(ones>4)||((ones==4)&&!data[0]);q[0]=data[0];
  for(integer i=1;i<8;i=i+1)q[i]=q[i-1]^data[i]^xn;
  q[8]=!xn;balance=0;for(integer i=0;i<8;i=i+1)balance=balance+(q[i]?1:-1);
 end
 always_ff @(posedge clk)begin
  if(!rst_n || !de)begin
   disparity<=0;
   case({c1,c0})0:code<=10'b1101010100;1:code<=10'b0010101011;
    2:code<=10'b0101010100;default:code<=10'b1010101011;endcase
  end else if(disparity==0 || balance==0)begin
   code<={!q[8],q[8],q[8]?q[7:0]:~q[7:0]};
   disparity<=6'($signed(disparity)+(q[8]?balance:-balance));
  end else if((disparity>0 && balance>0)||(disparity<0 && balance<0))begin
   code<={1'b1,q[8],~q[7:0]};disparity<=6'($signed(disparity)+(q[8]?2:0)-balance);
  end else begin
   code<={1'b0,q[8],q[7:0]};disparity<=6'($signed(disparity)+balance-(q[8]?0:2));
  end
 end
endmodule
