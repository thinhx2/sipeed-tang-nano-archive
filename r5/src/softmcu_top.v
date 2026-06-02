module softmcu_top (
    input        sys_clk,     // Khớp với chân clock hệ thống (27MHz)
    output [2:0] O_led,       // 3 LED RGB sáng luân phiên (Test mạch)
    output       O_uart_tx,   

    // ====== CHÂN VẬT LÝ KẾT NỐI CHIP PSRAM RỜI ======
    output       O_psram_ck,  // Xung Clock cấp cho PSRAM
    output       O_psram_ce,  // Chip Enable (Chân chọn chip - Active Low)
    inout        IO_psram_d0, // MOSI (Dữ liệu master xuất ra)
    inout        IO_psram_d1, // MISO (Dữ liệu từ PSRAM trả về)
    inout        IO_psram_d2, // Giữ mức 1 (WP_n ở chế độ SPI 1-bit)
    inout        IO_psram_d3  // Giữ mức 1 (HOLD_n ở chế độ SPI 1-bit)
);

    // ==========================================
    // 1. MẠCH RESET VÀ ĐẾM LED RGB LUÂN PHIÊN (GIỮ NGUYÊN)
    // ==========================================
    reg [3:0] por_count = 4'b0000;
    wire sys_rst_n = por_count[3];
    always @(posedge sys_clk) begin
        if (!sys_rst_n) por_count <= por_count + 1'b1;
    end

    reg [23:0] clk_div;
    reg [1:0]  led_index;
    always @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            clk_div   <= 0;
            led_index <= 0;
        end else begin
            if (clk_div == 24'd8_000_000) begin
                clk_div <= 0;
                if (led_index == 2'd2) led_index <= 0;
                else led_index <= led_index + 1'b1;
            end else begin
                clk_div <= clk_div + 1'b1;
            end
        end
    end
    assign O_led[0] = (led_index == 2'd0) ? 1'b0 : 1'b1;
    assign O_led[1] = (led_index == 2'd1) ? 1'b0 : 1'b1;
    assign O_led[2] = (led_index == 2'd2) ? 1'b0 : 1'b1;
    assign O_uart_tx = 1'b1;

    // ==========================================
    // 3. ĐƯỜNG BUS LIÊN KẾT CPU VÀ PHÂN VÙNG BỘ NHỚ
    // ==========================================
    wire [31:0] cpu_mem_addr;
    wire [31:0] cpu_mem_wdata;
    wire [3:0]  cpu_mem_wstrb;
    wire        cpu_mem_valid;
    wire [31:0] cpu_mem_rdata;
    wire        cpu_mem_ready;

    femtorv_quark cpu_core (
        .clk(sys_clk),
        .rst_n(sys_rst_n && !jtag_ram_wre),
        .mem_addr(cpu_mem_addr),
        .mem_wdata(cpu_mem_wdata),
        .mem_wstrb(cpu_mem_wstrb),
        .mem_valid(cpu_mem_valid),
        .mem_rdata(cpu_mem_rdata),
        .mem_ready(cpu_mem_ready)
    );

    // Phân vùng: gowin_sp (1KB) tại 0x00000000 | PSRAM (8MB) tại 0x20000000
    wire is_ram   = (cpu_mem_addr[31:10] == 22'h000000); 
    wire is_psram = (cpu_mem_addr[31:24] == 8'h20); 

    // Quản lý tín hiệu Ready phản hồi về CPU
    wire psram_ready;
    assign cpu_mem_ready = is_ram ? cpu_mem_valid : (is_psram ? psram_ready : cpu_mem_valid);

    // MUX dữ liệu đọc trả về cho CPU
    wire [31:0] ram_dout;
    wire [31:0] psram_dout;
    assign cpu_mem_rdata = is_ram ? ram_dout : (is_psram ? psram_dout : 32'h00000000);

    // ==========================================
    // 4. MẠCH ĐIỀU KHIỂN PSRAM (PSRAM CONTROLLER FSM)
    // ==========================================
    reg [2:0]  psram_state;
    reg [5:0]  bit_cnt;
    reg [39:0] shift_out;
    reg [31:0] shift_in;
    reg        psram_ce_reg;
    reg        psram_mosi_reg;

    localparam IDLE  = 3'd0;
    localparam CMD   = 3'd1;
    localparam DATA  = 3'd2;
    localparam DONE  = 3'd3;

    wire psram_write = |cpu_mem_wstrb;
    
    always @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            psram_state    <= IDLE;
            bit_cnt        <= 0;
            psram_ce_reg   <= 1'b1;
            psram_mosi_reg <= 1'b0;
            shift_in       <= 32'h0;
            shift_out      <= 40'h0;
        end else begin
            case (psram_state)
                IDLE: begin
                    psram_ce_reg <= 1'b1;
                    if (cpu_mem_valid && is_psram) begin
                        psram_ce_reg <= 1'b0; // Kéo CE xuống thấp để chọn chip
                        bit_cnt      <= 0;
                        psram_state  <= CMD;
                        // Nạp [8-bit Lệnh][24-bit Địa chỉ]
                        // Ghi: Lệnh 0x02, Đọc: Lệnh 0x03
                        shift_out    <= {psram_write ? 8'h02 : 8'h03, cpu_mem_addr[23:0], 8'h00};
                    end
                end

                CMD: begin // Phát xong 32-bit (8-bit lệnh + 24-bit địa chỉ)
                    psram_mosi_reg <= shift_out[39];
                    shift_out      <= {shift_out[38:0], 1'b0};
                    bit_cnt        <= bit_cnt + 1'b1;
                    if (bit_cnt == 31) begin
                        bit_cnt     <= 0;
                        shift_out   <= cpu_mem_wdata; // Chuẩn bị sẵn dữ liệu nếu là lệnh ghi
                        psram_state <= DATA;
                    end
                end

                DATA: begin // Dịch tiếp 32-bit dữ liệu (Ghi ra MOSI hoặc Đọc vào MISO)
                    bit_cnt <= bit_cnt + 1'b1;
                    if (psram_write) begin
                        psram_mosi_reg <= shift_out[31];
                        shift_out      <= {shift_out[30:0], 1'b0};
                    end else begin
                        shift_in       <= {shift_in[30:0], IO_psram_d1};
                    end
                    
                    if (bit_cnt == 31) begin
                        psram_ce_reg <= 1'b1; // Ngắt chọn chip sau khi xong việc
                        psram_state  <= DONE;
                    end
                end

                DONE: begin
                    psram_state <= IDLE;
                end
            endcase
        end
    end

    // Ánh xạ tín hiệu điều khiển ra chân PSRAM vật lý
    assign O_psram_ce  = psram_ce_reg;
    assign O_psram_ck  = (psram_state == CMD || psram_state == DATA) ? !sys_clk : 1'b0; // Cấp clock khi truyền dữ liệu
    assign IO_psram_d0 = psram_write ? psram_mosi_reg : 1'bz; // Chân MOSI
    assign IO_psram_d2 = 1'b1; // Kéo cao chân bảo vệ chống ghi
    assign IO_psram_d3 = 1'b1; // Kéo cao chân giữ trạng thái
    
    // Tín hiệu bắt tay đồng bộ dữ liệu
    assign psram_ready = (psram_state == DONE);
    assign psram_dout  = shift_in;

    // ==========================================
    // 5. KHỐI RAM MỒI GOWIN_SP (GIỮ NGUYÊN)
    // ==========================================
wire [7:0]  final_ram_addr = cpu_mem_addr[9:2];
    wire [31:0] final_ram_din  = cpu_mem_wdata;
    wire        final_ram_wre  = (cpu_mem_valid && |cpu_mem_wstrb && is_ram);

    Gowin_SP your_ram_block (
        .dout(ram_dout),
        .clk(sys_clk),
        .oce(1'b0),
        .ce(1'b1),
        .reset(!sys_rst_n),
        .wre(final_ram_wre),
        .ad(final_ram_addr),
        .din(final_ram_din)
    );

endmodule