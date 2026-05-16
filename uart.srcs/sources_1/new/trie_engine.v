// ============================================================================
// trie_engine.v
// 
// CSR-based Trie Walker with Binary Search and Zero-Copy Backtracking
// For FPGA WordPiece Tokenization (BERT bert-base-uncased)
//
// ============================================================================

module trie_engine #(
    parameter ROOT_NUM_NODES = 56719, // total nodes in root trie CSR
    parameter ROOT_NUM_EDGES = 56718, // total edges in root trie CSR
    parameter CONT_NUM_NODES = 7864, // total nodes in cont (continuous) trie CSR
    parameter CONT_NUM_EDGES = 7863, // total edges in cont (continuous) trie CSR
    parameter BUF_DEPTH = 32,
    parameter TOKEN_W = 16,
    parameter NODE_W = 17, // max(ROOT_NUM_NODES, CONT_NUM_NODES) needs 17 bits
    parameter EDGE_ADDR_W = 16, // max(ROOT_NUM_EDGES, CONT_NUM_EDGES) needs 16 bits
    parameter CHAR_W = 10
)(
    input  wire clk, // our clock
    input  wire rst, // our reset signal

    // --- Upstream interface (from pre-tokenizer) ---
    input  wire [CHAR_W-1:0] in_char, // mapped index of the current character
    input  wire in_char_valid, // pre-tokenizer has a valid character ready for us
    input  wire in_word_done, // pre-tokenizer signals that is the end of the current word
    output reg ready, // trie engine can accept a new character

    // --- Downstream interface (to token ID output FIFO) ---
    output reg [TOKEN_W-1:0] out_token_id, // the 16 bit result BERT token
    output reg out_token_valid // pulses high when the token is valid
);

    // ========================================================================
    // FSM State Encoding
    // ========================================================================
    localparam [3:0] S_IDLE = 4'd0, // idle state
                     S_ROW_WAIT = 4'd1, // waiting 1 cycle for BRAM to return row_ptr data
                     S_ROW_READ = 4'd2, // reading the row_ptr data BRAM returned
                     S_SEARCH = 4'd3, // computing the next binary seatch midpoint & issue BRAM read
                     S_SEARCH_WAIT = 4'd4, // waiting 1 cycle for BRAM to return edge data
                     S_EVAL = 4'd5, // comparing the edge data we got (index) against the target character (either go left or right)
                     S_TERMINAL_WAIT = 4'd6, // waiting 1 cycle for BRAM to return terminal flag & token ID
                     S_EMIT = 4'd7, // output the matched token ID
                     S_TERM_READ = 4'd8; // read terminal flag and token ID from BRAM

    reg [3:0] state;

    // ========================================================================
    // Root Trie BRAMs
    // ========================================================================
    // Instantiate these arrays in memory
    (* ram_style = "block" *) reg [31:0] root_csr_row_ptr [0:ROOT_NUM_NODES-1];
    (* ram_style = "block" *) reg [31:0] root_csr_edges [0:ROOT_NUM_EDGES-1];
    (* ram_style = "block" *) reg [7:0] root_is_terminal [0:ROOT_NUM_NODES-1];
    (* ram_style = "block" *) reg [TOKEN_W-1:0] root_token_ids [0:ROOT_NUM_NODES-1];

    // copy the contents of the .mem files into the arrays
    initial begin
        $readmemh("root_csr_row_ptr.mem", root_csr_row_ptr);
        $readmemh("root_csr_edges.mem", root_csr_edges);
        $readmemh("root_is_terminal.mem", root_is_terminal);
        $readmemh("root_token_ids.mem", root_token_ids);
    end
    
    // ========================================================================
    // Continuation Trie BRAMs
    // ========================================================================
    // Instantiate these arrays in memory
    (* ram_style = "block" *) reg [31:0] cont_csr_row_ptr [0:CONT_NUM_NODES-1];
    (* ram_style = "block" *) reg [31:0] cont_csr_edges [0:CONT_NUM_EDGES-1];
    (* ram_style = "block" *) reg [7:0] cont_is_terminal [0:CONT_NUM_NODES-1];
    (* ram_style = "block" *) reg [TOKEN_W-1:0] cont_token_ids [0:CONT_NUM_NODES-1];

    // copy the contents of the .mem files into the arrays
    initial begin
        $readmemh("cont_csr_row_ptr.mem", cont_csr_row_ptr);
        $readmemh("cont_csr_edges.mem", cont_csr_edges);
        $readmemh("cont_is_terminal.mem", cont_is_terminal);
        $readmemh("cont_token_ids.mem", cont_token_ids);
    end
    
    // ========================================================================
    // Trie Selection Register
    // ========================================================================
    reg use_root;   // 1 = search root trie (first piece of word)
                    // 0 = search continuation trie (subsequent pieces)
                    // Starts at 1, clears after first token emit,
                    // resets to 1 when word_done arrives

    // ========================================================================
    // BRAM Address Registers (shared - same addresses for both tries)
    // ========================================================================
    reg [NODE_W-1:0] row_rd_addr; // address for row_ptr lookup
    reg [EDGE_ADDR_W-1:0] edge_rd_addr; // address for edge lookup
    reg [NODE_W-1:0] term_rd_addr; // address for terminal and token_id lookup

    // ========================================================================
    // BRAM Read Output Registers (root trie)
    // these hold the data returned from root BRAM 1 clock cycle after the address is set
    // ========================================================================
    reg [31:0] root_row_data; // the packed result of root row_ptr (offset | count) 
    reg [31:0] root_edge_data; // the packed result of root edge (offset | count) 
    reg [7:0] root_terminal_data; // the root terminal flag: 0x01 if node is the end of token 
    reg [TOKEN_W-1:0] root_tid_data; // the root token ID: 16-bit BERT token ID

    // ========================================================================
    // BRAM Read Output Registers (continuation trie)
    // these hold the data returned from continuation BRAM 1 clock cycle after the address is set
    // ========================================================================
    reg [31:0] cont_row_data; // the packed result of cont row_ptr (offset | count) 
    reg [31:0] cont_edge_data; // the packed result of cont edge (offset | count)
    reg [7:0] cont_terminal_data; // the cont terminal flag: 0x01 if node is the end of token
    reg [TOKEN_W-1:0] cont_tid_data; // the cont token ID: 16-bit BERT token ID

    // ========================================================================
    // Synchronous BRAM reads - both tries read every cycle
    // ========================================================================
    always @(posedge clk) begin
        // on each cycle, we read the data from the root trie arrays
        root_row_data <= root_csr_row_ptr[row_rd_addr];
        root_edge_data <= root_csr_edges[edge_rd_addr];
        root_terminal_data <= root_is_terminal[term_rd_addr];
        root_tid_data <= root_token_ids[term_rd_addr];

        // on each cycle, we read the data from the cont trie arrays
        cont_row_data <= cont_csr_row_ptr[row_rd_addr];
        cont_edge_data <= cont_csr_edges[edge_rd_addr];
        cont_terminal_data <= cont_is_terminal[term_rd_addr];
        cont_tid_data <= cont_token_ids[term_rd_addr];
    end

    // ========================================================================
    // Multiplexer: select root or continuation based on use_root
    // The FSM uses these wires instead of accessing BRAMs directly
    // ========================================================================
    // all of these is just conditional selection
    // we set each set of data, depending on use_root (0x01 we take the root, else cont)
    wire [31:0] bram_row_data = use_root ? root_row_data : cont_row_data;
    wire [31:0] bram_edge_data = use_root ? root_edge_data : cont_edge_data;
    wire [7:0] bram_terminal_data = use_root ? root_terminal_data : cont_terminal_data;
    wire [TOKEN_W-1:0] bram_tid_data = use_root ? root_tid_data : cont_tid_data;

    // ========================================================================
    // Trie Walker Registers
    // ========================================================================
    reg [NODE_W-1:0] current_node; // selected node at in the trie
    reg [CHAR_W-1:0] target_char; // the character we are searching for

    // Binary search bounds (absolute indices into csr_edges array)
    reg [EDGE_ADDR_W-1:0] bs_lo; // lower bound of binary search array
    reg [EDGE_ADDR_W-1:0] bs_hi; // upper bound of binary search array

    // Best match tracking
    reg has_best_match; // 1 if we found at least 1 valid token
    reg [TOKEN_W-1:0] best_match_tid; // token ID of the longest match we have found so fat
    reg [4:0] best_end; // buffer position where the best match ends

    // ========================================================================
    // Backtracking Buffer (LUTRAM)
    // ========================================================================
    (* ram_style = "distributed" *) reg [CHAR_W-1:0] char_buf [0:BUF_DEPTH-1];

    reg [4:0] m_start; // start position of current search in buffer
    reg [4:0] scan_ptr; // current scan position during replay
    reg [4:0] buf_end; // next free positionin the buffer

    reg word_active; // 1 if we are currently processing a word
    reg word_done_pending; // latched word_done signal waiting to be handled
    reg replaying; // 1 if we are replaying unconsumed chars from buffer

    // ========================================================================
    // UNK Token ID
    // ========================================================================
    localparam [TOKEN_W-1:0] UNK_TOKEN_ID = 16'd100;
    
    reg [CHAR_W-1:0] pending_char; // tracks the pending character
    reg pending_char_valid; // a flag if the pending character is valid

    // ========================================================================
    // Main FSM
    // ========================================================================
    always @(posedge clk) begin // this block executes on every rising clock edge
        if (rst) begin // if a reset signal is driven
            use_root <= 1'b1;   // first word starts with root trie
            state <= S_IDLE; // FSM starts in idle state
            current_node <= {NODE_W{1'b0}}; // cleared
            ready <= 1'b1; // we set ready=1 meaning the engine can immediately accept characters
            out_token_valid <= 1'b0; // cleared
            out_token_id <= {TOKEN_W{1'b0}}; // cleared
            has_best_match <= 1'b0; // cleared
            best_match_tid <= {TOKEN_W{1'b0}}; // cleared
            best_end <= 5'd0; // cleared
            m_start <= 5'd0; // cleared
            scan_ptr <= 5'd0; // cleared
            buf_end <= 5'd0; // cleared
            word_active <= 1'b0; // cleared
            word_done_pending <= 1'b0; // cleared
            replaying <= 1'b0; // cleared
            target_char <= {CHAR_W{1'b0}}; // cleared
            bs_lo <= {EDGE_ADDR_W{1'b0}}; // cleared
            bs_hi <= {EDGE_ADDR_W{1'b0}}; // cleared
            row_rd_addr <= {NODE_W{1'b0}}; // cleared
            edge_rd_addr <= {EDGE_ADDR_W{1'b0}}; // cleared
            term_rd_addr <= {NODE_W{1'b0}}; // cleared
            pending_char <= {CHAR_W{1'b0}}; // cleared
            pending_char_valid <= 1'b0; // cleared
        end else begin
            out_token_valid <= 1'b0; // for every cycle, we clear the token output pulse
            // out_token_valid is high only when we actually emit a token (So FIFO would not read the same token twice)

            // this block runs every clock cycle
            // if we catch a high pulse of in_word_done when we are busy,
            // (maybe while we're mid-binary-search or backtracking)
            // we can't stop and handle it immediately.
            // so we latch onto word_done_pending as a "sticky" flag.
            // The FSM will check this flag when it's ready (in S_IDLE or S_EMIT).
            // also, we immediately block new characters
            if (in_word_done) begin
                word_done_pending <= 1'b1;
            end

            // handle incoming characters, word_done, boundary characters and replaying
            case (state)
                S_IDLE: begin
                    // is this a word boundary & we're not replaying buffered characters?
                    // in replay mode - instead of reading characters from the pre-tokenizer input
                    // we read from our internal buffer - char_buf
                    // replaying buffered characters - re-processing characters that were
                    // already received and stored in the buffer but weren't consumed by the previous token match
                    if (word_done_pending && !replaying) begin
                        // if we found "best_match" - some valid token was found during traversal
                        if (has_best_match) begin
                            // Capture simultaneous character so it isn't lost
                            if (in_char_valid && ready) begin
                                pending_char       <= in_char;
                                pending_char_valid <= 1'b1;
                            end
                            // Don't clear word_done_pending here - let S_EMIT see it
                            // so it knows to reset use_root for the next word
                            state <= S_EMIT;
                        end else begin
                            // Capture simultaneous character so it isn't lost
                            if (in_char_valid && ready) begin
                                pending_char       <= in_char;
                                pending_char_valid <= 1'b1;
                            end
                            // No best match exists - clean up for next word
                            word_done_pending <= 1'b0;
                            use_root     <= 1'b1;
                            word_active  <= 1'b0;
                            m_start      <= 5'd0;
                            scan_ptr     <= 5'd0;
                            buf_end      <= 5'd0;
                        end

                    // we previously emmited a token but there are leftover characters
                    // in the backtracking buffer that are not from that token.
                    // those are now re-fed into the trie
                    end else if (replaying) begin
                        // Once we finish the "replaying" - all characters have been replayed
                        if (scan_ptr == buf_end) begin
                            replaying <= 1'b0;           // all chars replayed, done
                            // If we found a match during replay, we emit
                            if (word_done_pending) begin
                                word_done_pending <= 1'b0;
                                use_root <= 1'b1;
                                // If we found a match during replay, we emit it
                                if (has_best_match) begin
                                    state <= S_EMIT;
                                end else begin
                                    // if we didn't find a anything, force [UNK] token
                                    best_match_tid <= UNK_TOKEN_ID;
                                    has_best_match <= 1'b1;
                                    best_end       <= buf_end;
                                    state          <= S_EMIT;
                                end
                            end else begin
                                // go back into accepting new characters
                                ready <= 1'b1;           // ready for next character
                            end
                        end else begin
                            // we enter when there are characters left to be replayed
                            // pull next character -> advance scan pointer -> issue BRAM read
                            // -> wait for BRAM
                            target_char  <= char_buf[scan_ptr[4:0]]; // load next buffered char
                            scan_ptr     <= scan_ptr + 1'b1; // advance scan pointer
                            row_rd_addr  <= current_node; // issue row_ptr read for current node
                            state        <= S_ROW_WAIT; // wait for BRAM
                            ready        <= 1'b0; // not ready for new input
                        end

                    // no word_done, not replaying - normal operation
                    // we got a character from Pre-Tokenizer and we are ready for it
                    end else if (in_char_valid && ready) begin
                        // New character arriving from pre-tokenizer
                        word_active  <= 1'b1; // we are now inside a word
                        target_char  <= in_char; // mark the inputted character as the target to search
                        char_buf[buf_end[4:0]] <= in_char; // store remaining characters (not processed yet) in backtracking buffer
                        buf_end      <= buf_end + 1'b1; // advance buffer write pointer
                        row_rd_addr  <= current_node; // issue row_ptr read
                        state        <= S_ROW_WAIT; // wait for BRAM
                        ready        <= 1'b0; // not ready for new input
                    end
                end
                
                // Pure wait state - BRAM is synchronous
                // we put the address on row_rd_addr in the previous cycle,
                // and the BRAM needs this cycle to register the output.
                // Next cycle the data will be valid.
                S_ROW_WAIT: begin
                    state <= S_ROW_READ;   // just wait one cycle, then read the data
                end

                // BRAM data is now valid
                // bram_row_data is 32 bit packed value
                // upper 16 bits = offset (where this node's edges in the edges array)
                // lower 16 bits = count (the amount of edges this node has)
                // if count == 0, then dead end! go to S_EMIT
                S_ROW_READ: begin
                    // we read count - lowe 16 bits
                    if (bram_row_data[15:0] == 16'd0) begin
                        // This node has zero children -> dead end in trie
                        state <= S_EMIT;
                    end else begin
                        // initialize binary search bounds
                        // bs_lo - lower bound
                        // bs_hi - higher bound (last edge index)
                        bs_lo <= bram_row_data[31:16]; // Extract offset (upper 16 bits)
                        bs_hi <= bram_row_data[31:16] + bram_row_data[15:0] - 16'd1; // Find last edge index
                        // Compute first binary search midpoint and issue edge read
                        edge_rd_addr <= bram_row_data[31:16]
                                      + ((bram_row_data[15:0] - 16'd1) >> 1);
                        state <= S_SEARCH_WAIT;   // wait for edge BRAM read
                    end
                end

                // --------------------------------------------------------
                // S_SEARCH: Compute new midpoint after narrowing bounds
                // UNCHANGED
                // --------------------------------------------------------
                S_SEARCH: begin
                    if (bs_lo > bs_hi) begin // if lower bound > upper bound
                        state <= S_EMIT;   // character not found -> jump to S_EMIT
                    end else begin
                        // Compute midpoint and issue edge BRAM read
                        edge_rd_addr <= bs_lo + ((bs_hi - bs_lo) >> 1);
                        state <= S_SEARCH_WAIT; // Go to S_SEARCH_WAIT
                    end
                end

                // We wait 1 cycle BRAM latency for edge read
                S_SEARCH_WAIT: begin
                    state <= S_EVAL;   // just wait one cycle, then evaluate
                end

                // Binary search comparison
                // compare edge character against target character
                S_EVAL: begin
                    if (bram_edge_data[31:17] == target_char) begin // if we found a match
                        // MATCH: character found, move to destination node
                        current_node <= bram_edge_data[NODE_W-1:0];    // update current node
                        term_rd_addr <= bram_edge_data[NODE_W-1:0];    // issue terminal check read
                        state        <= S_TERMINAL_WAIT;               // go to state and wait for result from BRAM read
                    end else if (bram_edge_data[31:17] < target_char) begin // edge character < targer (smaller)
                        // Edge char is smaller -> target is in upper half
                        bs_lo <= edge_rd_addr + 16'd1; // we advance lower bound above the midpoint
                        state <= S_SEARCH; // jump back to S_SEARCH
                    end else begin // edge character > targer (bigger)
                        // Edge char is larger -> target is in lower half
                        bs_hi <= edge_rd_addr - 16'd1; // we reduce higher bound below the midpoint
                        state <= S_SEARCH; // jump back to S_SEARCH
                    end
                end 

                // wait 1 cycle BRAM latency for terminal read (BRAM read for terminal flag and token ID)
                S_TERMINAL_WAIT: begin
                    state <= S_TERM_READ;   // just wait one cycle
                end

                // S_TERM_READ: Read terminal flag and token ID from BRAM
                S_TERM_READ: begin
                    // if the node is terminal (end of a valid token)
                    if (bram_terminal_data != 8'd0) begin
                        // This node IS terminal -> record as best match
                        has_best_match <= 1'b1; // record as best match so far
                        best_match_tid <= bram_tid_data; // save token ID
                        best_end <= replaying ? scan_ptr : buf_end; // save buffer position (where we found the match)
                        // we save this data because if we end up replaying
                        // we keep overwriting best_match_tid as we find longer matches.
                        // If we later hit a dead end, we'll backtrack to this best match.
                    end
                    // If we end up replaying
                    if (replaying) begin
                        state <= S_IDLE; // jump to S_IDLE
                    end else begin
                        // if we are processing a new input 
                        ready <= 1'b1; // ready for new input
                        state <= S_IDLE; // jump to S_IDLE
                    end
                end

                // Output the best-match token ID
                S_EMIT: begin
                    // if we found a valid token to emit (we have a best longest match)
                    if (has_best_match) begin
                        out_token_id    <= best_match_tid; // pulse out_token_id (the token we've found!)
                        out_token_valid <= 1'b1; // pulse a token_valid (We've found a token!)
                        has_best_match  <= 1'b0; // clear best_match since we've consumed it
                        current_node    <= {NODE_W{1'b0}}; // reset current node
                
                        // the best match doesn't contain all of the characters in the buffer
                        // for example - "embedding" matched "em", but Pre-Tokenizer
                        // kept sending characters because we didn't hit a dead end...
                        // "bedding" needs to be replayed
                        if (best_end != buf_end) begin
                            // Unconsumed characters remain -> replay them
                            use_root   <= 1'b0; // continuation trie for remaining pieces (switch to continuation trie)
                            m_start    <= best_end; // m_start pointer is where the longest match ended
                            scan_ptr   <= best_end; // we set the scan pointer to the same position
                            replaying  <= 1'b1; // we set the replaying flag to 1
                            ready      <= 1'b0; // // we set ready flag to 0 because we're are busy replaying and we can't get more characters from Pre-Tokenizer
                            state      <= S_IDLE; // we jump to S_IDLE
                        end else begin
                            // All characters consumed - no need to backtracking (replaying)
                            m_start     <= buf_end; // m_start pointer is where the end of the token
                            scan_ptr    <= buf_end; // scan_ptr pointer to the same position
                            replaying   <= 1'b0; // we are not replaying, so we set 0
                
                            // the word is finished because we hit a boundary
                            if (word_done_pending) begin
                                // Word is finished - reset everything for next word
                                word_done_pending <= 1'b0; // cleared
                                word_active       <= 1'b0; // // cleared
                                use_root <= 1'b1; // next word uses root trie
                                m_start  <= 5'd0; // cleared
                                scan_ptr <= 5'd0; // cleared
                                buf_end  <= 5'd0; // cleared
                                
                                if(pending_char_valid) begin
                                    // A character from the next word was captured — process it now
                                    word_active        <= 1'b1;
                                    target_char        <= pending_char;
                                    char_buf[0]        <= pending_char;
                                    buf_end            <= 5'd1;
                                    row_rd_addr        <= {NODE_W{1'b0}};  // root node 0
                                    pending_char_valid <= 1'b0;
                                    ready    <= 1'b0; // not ready - we're processing pending char
                                    state    <= S_ROW_WAIT; // go process it through the trie
                                end else begin
                                    ready    <= 1'b1; // we are ready for a new character
                                    state    <= S_IDLE; // jump to S_IDLE
                                end
                            end
                        end                                            
                    // no match was ever found
                    // the entire word couldn't be tokenized at all...
                    // emit [UNK]
                    end else begin                        
                        out_token_id    <= UNK_TOKEN_ID; // No match at all -> emit [UNK]
                        out_token_valid <= 1'b1; // token [UNK] is valid
                        has_best_match  <= 1'b0; // cleared
                        current_node    <= {NODE_W{1'b0}}; // cleared
                        word_active     <= 1'b0; // cleared
                        use_root        <= 1'b1; // we move to the root trie
                        m_start         <= 5'd0; // cleared
                        scan_ptr        <= 5'd0; // cleared
                        buf_end         <= 5'd0; // cleared
                        replaying       <= 1'b0; // cleared
                        ready           <= 1'b1; // ready
                        state           <= S_IDLE; // jump to S_IDLE
                    end
                end 

                // safety net: if FSM is corrupted, we move to S_IDLE by default
                default: begin
                    state <= S_IDLE;
                end

            endcase
        end
    end

endmodule