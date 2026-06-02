module uart_tx_mini #(
    parameter CLK_FREQ = 27000000, // Cấu hình chuẩn theo thạch anh trên mạch
    parameter BAUD_RATE = 115200
)(
    input            clk,
    input            rst_n,
    input [7:0]      tx_data,
    input            tx_start,
    output reg       tx_busy,
    output reg       tx_pin
);
    localparam BIT_PERIOD = CLK_FREQ / BAUD_RATE;
    reg [15:0] clk_count;
    reg [3:0]  bit_index;
    reg [7:0]  tx_reg;
    reg [1:0]  state;

    localparam STATE_IDLE  = 2'b00;
    localparam STATE_START = 2'b01;
    localparam STATE_DATA  = 2'b10;
    localparam STATE_STOP  = 2'b11;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= STATE_IDLE;
            tx_pin    <= 1'b1;
            tx_busy   <= 1'b0;
            clk_count <= 0;
            bit_index <= 0;
        end else begin
            case (state)
                STATE_IDLE: begin
                    tx_pin  <= 1'b1;
                    tx_busy <= 1'b0;
                    if (tx_start) begin
                        tx_reg    <= tx_data;
                        tx_busy   <= 1'b1;
                        clk_count <= 0;
                        state     <= STATE_START;
                    end
                end
                STATE_START: begin
                    tx_pin <= 1'b0;
                    if (clk_count == BIT_PERIOD - 1) begin
                        clk_count <= 0;
                        state     <= STATE_DATA;
                    end else clk_count <= clk_count + 1'b1;
                end
                STATE_DATA: begin
                    tx_pin <= tx_reg[bit_index];
                    if (clk_count == BIT_PERIOD - 1) begin
                        clk_count <= 0;
                        if (bit_index == 7) state <= STATE_STOP;
                        else bit_index <= bit_index + 1'b1;
                    end else clk_count <= clk_count + 1'b1;
                end
                STATE_STOP: begin
                    tx_pin <= 1'b1;
                    if (clk_count == BIT_PERIOD - 1) begin
                        clk_count <= 0;
                        state     <= STATE_IDLE;
                    end else clk_count <= clk_count + 1'b1;
                end
            endcase
        end
    end
endmodule