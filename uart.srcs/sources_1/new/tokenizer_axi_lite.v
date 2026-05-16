`timescale 1ns / 1ps

// ============================================================================
// tokenizer_axi_lite.v
//
// AXI-Lite Slave Wrapper for FPGA WordPiece Tokenizer Pipeline.
// Contains: Input FIFO (8-bit) -> top_tokenizer -> Output FIFO (16-bit)
//
// The MicroBlaze writes ASCII bytes and reads BERT Token IDs through
// four memory-mapped registers:
//
// Register Map:
//   0x00  TX_DATA  (W)  - Write an 8-bit ASCII byte into the input FIFO
//   0x04  RX_DATA  (R)  - Read a 16-bit Token ID from the output FIFO
//   0x08  STATUS   (R)  - Bit 0: input FIFO not full (1 = safe to write)
//                         Bit 1: output FIFO not empty (1 = token available)
//   0x0C  RESERVED
//
// Usage from MicroBlaze C code:
//   1. Check STATUS bit 0 before writing to TX_DATA
//   2. Check STATUS bit 1 before reading from RX_DATA
//   3. Write ASCII bytes (including spaces as word delimiters)
//   4. Poll STATUS bit 1, then read RX_DATA for each token ID
//
// ============================================================================

module tokenizer_axi_lite #(
    // AXI-Lite parameters
    parameter C_S_AXI_DATA_WIDTH = 32,
    parameter C_S_AXI_ADDR_WIDTH = 4,  // 4 bits = 16 bytes = 4 registers
    // Tokenizer parameters
    parameter CHAR_W  = 10,
    parameter TOKEN_W = 16,
    // FIFO depths (must be power of 2)
    parameter IN_FIFO_DEPTH_LOG2  = 8, // 2^8 = 256 entries
    parameter OUT_FIFO_DEPTH_LOG2 = 8  // 2^8 = 256 entries
)(
    // AXI-Lite Slave Interface
    input  wire                                s_axi_aclk,
    input  wire                                s_axi_aresetn,
    // Write address channel
    input  wire [C_S_AXI_ADDR_WIDTH-1:0]       s_axi_awaddr,
    input  wire                                s_axi_awvalid,
    output reg                                 s_axi_awready,
    // Write data channel
    input  wire [C_S_AXI_DATA_WIDTH-1:0]       s_axi_wdata,
    input  wire [(C_S_AXI_DATA_WIDTH/8)-1:0]   s_axi_wstrb,
    input  wire                                s_axi_wvalid,
    output reg                                 s_axi_wready,
    // Write response channel
    output reg  [1:0]                          s_axi_bresp,
    output reg                                 s_axi_bvalid,
    input  wire                                s_axi_bready,
    // Read address channel
    input  wire [C_S_AXI_ADDR_WIDTH-1:0]       s_axi_araddr,
    input  wire                                s_axi_arvalid,
    output reg                                 s_axi_arready,
    // Read data channel
    output reg  [C_S_AXI_DATA_WIDTH-1:0]       s_axi_rdata,
    output reg  [1:0]                          s_axi_rresp,
    output reg                                 s_axi_rvalid,
    input  wire                                s_axi_rready
);

    // ========================================================================
    // Internal clock and reset (active-high reset for tokenizer)
    // ========================================================================
    wire clk;
    wire rst;
    assign clk = s_axi_aclk;
    assign rst = ~s_axi_aresetn;

    // ========================================================================
    // Input FIFO (8-bit): AXI writes -> Pre-Tokenizer reads
    // Synchronous FIFO with registered output (FWFT style)
    //
    // The output register holds the current byte until the pre-tokenizer
    // actually consumes it (in_fifo_pop). This prevents the FIFO from
    // racing ahead of the pre-tokenizer when fifo_ready stays high.
    // ========================================================================
    localparam IN_FIFO_DEPTH = (1 << IN_FIFO_DEPTH_LOG2);

    reg [7:0]                      in_fifo_mem [0:IN_FIFO_DEPTH-1];
    reg [IN_FIFO_DEPTH_LOG2:0]     in_fifo_wr_ptr;
    reg [IN_FIFO_DEPTH_LOG2:0]     in_fifo_rd_ptr;

    wire in_fifo_full  = (in_fifo_wr_ptr[IN_FIFO_DEPTH_LOG2] != in_fifo_rd_ptr[IN_FIFO_DEPTH_LOG2]) &&
                         (in_fifo_wr_ptr[IN_FIFO_DEPTH_LOG2-1:0] == in_fifo_rd_ptr[IN_FIFO_DEPTH_LOG2-1:0]);
    wire in_fifo_empty = (in_fifo_wr_ptr == in_fifo_rd_ptr);

    // Registered output stage - present one byte at a time
    // After each byte is consumed, deassert valid for one cooldown cycle
    // before presenting the next byte. This matches the timing that
    // the pre-tokenizer expects between consecutive bytes.
    reg [7:0] in_fifo_out_data;
    reg       in_fifo_out_valid;
    wire      in_fifo_ready; // from tokenizer (fifo_in_ready)

    // FIFO write (from AXI)
    reg in_fifo_wr_en;

    always @(posedge clk) begin
        if (rst) begin
            in_fifo_wr_ptr    <= 0;
            in_fifo_rd_ptr    <= 0;
            in_fifo_out_data  <= 8'd0;
            in_fifo_out_valid <= 1'b0;
        end else begin
            // Write side: AXI pushes a byte
            if (in_fifo_wr_en && !in_fifo_full) begin
                in_fifo_mem[in_fifo_wr_ptr[IN_FIFO_DEPTH_LOG2-1:0]] <= s_axi_wdata[7:0];
                in_fifo_wr_ptr <= in_fifo_wr_ptr + 1;
            end

            // Output register state machine
            if (in_fifo_out_valid && in_fifo_ready) begin
                // Byte was consumed - clear output
                in_fifo_out_valid <= 1'b0;
            end else if (!in_fifo_out_valid && !tok_word_busy) begin
                // Output empty AND pre-tokenizer not processing a word boundary
                if (!in_fifo_empty) begin
                    in_fifo_out_data  <= in_fifo_mem[in_fifo_rd_ptr[IN_FIFO_DEPTH_LOG2-1:0]];
                    in_fifo_out_valid <= 1'b1;
                    in_fifo_rd_ptr    <= in_fifo_rd_ptr + 1;
                end
            end
        end
    end

    // ========================================================================
    // Output FIFO (16-bit): Trie Engine writes -> AXI reads
    // ========================================================================
    localparam OUT_FIFO_DEPTH = (1 << OUT_FIFO_DEPTH_LOG2);

    reg [TOKEN_W-1:0]              out_fifo_mem [0:OUT_FIFO_DEPTH-1];
    reg [OUT_FIFO_DEPTH_LOG2:0]    out_fifo_wr_ptr;
    reg [OUT_FIFO_DEPTH_LOG2:0]    out_fifo_rd_ptr;

    wire out_fifo_full  = (out_fifo_wr_ptr[OUT_FIFO_DEPTH_LOG2] != out_fifo_rd_ptr[OUT_FIFO_DEPTH_LOG2]) &&
                          (out_fifo_wr_ptr[OUT_FIFO_DEPTH_LOG2-1:0] == out_fifo_rd_ptr[OUT_FIFO_DEPTH_LOG2-1:0]);
    wire out_fifo_empty = (out_fifo_wr_ptr == out_fifo_rd_ptr);

    // FIFO read side signals (to AXI)
    wire [TOKEN_W-1:0] out_fifo_dout = out_fifo_mem[out_fifo_rd_ptr[OUT_FIFO_DEPTH_LOG2-1:0]];

    // FIFO write (from tokenizer)
    wire        tok_out_valid; // from tokenizer
    wire [TOKEN_W-1:0] tok_out_data;  // from tokenizer
    
    wire tok_word_busy;

    // FIFO read (AXI pulls)
    reg out_fifo_rd_en;

    always @(posedge clk) begin
        if (rst) begin
            out_fifo_wr_ptr <= 0;
            out_fifo_rd_ptr <= 0;
        end else begin
            // Write side: tokenizer pushes a token
            if (tok_out_valid && !out_fifo_full) begin
                out_fifo_mem[out_fifo_wr_ptr[OUT_FIFO_DEPTH_LOG2-1:0]] <= tok_out_data;
                out_fifo_wr_ptr <= out_fifo_wr_ptr + 1;
            end
            // Read side: AXI reads a token
            if (out_fifo_rd_en && !out_fifo_empty) begin
                out_fifo_rd_ptr <= out_fifo_rd_ptr + 1;
            end
        end
    end

    // ========================================================================
    // Tokenizer Pipeline Instance
    // ========================================================================
    top_tokenizer #(
        .CHAR_W  (CHAR_W),
        .TOKEN_W (TOKEN_W)
    ) u_tokenizer (
        .clk            (clk),
        .rst            (rst),
        // Input: from input FIFO (registered output)
        .fifo_in_data   (in_fifo_out_data),
        .fifo_in_valid  (in_fifo_out_valid),
        .fifo_in_ready  (in_fifo_ready),
        // Output: to output FIFO
        .fifo_out_data      (tok_out_data),
        .fifo_out_valid     (tok_out_valid),
        .word_boundary_busy (tok_word_busy)
    );

    // ========================================================================
    // AXI-Lite Slave: Write Logic
    // ========================================================================
    reg [C_S_AXI_ADDR_WIDTH-1:0] axi_awaddr_latched;
    reg aw_ready_done;
    reg w_ready_done;

    always @(posedge clk) begin
        if (rst) begin
            s_axi_awready    <= 1'b0;
            s_axi_wready     <= 1'b0;
            s_axi_bvalid     <= 1'b0;
            s_axi_bresp      <= 2'b00;
            in_fifo_wr_en    <= 1'b0;
            aw_ready_done    <= 1'b0;
            w_ready_done     <= 1'b0;
            axi_awaddr_latched <= 0;
        end else begin
            // Default: clear write enable pulse
            in_fifo_wr_en <= 1'b0;

            // Accept write address
            if (s_axi_awvalid && !aw_ready_done) begin
                s_axi_awready <= 1'b1;
                axi_awaddr_latched <= s_axi_awaddr;
                aw_ready_done <= 1'b1;
            end else begin
                s_axi_awready <= 1'b0;
            end

            // Accept write data
            if (s_axi_wvalid && !w_ready_done) begin
                s_axi_wready <= 1'b1;
                w_ready_done <= 1'b1;
            end else begin
                s_axi_wready <= 1'b0;
            end

            // When both address and data are captured, perform the write
            if (aw_ready_done && w_ready_done) begin
                // Register 0x00: TX_DATA - push byte into input FIFO
                if (axi_awaddr_latched[3:2] == 2'b00) begin
                    in_fifo_wr_en <= 1'b1;
                end
                // Issue write response
                s_axi_bvalid  <= 1'b1;
                s_axi_bresp   <= 2'b00; // OKAY
                aw_ready_done <= 1'b0;
                w_ready_done  <= 1'b0;
            end

            // Clear write response when master acknowledges
            if (s_axi_bvalid && s_axi_bready) begin
                s_axi_bvalid <= 1'b0;
            end
        end
    end

    // ========================================================================
    // AXI-Lite Slave: Read Logic
    // ========================================================================
    always @(posedge clk) begin
        if (rst) begin
            s_axi_arready  <= 1'b0;
            s_axi_rvalid   <= 1'b0;
            s_axi_rdata    <= 0;
            s_axi_rresp    <= 2'b00;
            out_fifo_rd_en <= 1'b0;
        end else begin
            // Default: clear read enable pulse
            out_fifo_rd_en <= 1'b0;

            // Accept read address and respond with data
            if (s_axi_arvalid && !s_axi_rvalid) begin
                s_axi_arready <= 1'b1;
                s_axi_rvalid  <= 1'b1;
                s_axi_rresp   <= 2'b00; // OKAY

                case (s_axi_araddr[3:2])
                    2'b00: begin
                        // 0x00: TX_DATA (read returns 0, write-only register)
                        s_axi_rdata <= 32'd0;
                    end
                    2'b01: begin
                        // 0x04: RX_DATA - read token ID from output FIFO
                        if (!out_fifo_empty) begin
                            s_axi_rdata    <= {{(32-TOKEN_W){1'b0}}, out_fifo_dout};
                            out_fifo_rd_en <= 1'b1; // pop from FIFO
                        end else begin
                            s_axi_rdata <= 32'hFFFF_FFFF; // no data available
                        end
                    end
                    2'b10: begin
                        // 0x08: STATUS register
                        // Bit 0: input FIFO not full (safe to write)
                        // Bit 1: output FIFO not empty (token available)
                        s_axi_rdata <= {30'd0, ~out_fifo_empty, ~in_fifo_full};
                    end
                    default: begin
                        // 0x0C: Reserved
                        s_axi_rdata <= 32'd0;
                    end
                endcase
            end else begin
                s_axi_arready <= 1'b0;
            end

            // Clear read valid when master acknowledges
            if (s_axi_rvalid && s_axi_rready) begin
                s_axi_rvalid <= 1'b0;
            end
        end
    end

endmodule