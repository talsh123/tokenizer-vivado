`timescale 1ns / 1ps // simulation time resolution: 1ns - time unit, 1ps - precision

// tokenizer_axi_lite.v
// this module is the outermost module which wraps everything.
// this bridges (connects) the MicroBlaze software (AXI Bus) and the hardware tokenizer pipeline.
// it contains the AXI-Lite slaves interface, the input FIFO and the output FIFO, and instantiates top_tokenizer.

module tokenizer_axi_lite #(
    // parameter section - AXI-Lite parameters
    parameter C_S_AXI_DATA_WIDTH = 32, // 32-bit AXI-Lite data width (this matches the MicroBlaze's 32-bit data bus)
    parameter C_S_AXI_ADDR_WIDTH = 4,  // 4-bit AXI-Lite address width, 2^4 = 16 bytes of address space.
    
    // parameter section - tokenizer parameters
    parameter CHAR_W  = 10, // 10 bits of the alphabet index, 2^10 = 1024 > ~1008 unique characters
    parameter TOKEN_W = 16, // the token IDs consist of 16 bits -> 65,535 >> 30,522 BERT's token limit
    
    // parameter section - FIFO parameters
    parameter IN_FIFO_DEPTH_LOG2  = 8, // both FIFOs are 2^8 = 256 entries deep. holds ascii bytes (enough for 256 character sentence).
    parameter OUT_FIFO_DEPTH_LOG2 = 8  // both FIFOs are 2^8 = 256 entries deep. holds 256 token IDs. 
)(
    // inputs and outputs section - AXI-Lite slave interface
    input wire s_axi_aclk, // the AXI clock
    input wire s_axi_aresetn, // the active-LOW reset. NOTE: the tokenizer pipeline uses active-HIGH reset, the conversion happens later.
    
    // inputs and outputs section - AXI-Lite write channels
    // write access channel - WHERE to write
    input wire [C_S_AXI_ADDR_WIDTH-1:0] s_axi_awaddr, // the address where to write
    input wire s_axi_awvalid, // if the write is valid
    output reg s_axi_awready, // if we are ready to write
    // write data channel - WHAT to write
    input wire [C_S_AXI_DATA_WIDTH-1:0] s_axi_wdata, // the data we write
    input wire [(C_S_AXI_DATA_WIDTH/8)-1:0] s_axi_wstrb, // write strobe - 4 bits indicating which bytes of the 32-bit word are valid. NOTE: we do not use this because we only care about the lower 8 bits of TX_DATA.
    input wire s_axi_wvalid, // if the data is valid
    output reg s_axi_wready, // if we are ready to write
    // write response channel - tells the master the write has succeeded
    output reg [1:0] s_axi_bresp, // response code: 2'b00 = OKAY, 2'b10 = SLVERR (slave error), 2'b11 = DECERR (decode error).
    output reg s_axi_bvalid, // if the response is valid
    input wire s_axi_bready, // if the master is ready to receive the response
    
    // inputs and outputs section - AXI-Lite read channels
    // read address channel - WHERE to read
    input wire [C_S_AXI_ADDR_WIDTH-1:0] s_axi_araddr, // the address of where to read
    input wire  s_axi_arvalid, // if the read was valid
    output reg s_axi_arready, // if we are ready to read
    // read data channel - WHAT to read
    output reg [C_S_AXI_DATA_WIDTH-1:0] s_axi_rdata, // the data we need to read 
    output reg [1:0] s_axi_rresp, // response code: 2'b00 = OKAY, 2'b10 = SLVERR (slave error), 2'b11 = DECERR (decode error).
    output reg s_axi_rvalid, // is the data is valid
    input wire s_axi_rready // if the master is ready to read the data
);

    // clock and reset conversion
    wire clk;
    wire rst;
    assign clk = s_axi_aclk; // clk is set as the clock we've defined earlier in the input and outputs section.
    assign rst = ~s_axi_aresetn; // rst inverts the active-low AXI reset for the tokenizer pipeline which uses active-HIGH reset.

    // input FIFO declarations
    localparam IN_FIFO_DEPTH = (1 << IN_FIFO_DEPTH_LOG2); // 1 << 8 (IN_FIFO_DEPTH_LOG2) = 256 entries deep.

    reg [7:0] in_fifo_mem [0:IN_FIFO_DEPTH-1]; // this is the storage array, 256 entries of 8 bits each
    reg [IN_FIFO_DEPTH_LOG2:0] in_fifo_wr_ptr; // 9 bit pointer - extra bit is important for full/empty detection logic.
    reg [IN_FIFO_DEPTH_LOG2:0] in_fifo_rd_ptr; // 9 bit pointer - extra bit is important for full/empty detection logic.
    // if we only had 8 bits, both pointers wrap from 255 to 0.
    // when wr_ptr = rd_ptr, it could mean that either FIFO is empty (nothing was written) or the FIFO is full (256 items were written into the FIFO and the pointer wrapped around)
    // the extra MSB (most significant bit) tells us the difference:
    // if the lower 8 bits match but the MSB differs, the write pointer has lapped the read pointer - FIFO is full.
    // if both the MSB and lower bits match, they're at the same position - FIFO is empty.

    // FULL: if the MSB differs and the lower bits match, then the fifo is FULL.
    wire in_fifo_full = (in_fifo_wr_ptr[IN_FIFO_DEPTH_LOG2] != in_fifo_rd_ptr[IN_FIFO_DEPTH_LOG2]) &&
                         (in_fifo_wr_ptr[IN_FIFO_DEPTH_LOG2-1:0] == in_fifo_rd_ptr[IN_FIFO_DEPTH_LOG2-1:0]);
    // EMPTY: if both pointers are identical, then the fifo is EMPTY.
    wire in_fifo_empty = (in_fifo_wr_ptr == in_fifo_rd_ptr);

    // the registered output stage
    reg [7:0] in_fifo_out_data; // holds 1 byte for the pre-tokenizer to consume 
    reg in_fifo_out_valid; // a flag which represents if the byte we are holding for the pre-tokenizer is valid
    wire in_fifo_ready; // a signal from top_tokenizer indicating the byte was consumed.

    reg in_fifo_wr_en; // a single cycle pulse that triggers a FIFO write

    
    always @(posedge clk) begin
        if (rst) begin // if reset
            in_fifo_wr_ptr    <= 0; // pointer cleared
            in_fifo_rd_ptr    <= 0; // pointer cleared
            in_fifo_out_data  <= 8'd0; // output register cleared
            in_fifo_out_valid <= 1'b0; // output register cleared
        end else begin // AXI-Lite pushes a byte
            if (in_fifo_wr_en && !in_fifo_full) begin // is a FIFO write is triggered and the FIFO isn't full
                in_fifo_mem[in_fifo_wr_ptr[IN_FIFO_DEPTH_LOG2-1:0]] <= s_axi_wdata[7:0]; // store the lower 8 bits of the AXI-Lite write data at the current write position
                in_fifo_wr_ptr <= in_fifo_wr_ptr + 1; // advance the write pointer
            end

            // a 2 state machine for the output register
            if (in_fifo_out_valid && in_fifo_ready) begin // if valid = 1, ready = 1, the pre-tokenizer just consumed a byte
                in_fifo_out_valid <= 1'b0; // clear the valid flag and move on
            end else if (!in_fifo_out_valid && !tok_word_busy) begin // if valid = 0, word_busy = 0, the output register is empty and the pre-tokenizer isn't handling a word boundary.
                if (!in_fifo_empty) begin // if the fifo has data
                    in_fifo_out_data  <= in_fifo_mem[in_fifo_rd_ptr[IN_FIFO_DEPTH_LOG2-1:0]]; // read the next byte
                    in_fifo_out_valid <= 1'b1; // set the valid flag
                    in_fifo_rd_ptr    <= in_fifo_rd_ptr + 1; // advance the read pointer
                end
                // if valid = 0, word_busy = 1 - the output register is empty but the pre-tokenizer is busy with a word boundary.
                // do NOT present a new byte - wait until the word boundary processing completes.
                // this is the gate that prevents characters from the next word leaking into the trie engine before it's ready.
            end
        end
    end

    // output FIFO declarations
    localparam OUT_FIFO_DEPTH = (1 << OUT_FIFO_DEPTH_LOG2); // 1 << 8 (OUT_FIFO_DEPTH_LOG2) = 256 entries deep.

    reg [TOKEN_W-1:0] out_fifo_mem [0:OUT_FIFO_DEPTH-1]; // this is the storage array, 256 entries of 16 bits each
    reg [OUT_FIFO_DEPTH_LOG2:0] out_fifo_wr_ptr; // 9 bit pointer - extra bit is important for full/empty detection logic.
    reg [OUT_FIFO_DEPTH_LOG2:0] out_fifo_rd_ptr; // 9 bit pointer - extra bit is important for full/empty detection logic.

    // FULL: if the MSB differs and the lower bits match, then the fifo is FULL.
    wire out_fifo_full  = (out_fifo_wr_ptr[OUT_FIFO_DEPTH_LOG2] != out_fifo_rd_ptr[OUT_FIFO_DEPTH_LOG2]) &&
                          (out_fifo_wr_ptr[OUT_FIFO_DEPTH_LOG2-1:0] == out_fifo_rd_ptr[OUT_FIFO_DEPTH_LOG2-1:0]);
    // EMPTY: if both pointers are identical, then the fifo is EMPTY.
    wire out_fifo_empty = (out_fifo_wr_ptr == out_fifo_rd_ptr);

    wire [TOKEN_W-1:0] out_fifo_dout = out_fifo_mem[out_fifo_rd_ptr[OUT_FIFO_DEPTH_LOG2-1:0]]; // combinational read - the current front-of-FIFO value is always available on out_fifo_dout. This is NOT registered - it's a direct array lookup
    
    // 3 wires from the tokenizer pipeline
    wire tok_out_valid; // this indicated if emitted signal is a valid token (1) or not (0)
    wire [TOKEN_W-1:0] tok_out_data; // this carries the emitted token from the tokenizer pipeline
    wire tok_word_busy; // word boundary gate signal from the pre-tokenizer, indicating that the pre-tokenizer is waiting for the trie engine to acknowledge the boundary

    reg out_fifo_rd_en; // single cycle pulse that triggers a FIFO read

    always @(posedge clk) begin
        if (rst) begin // if we have a reset signal
            out_fifo_wr_ptr <= 0; // cleared
            out_fifo_rd_ptr <= 0; // cleared
        end else begin // else
            if (tok_out_valid && !out_fifo_full) begin // when the trie engine emits a token and the output FIFO is not full
                out_fifo_mem[out_fifo_wr_ptr[OUT_FIFO_DEPTH_LOG2-1:0]] <= tok_out_data; // stores the outputted token
                out_fifo_wr_ptr <= out_fifo_wr_ptr + 1; // advances the pointer
            end
            if (out_fifo_rd_en && !out_fifo_empty) begin // if we have a FIFO read pulse and the output FIFO is not empty
                out_fifo_rd_ptr <= out_fifo_rd_ptr + 1; // advances the pointer
            end
        end
    end

    // tokenizer pipeline instantiation
    // this entire block instantiates the top_tokenizer instance
    // connects the input FIFO's output register to the tokenizer's input, and the tokenizer's output to the output FIFO's write side.
    top_tokenizer #(
        .CHAR_W  (CHAR_W),
        .TOKEN_W (TOKEN_W)
    ) u_tokenizer ( // the name of the top_tokenizer instance
        .clk            (clk),
        .rst            (rst),
        // Input: from input FIFO (registered output)
        .fifo_in_data   (in_fifo_out_data),
        .fifo_in_valid  (in_fifo_out_valid),
        .fifo_in_ready  (in_fifo_ready), // comes back from the tokenizer telling the input FIFO when a byte was consumed
        // Output: to output FIFO
        .fifo_out_data      (tok_out_data),
        .fifo_out_valid     (tok_out_valid),
        .word_boundary_busy (tok_word_busy) // comes back to gate the input FIFO during word boundaries.
    );

    // 3 helper registers - AXI-Lite write logic
    reg [C_S_AXI_ADDR_WIDTH-1:0] axi_awaddr_latched; // captures the write address when it arrives.
    reg aw_ready_done; // tracks whether the address phase has completed
    reg w_ready_done; // tracks whether the data phase has completed
    // the address and the data phases can come in different times, so we need to wait for both

    always @(posedge clk) begin
        if (rst) begin // if reset
            s_axi_awready <= 1'b0; // cleared
            s_axi_wready <= 1'b0; // cleared
            s_axi_bvalid <= 1'b0; // cleared
            s_axi_bresp <= 2'b00; // cleared
            in_fifo_wr_en <= 1'b0; // cleared
            aw_ready_done <= 1'b0; // cleared
            w_ready_done <= 1'b0; // cleared
            axi_awaddr_latched <= 0; // cleared
        end else begin
            in_fifo_wr_en <= 1'b0; // on default in every cycle, in_fifo_wr_en is 0. it only goes high when both address and data are ready.

            // accept write address
            if (s_axi_awvalid && !aw_ready_done) begin // when the master presents a valid write address and we haven't captured it yet
                s_axi_awready <= 1'b1; // assert s_axi_awready for 1 cycle (telling the master "i got your address")
                axi_awaddr_latched <= s_axi_awaddr; // latch the address
                aw_ready_done <= 1'b1; // set the ready_done flag
            end else begin // on the next cycle, s_axi_awready is 0
                s_axi_awready <= 1'b0; // goes back to 0
            end

            if (s_axi_wvalid && !w_ready_done) begin // when the master presents valid data and we haven't captured it yet
                s_axi_wready <= 1'b1; // assert s_axi_wready for 1 cycle (telling the master "i got your data") 
                w_ready_done <= 1'b1; // set the ready_done flag
            end else begin // on the next cycle, w_ready_done is 0 
                s_axi_wready <= 1'b0; // goes back to 0
            end

            if (aw_ready_done && w_ready_done) begin // once both phases are done - address and data are captured
                if (axi_awaddr_latched[3:2] == 2'b00) begin // check the address: [3:2] extracts the register select bits
                // 2'b00 = address 0x00 = TX_DATA.
                // if the write targets TX_DATA, pulse in_fifo_wr_en to push the byte into the input FIFO
                // for any other register, the write is silently ignored.
                    in_fifo_wr_en <= 1'b1; // pulse in FIFO write signal
                end
                // issue a write response and reset the flags for the next transaction.
                s_axi_bvalid  <= 1'b1; // bvalid = 1
                s_axi_bresp   <= 2'b00; // bresp = OKAY
                aw_ready_done <= 1'b0; // cleared
                w_ready_done  <= 1'b0; // cleared
            end

            // the write response gets asserted until the master acknowledges it by asserting bready
            // then we clear bvalid
            if (s_axi_bvalid && s_axi_bready) begin
                s_axi_bvalid <= 1'b0; // clear bvalid
            end
        end
    end

    // AXI-Lite Slave: Read Logic
    always @(posedge clk) begin
        if (rst) begin
            s_axi_arready <= 1'b0; // cleared
            s_axi_rvalid <= 1'b0; // cleared
            s_axi_rdata <= 0; // cleared
            s_axi_rresp <= 2'b00; // cleared
            out_fifo_rd_en <= 1'b0; // cleared
        end else begin
            out_fifo_rd_en <= 1'b0; // on default every cycle, out_fifo_rd_en is 0. it only goes high when RX_DATA (0x04) is read.

            if (s_axi_arvalid && !s_axi_rvalid) begin // when the master requests a read and we are not already holding a response
                s_axi_arready <= 1'b1; // s_axi_arready goes HIGH
                s_axi_rvalid  <= 1'b1; // s_axi_rvalid goes HIGH
                s_axi_rresp   <= 2'b00; // OKAY

                case (s_axi_araddr[3:2]) // a switch case statement on the return address
                    2'b00: begin // corresponds to 0x00, meaning a write-only register
                        s_axi_rdata <= 32'd0; // return 0
                    end
                    2'b01: begin // corresponds to 0x04 (RX_DATA), meaning the output FIFO has data 
                        if (!out_fifo_empty) begin // if the output FIFO is not empty
                            s_axi_rdata    <= {{(32-TOKEN_W){1'b0}}, out_fifo_dout}; // return the 16-bit token ID zero-extended to 32 bits - the upper 16 bits are zero, lower 16 are the token.
                            out_fifo_rd_en <= 1'b1; // pulse out_fifo_rd_en to advance the read pointer
                        end else begin // if the FIFO is empty
                            s_axi_rdata <= 32'hFFFF_FFFF; // return 0xFFFFFFFF as a sentinel value. The C code never hits this path because it always checks STATUS first.
                        end
                    end
                    2'b10: begin // corresponds to 0x08 (STATUS), meaning it is a STATUS register.
                        // bit 0 = ~in_fifo_full = 1, when it's safe to write (input FIFO has space).
                        // bit 1 = ~out_fifo_empty = 1 when a token is available to read. Bits 31:2 are always 0. This is what the C code's tok_can_write() and tok_has_token() functions check.
                        s_axi_rdata <= {30'd0, ~out_fifo_empty, ~in_fifo_full};
                    end
                    default: begin // reserved register returns 0.
                        // when no read is active, arready stays 0.
                        s_axi_rdata <= 32'd0; // return 0
                    end
                endcase
            end else begin
                s_axi_arready <= 1'b0; // return 0
            end

            // the read response gets asserted until the master acknowledges it by asserting rready
            // then we clear rvalid
            if (s_axi_rvalid && s_axi_rready) begin
                s_axi_rvalid <= 1'b0; // clear rvalid
            end
        end
    end

endmodule