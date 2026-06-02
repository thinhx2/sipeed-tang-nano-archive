module femtorv_quark (
    input  wire        clk,
    input  wire        rst_n,
    output wire [31:0] mem_addr,
    output wire [31:0] mem_wdata,
    output wire [3:0]  mem_wstrb,
    output wire        mem_valid,
    input  wire [31:0] mem_rdata,
    input  wire        mem_ready
);

    reg [31:0] PC = 32'h00000000;
    reg [31:0] instr;
    
    // Thuộc tính ép buộc Gowin EDA sử dụng Distributed RAM/Shadow RAM
    /* gowin_distributed_ram = 1 */ reg [31:0] regs [0:31]; 

    reg [1:0] state = 2'b00;
    localparam STATE_FETCH = 2'b00;
    localparam STATE_EXEC  = 2'b01;

    // Giải mã lệnh (Decode)
    wire [4:0] rd     = instr[11:7];
    wire [4:0] rs1    = instr[19:15];
    wire [4:0] rs2    = instr[24:20];
    wire [6:0] opcode = instr[6:0];

    wire [31:0] Iimm = {{20{instr[31]}}, instr[31:20]};

    // Tạo các thanh ghi chốt dữ liệu đọc từ RAM để đồng bộ hóa góc nhìn (Synchronous Read)
    reg [31:0] reg_rs1_data;
    reg [31:0] reg_rs2_data;

    // Chuyển toàn bộ hành vi đọc regs về dạng Synchronous
    always @(posedge clk) begin
        reg_rs1_data <= regs[rs1];
        reg_rs2_data <= regs[rs2];
    end

    // Đường Bus kết nối bộ nhớ sử dụng dữ liệu đã đồng bộ hóa
    assign mem_addr  = (state == STATE_FETCH) ? PC : (reg_rs1_data + Iimm);
    assign mem_valid = 1'b1;
    assign mem_wstrb = (state == STATE_EXEC && opcode == 7'h23) ? 4'b1111 : 4'b0000; 
    assign mem_wdata = reg_rs2_data;

    // Khối 1: Ghi dữ liệu vào Register File (Không chứa logic Reset để suy luận ra RAM)
    always @(posedge clk) begin
        if (state == STATE_EXEC && mem_ready) begin
            if (opcode == 7'h13) begin
                if (rd != 5'd0) begin
                    regs[rd] <= reg_rs1_data + Iimm;
                end
            end
        end
    end

    // Khối 2: Điều khiển trạng thái và PC (Giữ lại Reset cứng)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            PC    <= 32'h00000000;
            state <= STATE_FETCH;
            instr <= 32'h00000000;
        end else begin
            case(state)
                STATE_FETCH: begin
                    if (mem_ready) begin
                        instr <= mem_rdata;
                        state <= STATE_EXEC;
                    end
                end
                STATE_EXEC: begin
                    if (mem_ready) begin
                        PC    <= PC + 4; 
                        state <= STATE_FETCH;
                    end
                end
            endcase
        end
    end

endmodule