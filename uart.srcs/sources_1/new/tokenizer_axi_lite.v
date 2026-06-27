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
    // Tell Vivado that this clock drives the AXI-Lite (s_axi) and BOTH AXI-Stream (s_axis, m_axis)
    // interfaces, so the block design associates the streams with this clock (clears BD 41-967).
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axi:s_axis:m_axis, ASSOCIATED_RESET s_axi_aresetn" *)
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
    input wire s_axi_rready, // if the master is ready to read the data

    // ================================================================================
    // AXI4-Stream interface for DMA. Lets an AXI DMA stream bytes in
    // and tokens out with no per-element CPU involvement. The AXI-Lite interface above is
    // kept for control/STATUS and as a polling fallback; in practice only one input path
    // and one output path is exercised at a time. The pre-tokenizer/trie core is unchanged,
    // so token IDs stay identical regardless of which datapath feeds/drains the FIFOs.
    // ================================================================================
    // AXI4-Stream slave - input byte stream (from DMA MM2S). tlast marks the final input byte.
    input  wire [7:0]         s_axis_tdata,
    input  wire               s_axis_tvalid,
    output wire               s_axis_tready,
    input  wire               s_axis_tlast,
    // AXI4-Stream master - output token stream (to DMA S2MM). tlast marks the final output token.
    output wire [TOKEN_W-1:0] m_axis_tdata,
    output wire               m_axis_tvalid,
    input  wire               m_axis_tready,
    output wire               m_axis_tlast
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
    // word-boundary gate from the pre-tokenizer (driven by the top_tokenizer instance further
    // below). Declared here, ahead of the input-FIFO block that reads it, so it is not referenced
    // before its declaration.
    wire tok_word_busy; // 1 while the pre-tokenizer is handing a word boundary to the trie engine

    reg in_fifo_wr_en; // a single cycle pulse that triggers a FIFO write

    // DMA input stream: accept a byte from the AXI-Stream slave when the input FIFO has space
    // and no AXI-Lite TX write is firing this cycle (the two input paths are mutually exclusive in
    // practice). s_axis_fire is the accepted-byte handshake.
    assign s_axis_tready = !in_fifo_full && !in_fifo_wr_en;
    wire s_axis_fire = s_axis_tvalid && s_axis_tready;

    always @(posedge clk) begin
        if (rst) begin // if reset
            in_fifo_wr_ptr    <= 0; // pointer cleared
            in_fifo_rd_ptr    <= 0; // pointer cleared
            in_fifo_out_data  <= 8'd0; // output register cleared
            in_fifo_out_valid <= 1'b0; // output register cleared
        end else begin // AXI-Lite pushes a byte
            if (in_fifo_wr_en && !in_fifo_full) begin // AXI-Lite TX_DATA write
                in_fifo_mem[in_fifo_wr_ptr[IN_FIFO_DEPTH_LOG2-1:0]] <= s_axi_wdata[7:0]; // store the lower 8 bits of the AXI-Lite write data at the current write position
                in_fifo_wr_ptr <= in_fifo_wr_ptr + 1; // advance the write pointer
            end else if (s_axis_fire) begin // DMA input-stream byte; s_axis_tready already implies FIFO space
                in_fifo_mem[in_fifo_wr_ptr[IN_FIFO_DEPTH_LOG2-1:0]] <= s_axis_tdata;
                in_fifo_wr_ptr <= in_fifo_wr_ptr + 1;
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
    
    // wires from the tokenizer pipeline (tok_word_busy is declared earlier, near the input FIFO
    // block that reads it, to avoid a used-before-declaration warning)
    wire tok_out_valid; // this indicated if emitted signal is a valid token (1) or not (0)
    wire [TOKEN_W-1:0] tok_out_data; // this carries the emitted token from the tokenizer pipeline
    wire tok_pipeline_busy; // high while the pre-tokenizer or trie engine still has work in flight (from top_tokenizer)

    reg out_fifo_rd_en; // single cycle pulse that triggers a FIFO read
    // read-address gate: marks that the current read-address assertion has already been serviced. A well-behaved
    // master deasserts arvalid after the handshake, but if a master holds arvalid high across (or
    // after) the read response, this flag stops a second accept from popping the output FIFO again
    // for one intended read. Cleared once arvalid drops, so the next transaction is serviced.
    reg read_addr_serviced;

    // output-FIFO overflow detection (de-silence dropped tokens)
    reg out_fifo_overflow; // sticky: set when a token is dropped because the output FIFO was full
    reg clear_overflow;    // 1-cycle pulse from the AXI write logic (write to STATUS) to clear the flag

    // DMA token-count register: counts tokens enqueued to the output FIFO since the last clear,
    // readable at AXI-Lite address 0x0C (TOKEN_COUNT). Simple-mode AXI DMA does not report the S2MM
    // received length, so the firmware reads this after a transfer to learn how many tokens came
    // back. Cleared by a write to 0x0C (clear_count pulse from the AXI write block).
    reg [TOKEN_W-1:0] tok_count;
    reg clear_count;

    // ---- DMA output stream ----
    // input_done: the input stream's final byte (tlast) has been accepted. Held until the matching
    // final token has been handed to the DMA (m_axis tlast handshake), then cleared for the next
    // transfer. Declared here, assigned in the always block below.
    reg input_done;

    // "producing": the pipeline could still push more tokens into the output FIFO. This is
    // pipeline_busy_all WITHOUT the !out_fifo_empty term -- i.e. "is anything still upstream of the
    // output FIFO?". When producing == 0 and input_done == 1, the tokens currently in the output
    // FIFO are the complete, final response, so the token that empties the FIFO is the last one.
    wire producing = tok_pipeline_busy || !in_fifo_empty || in_fifo_out_valid || tok_out_valid;

    // exactly one token left (this read empties the FIFO). Pointer subtraction (with the extra MSB)
    // gives the true occupancy 0..OUT_FIFO_DEPTH.
    wire [OUT_FIFO_DEPTH_LOG2:0] out_fifo_count = out_fifo_wr_ptr - out_fifo_rd_ptr;
    wire out_fifo_one_left = (out_fifo_count == 1);

    // present each queued token on the master stream; assert tlast on the final token of the
    // response (empties the FIFO once nothing more can be produced). m_axis_fire is the handshake.
    assign m_axis_tdata  = out_fifo_dout;
    assign m_axis_tvalid = !out_fifo_empty;
    assign m_axis_tlast  = m_axis_tvalid && out_fifo_one_left && input_done && !producing;
    wire m_axis_fire = m_axis_tvalid && m_axis_tready;

    always @(posedge clk) begin
        if (rst)
            input_done <= 1'b0;
        else if (s_axis_fire && s_axis_tlast)                 // final input byte accepted
            input_done <= 1'b1;
        else if (m_axis_fire && m_axis_tlast)                 // final token handed to the DMA
            input_done <= 1'b0;
    end

    always @(posedge clk) begin
        if (rst) begin // if we have a reset signal
            out_fifo_wr_ptr <= 0; // cleared
            out_fifo_rd_ptr <= 0; // cleared
            out_fifo_overflow <= 1'b0; // cleared
            tok_count <= {TOKEN_W{1'b0}}; // cleared (DMA token counter)
        end else begin // else
            if (tok_out_valid && !out_fifo_full) begin // when the trie engine emits a token and the output FIFO is not full
                out_fifo_mem[out_fifo_wr_ptr[OUT_FIFO_DEPTH_LOG2-1:0]] <= tok_out_data; // stores the outputted token
                out_fifo_wr_ptr <= out_fifo_wr_ptr + 1; // advances the pointer
            end
            // a token emitted while the FIFO is full is DROPPED. Record it so the loss is
            // detectable (STATUS bit 2) instead of silent. 'set' takes priority over 'clear' so
            // a drop is never missed if a clear arrives on the same cycle.
            if (tok_out_valid && out_fifo_full)
                out_fifo_overflow <= 1'b1;
            else if (clear_overflow)
                out_fifo_overflow <= 1'b0;
            // count tokens actually enqueued to the output FIFO (what the DMA will receive).
            // clear takes priority, so a per-transfer clear (write to 0x0C) before the transfer
            // zeroes it cleanly with no token in flight yet.
            if (clear_count)
                tok_count <= {TOKEN_W{1'b0}};
            else if (tok_out_valid && !out_fifo_full)
                tok_count <= tok_count + 1'b1;
            // pop on either an AXI-Lite RX_DATA read (out_fifo_rd_en) or a DMA output-stream
            // handshake (m_axis_fire). The two output paths are mutually exclusive in practice.
            if ((out_fifo_rd_en || m_axis_fire) && !out_fifo_empty) begin
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
        .word_boundary_busy (tok_word_busy), // comes back to gate the input FIFO during word boundaries.
        .pipeline_busy      (tok_pipeline_busy) // high while either pipeline stage still has work in flight
    );

    // overall pipeline-busy: the tokenizer pipeline is working, OR a byte is still queued
    // in the input FIFO / its output register, OR a token is still queued in the output FIFO,
    // OR a token is being emitted this very cycle (tok_out_valid). The last term closes a
    // one-cycle hole: when the engine emits its final token it also finalizes and goes idle,
    // but the output-FIFO write is registered, so for that single cycle the token is in flight
    // (not yet in the FIFO, engine already idle) and every other term reads 0. A poller landing
    // there would see a false "idle" and stop one token early.
    // exposed on STATUS bit 3 so the firmware can drain exactly until the hardware is idle
    // instead of waiting a fixed delay. high until every byte has been consumed and every
    // token produced has been read out.
    wire pipeline_busy_all = tok_pipeline_busy || !in_fifo_empty || in_fifo_out_valid || !out_fifo_empty || tok_out_valid;

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
            clear_overflow <= 1'b0; // cleared
            clear_count <= 1'b0; // cleared (DMA token counter)
        end else begin
            in_fifo_wr_en <= 1'b0; // on default in every cycle, in_fifo_wr_en is 0. it only goes high when both address and data are ready.
            clear_overflow <= 1'b0; // default 0; pulses high only on a write to STATUS (0x08)
            clear_count <= 1'b0; // default 0; pulses high only on a write to TOKEN_COUNT (0x0C)

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
                if (axi_awaddr_latched[3:2] == 2'b10) begin // 0x08 = STATUS -> write-to-clear the overflow flag
                    clear_overflow <= 1'b1;
                end
                if (axi_awaddr_latched[3:2] == 2'b11) begin // 0x0C = TOKEN_COUNT -> write-to-clear the counter
                    clear_count <= 1'b1;
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
            read_addr_serviced <= 1'b0; // cleared
        end else begin
            out_fifo_rd_en <= 1'b0; // on default every cycle, out_fifo_rd_en is 0. it only goes high when RX_DATA (0x04) is read.

            // once the master drops arvalid, release the gate so the next read can be serviced.
            if (!s_axi_arvalid) read_addr_serviced <= 1'b0;

            if (s_axi_arvalid && !s_axi_rvalid && !read_addr_serviced) begin // master requests a read, we are not already holding a response, and this arvalid assertion has not been serviced yet
                s_axi_arready <= 1'b1; // s_axi_arready goes HIGH
                s_axi_rvalid  <= 1'b1; // s_axi_rvalid goes HIGH
                s_axi_rresp   <= 2'b00; // OKAY
                read_addr_serviced <= 1'b1; // this read-address assertion is now serviced; block a second pop until arvalid drops

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
                        // bit 1 = ~out_fifo_empty = 1 when a token is available to read.
                        // bit 2 = out_fifo_overflow: 1 if any token was dropped because the output
                        //         FIFO was full. Sticky; cleared by reset or by writing to STATUS (0x08).
                        // bit 3 = pipeline_busy_all: 1 while any byte/word/token is still in flight
                        //         anywhere in the pipeline or FIFOs. The firmware polls this to drain
                        //         exactly until the hardware is idle instead of waiting a fixed delay.
                        // This is what the C code's tok_can_write()/tok_has_token()/tok_pipeline_busy()
                        // (and an overflow check) read.
                        s_axi_rdata <= {28'd0, pipeline_busy_all, out_fifo_overflow, ~out_fifo_empty, ~in_fifo_full};
                    end
                    2'b11: begin // 0x0C = TOKEN_COUNT -> tokens enqueued since the last clear,
                        // zero-extended to 32 bits. The firmware reads this after a DMA transfer to
                        // learn how many tokens were produced (simple-mode S2MM doesn't report length).
                        s_axi_rdata <= {{(32-TOKEN_W){1'b0}}, tok_count};
                    end
                    default: begin // unreachable (all 4 selector values covered); return 0 defensively.
                        s_axi_rdata <= 32'd0;
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