`timescale 1ns/1ps
module tb_note_table_review;
 zone_note_map z();audition_sequencer a();integer n,c,oct;reg[31:0]base,refv;
 function automatic[31:0] reference_inc(input integer note);integer oct;reg[31:0]b;
 begin case(note%12)
 0:b=32'h016533c1;1:b=32'h017a7148;2:b=32'h0190f225;3:b=32'h01a8c990;
 4:b=32'h01c20be9;5:b=32'h01dccec4;6:b=32'h01f928ff;7:b=32'h021732d3;
 8:b=32'h023705e9;9:b=32'h0258bd73;10:b=32'h027c763f;default:b=32'h02a24ed2;
 endcase oct=note/12-5;reference_inc=oct>=0?b<<oct:b>>(-oct);end endfunction
 initial begin
 for(n=0;n<128;n++)begin
  c=n<36?36:n>108?108:n;refv=reference_inc(c);
  if(z.inc_for_note(7'(n))!==refv)$fatal(1,"zone note %0d",n);
  refv=reference_inc(n);if(a.inc(7'(n))!==refv)$fatal(1,"audition note %0d",n);
 end
 $display("PASS tb_note_table_review all 128+128 notes bit exact to original arithmetic");$finish;end
endmodule
