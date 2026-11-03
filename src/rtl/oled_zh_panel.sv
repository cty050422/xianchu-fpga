// SSD1306 128x64, FPGA single master, write address 0x78 (7-bit 0x3c).
// Commands and pixel data use SEPARATE transactions with 0x00 / 0x40 control
// bytes. Page mode is explicitly selected; both halves of each glyph are sent.
// Frame text is latched before page 0: no mixed-mode frame during a slow I2C
// refresh. SDA is open drain. SCL is push-pull (SSD1306 does not stretch SCL).
// No Icarus workaround or hierarchy-dependent behaviour is required.
module oled_zh_panel #(
    parameter integer CLK_HZ=12_288_000,
    parameter integer I2C_HZ=100_000
)(
    input logic clk,rst_n,
    input logic [1:0] mode,preset,
    input logic [5:0] step,
    input logic [1:0] expression=2'd0,
    input logic [3:0] target_mask,
    input logic [15:0] wrong_count,
    input logic calibrated,
    input logic mapping_ready=1'b1,
    input logic [19:0] pairing_code,
    input logic hold,
    output logic scl,
    inout wire sda
);
    logic [6:0] frame [0:31];
    always_comb begin
        for (integer i = 0; i < 32; i = i + 1) frame[i] = 7'd63;
        // line 0: 模式 <自由|引导|挑战>
        frame[0] = 7'd0; frame[1] = 7'd1;
        case (mode)
            2'd0: begin frame[2] = 7'd2; frame[3] = 7'd3; end
            2'd1: begin frame[2] = 7'd4; frame[3] = 7'd5; end
            2'd2: begin frame[2] = 7'd6; frame[3] = 7'd7; end
            default:begin frame[2]=7'd60;frame[3]=7'd61;end
        endcase
        // line 1: <拨弦|吹管|钟声|贝斯>
        case (preset)
            2'd0: begin frame[8] = 7'd27; frame[9] = 7'd28; end
            2'd1: begin frame[8] = 7'd29; frame[9] = 7'd30; end
            2'd2: begin frame[8] = 7'd31; frame[9] = 7'd32; end
            default: begin frame[8] = 7'd33; frame[9] = 7'd34; end
        endcase
        frame[5]=7'd25;frame[6]=7'(35+((int'(step)+1)/10));frame[7]=7'(35+((int'(step)+1)%10));
        // Confirmed assembled orientation: X+ down/X- up, Y+ right/Y- left.
        // Current score accepts either sign; never invent a one-way target.
        if(calibrated && mapping_ready && target_mask!=0 &&
           (mode==1 || mode==2) && (expression==1 || expression==2)) begin
            frame[8]=7'd46;frame[9]=7'd36; // J1
            frame[10]=(expression==1)?7'd47:7'd48; // X/Y
            frame[11]=7'd51;frame[12]=(expression==1)?7'd55:7'd57; // + down/right
            frame[13]=7'd59;frame[14]=(expression==1)?7'd56:7'd58; // - up/left
            frame[15]=7'd63;
        end
        // Keep ALL targets visible even after an error.
        frame[16]=7'd12;frame[17]=7'd13;frame[18]=7'd24;
        for(integer z=0;z<4;z=z+1) frame[19+z]=target_mask[z]?(7'd36+z):7'd63;
        if(mode==3)for(integer k=16;k<24;k=k+1)frame[k]=7'd63;
        // line 3: 配对 <4 digits> | 校准就绪 | 等待
        if (pairing_code != 20'd0) begin
            frame[24] = 7'd16; frame[25] = 7'd17;
            for (integer d=0; d<6; d=d+1)
                frame[26+d] = 7'(35 + ((pairing_code / (10 ** (5-d))) % 10));
        end else if(!mapping_ready && mode!=3)begin
            frame[24]=52;frame[25]=53;frame[26]=23;frame[27]=54; // 曲谱待传
        end else if(mode==3)begin end else if(wrong_count!=0) begin
            frame[24]=7'd14;frame[25]=7'd15;frame[26]=7'd35+(wrong_count/10)%10;frame[27]=7'd35+wrong_count%10;
            if(wrong_count>99)begin frame[26]=44;frame[27]=44;frame[28]=51;end
        end else if (!calibrated) begin
            frame[24] = 7'd22; frame[25] = 7'd23; // 等待
        end else begin
            frame[24] = 7'd10; frame[25] = 7'd11; // 校准
            frame[26] = 7'd8;  frame[27] = 7'd9;  // 就绪
        end
    end


    localparam integer DIV = (CLK_HZ/(I2C_HZ*2)<1) ? 1 : CLK_HZ/(I2C_HZ*2);
    localparam integer INIT_COUNT=27;
    logic [6:0] snapshot[0:31];
    logic [2:0] page;
    logic [7:0] index;
    logic [1:0] transaction; // 0 init, 1 page commands, 2 page data
    logic [7:0] tx_byte;
    logic [7:0] shift;
    logic [2:0] bit_index;
    logic sda_low;
    integer divider;
    logic nack;
    logic [15:0] ack_errors,restarts;
    logic [31:0] frames_sent;
    logic [6:0] glyph_id;
    wire [255:0] glyph_word;
    integer column;
    integer slot;
    oled_glyph_rom glyphs(.idx(glyph_id),.word(glyph_word));
    function automatic [7:0] init_byte(input integer n);
        case(n)
          0:init_byte=8'h78; 1:init_byte=8'h00;
          2:init_byte=8'hAE; 3:init_byte=8'hD5; 4:init_byte=8'h80;
          5:init_byte=8'hA8; 6:init_byte=8'h3F; 7:init_byte=8'hD3;
          8:init_byte=8'h00; 9:init_byte=8'h40;
          10:init_byte=8'h8D; 11:init_byte=8'h14; // charge pump
          12:init_byte=8'h20; 13:init_byte=8'h02; // page addressing
          14:init_byte=8'hA1; 15:init_byte=8'hC8;
          16:init_byte=8'hDA; 17:init_byte=8'h12;
          18:init_byte=8'h81; 19:init_byte=8'h7F;
          20:init_byte=8'hD9; 21:init_byte=8'hF1;
          22:init_byte=8'hDB; 23:init_byte=8'h40;
          24:init_byte=8'hA4; 25:init_byte=8'hA6;
          default:init_byte=8'hAF;
        endcase
    endfunction
    // Address selection and ROM column conversion are separate combinational
    // stages; the byte is registered in LOAD, after index has settled.
    always_comb begin
        column=0; slot=0; glyph_id=7'd63;
        if(transaction==2 && index>=2) begin
            column=(index-2)%16;
            slot=(page>>1)*8+(index-2)/16;
            glyph_id=snapshot[slot];
        end
    end
    always_comb begin
        tx_byte=8'h00;
        if(transaction==0) tx_byte=init_byte(index);
        else if(index==0) tx_byte=8'h78;
        else if(index==1) tx_byte=(transaction==2)?8'h40:8'h00;
        else if(transaction==1) begin
            case(index)
                2:tx_byte=8'hB0|{5'd0,page};
                3:tx_byte=8'h00;
                default:tx_byte=8'h10;
            endcase
        end else begin
            for(integer row=0;row<8;row=row+1)
                tx_byte[row]=glyph_word[(row+(page[0]?8:0))*16+15-column];
        end
    end
    wire last_byte=(transaction==0)?(index==INIT_COUNT-1):
                   (transaction==1)?(index==4):(index==129);
    typedef enum logic [3:0] {SNAP,START_A,START_B,LOAD,BIT_LOW,BIT_HIGH,
        ACK_LOW,ACK_HIGH,ACK_FALL,NEXT_BYTE,STOP_A,STOP_B,STOP_C} state_t;
    state_t state;
    assign sda=sda_low?1'b0:1'bz;
    always_ff @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=SNAP; divider<=0; scl<=1; sda_low<=0;
            page<=0;index<=0;transaction<=0;shift<=0;bit_index<=7;
            ack_errors<=0;restarts<=0;frames_sent<=0;nack<=0;
            for(integer i=0;i<32;i=i+1) snapshot[i]<=63;
        end else if(!hold) begin
            if(divider!=DIV-1) divider<=divider+1;
            else begin
                divider<=0;
                case(state)
                    SNAP: begin
                        for(integer i=0;i<32;i=i+1) snapshot[i]<=frame[i];
                        state<=START_A;
                    end
                    START_A: begin scl<=1;sda_low<=0;state<=START_B;end
                    START_B: begin sda_low<=1;state<=LOAD;end
                    LOAD: begin
                        scl<=0;shift<=tx_byte;bit_index<=7;state<=BIT_LOW;
                    end
                    BIT_LOW: begin scl<=0;sda_low<=!shift[bit_index];state<=BIT_HIGH;end
                    BIT_HIGH: begin
                        scl<=1;
                        if(bit_index==0) state<=ACK_LOW;
                        else begin bit_index<=bit_index-3'd1;state<=BIT_LOW;end
                    end
                    ACK_LOW: begin scl<=0;sda_low<=0;state<=ACK_HIGH;end
                    ACK_HIGH: begin scl<=1;state<=ACK_FALL;end
                    ACK_FALL: begin
                        scl<=0;
                        if(sda!==1'b0) begin
                            nack<=1;ack_errors<=ack_errors==16'hffff ?16'hffff:ack_errors+16'd1;state<=STOP_A;
                        end else state<=NEXT_BYTE;
                    end
                    NEXT_BYTE: begin
                        if(last_byte) state<=STOP_A;
                        else begin index<=index+8'd1;state<=LOAD;end
                    end
                    STOP_A: begin scl<=0;sda_low<=1;state<=STOP_B;end
                    STOP_B: begin scl<=1;state<=STOP_C;end
                    STOP_C: begin
                        sda_low<=0;index<=0;
                        if(nack) begin
                            nack<=0;restarts<=restarts==16'hffff ?16'hffff:restarts+16'd1;transaction<=0;page<=0;state<=SNAP;
                        end else if(transaction==0) begin transaction<=1;state<=SNAP;end
                        else if(transaction==1) begin transaction<=2;state<=START_A;end
                        else if(page==7) begin
                            page<=0;transaction<=1;frames_sent<=frames_sent+1;state<=SNAP;
                        end else begin page<=page+3'd1;transaction<=1;state<=START_A;end
                    end
                    default:state<=SNAP;
                endcase
            end
        end
    end
    wire unused_step=^step;
endmodule
