// Compatibility wrapper for the corrected public FFT read interface.
module fft256_engine #(parameter N=256,parameter STAGES=8)(
 input wire clk,rst_n,sample_ce,input wire signed [15:0] sample,
 input wire capture_start,output wire frame_ready,input wire [7:0] mag_addr,output wire [15:0] mag_data);
 fft_fixed_engine #(.LOGN(8)) engine(.*);
endmodule
