`timescale 1ns/1ps
module tb_effect_family_review;
 reg clk=0;always #5 clk=~clk;reg rst_n=0,req=0,held=0;reg[1:0]op=0;reg[7:0]field=19;reg[15:0]value=0;
 wire ack,valid,ef,efv,commit;wire[7:0]result;wire[15:0]getv;
 config_capability c(.clk,.rst_n,.req_valid(req),.req_op(op),.req_field(field),.req_value(value),.req_epoch(16'd7),.cur_epoch(16'd7),.held,
 .ack,.result,.get_valid(valid),.get_value(getv),.applied_effect_family(ef),.effect_family_valid(efv),.commit_pulse(commit));
 config_session s();
 task command(input[1:0]p,input[15:0]v,input[7:0]expected);begin
 @(negedge clk);op=p;value=v;req=1;@(negedge clk);req=0;
 if(!ack||result!==expected)$fatal(1,"op=%0d value=%0d result=%0d expected=%0d",p,v,result,expected);
 end endtask
 initial begin repeat(3)@(negedge clk);rst_n=1;repeat(2)@(negedge clk);
 if(!s.SUPPORTED_MASK[18]||!c.SUPPORTED_MASK[18])$fatal(1,"family absent from capability mask");
 command(2,0,0);if(getv!==1)$fatal(1,"factory family must be space");
 command(0,0,1);if(ef!==1)$fatal(1,"uncommitted set leaked");
 held=1;command(1,0,20);if(ef!==1)$fatal(1,"held commit changed family");held=0;
 command(1,0,0);if(ef!==0||!efv||!commit)$fatal(1,"family0 consumer not reached");
 command(2,0,0);if(getv!==0)$fatal(1,"family0 readback");
 command(0,2,17);command(0,1,1);command(1,0,0);command(2,0,0);if(getv!==1||ef!==1)$fatal(1,"family1 readback");
 $display("PASS tb_effect_family_review capability, staged isolation, held, both consumers, range and GET");$finish;end
endmodule
