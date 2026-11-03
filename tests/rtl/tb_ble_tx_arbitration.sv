`timescale 1ns/1ps
module tb_ble_tx_arbitration;
reg clk=0,rst_n=0;always #5 clk=~clk;wire tx;
esp_score_link #(.CLOCKS_PER_BIT(8),.STATUS_INTERVAL(100000000),.ENABLE_MOBILE(1'b1))dut(
 .clk,.rst_n,.uart_rx_i(1'b1),.uart_tx_o(tx),.audition_sample_ce(1'b1),
 .current_step(6'd0),.guide_active(1'b0),.test_mode(1'b0),.panic_mute(1'b0),.calibrated(1'b1),
 .hit_count(16'd0),.wrong_count(16'd0),.miss_count(16'd0),.note_layout(2'd0),.partial_target(6'd32),.wet_target(8'd0));
wire[7:0]data;wire dv,fe;
uart_rx #(.CLOCKS_PER_BIT(8))rx(.clk,.rst_n,.rx(tx),.data,.data_valid(dv),.framing_error(fe));
integer n=0,total=0,controls=0;reg[7:0]crc=0,kind=0;
integer capture_fd,byte_count=0;reg[303:0]state_body=0;
function[7:0]c8(input[7:0]c0,input[7:0]b);reg[7:0]c;begin c=c0^b;repeat(8)c=c[7]?(c<<1)^7:c<<1;c8=c;end endfunction
always@(negedge clk)if(dv)begin
 $fdisplay(capture_fd,"%0d,%02x",byte_count,data);byte_count++;
 if(n==0)begin if(data!=8'ha5)$fatal(1,"SOF");crc=0;end
 if(n==1&&data!=8'h5a)$fatal(1,"interleave");
 if(n==3)kind=data;if(n==4)total=data+7;
 if(n>=2&&n!=total-1)crc=c8(crc,data);
 if(n>=6&&n==total-1)begin if(crc!=data)$fatal(1,"CRC");if(kind==8'h82)controls++;n=0;total=0;end else n++;
end
reg mt,vt;
initial begin
 capture_fd=$fopen("ble_state_uart.csv","w");$fdisplay(capture_fd,"index,byte_hex");
 state_body[7:0]=1;state_body[15:8]=2;state_body[23:16]=1;state_body[31:24]=8;
 state_body[39:32]=2;state_body[55:48]=9;state_body[71:64]=1;
 state_body[87:80]=5;state_body[95:88]=5;state_body[111:104]=2;state_body[119:112]=5;
 state_body[135:128]=128;state_body[191:184]=32;state_body[207:200]=19;state_body[247:240]=2;
 repeat(5)@(negedge clk);rst_n=1;repeat(3)@(negedge clk);
 force dut.mobile_ready=1;force dut.voice_ready=1;
 force dut.mobile_kind=8'h82;force dut.mobile_length=31;force dut.mobile_body=state_body;
 force dut.voice_length=45;force dut.voice_body=360'h2;
 #1;mt=dut.mobile_take;vt=dut.voice_take;
 @(posedge clk);#1;
 $display("SIMULTANEOUS_READY selected_kind=%0d mobile_take=%0d voice_take=%0d",dut.tx_kind,mt,vt);
 if(dut.tx_kind!=2 || !mt || vt)$fatal(1,"state frame must win and only selected producer may be popped");
 @(negedge clk);force dut.mobile_ready=0;force dut.voice_ready=0;
 repeat(4500)@(negedge clk);
 if(controls!=1)$fatal(1,"state frame missing from actual UART controls=%0d",controls);
 $fclose(capture_fd);$display("PASS tb_ble_tx_arbitration: same-ready arbitration and actual UART CRC");$finish;
end
endmodule
