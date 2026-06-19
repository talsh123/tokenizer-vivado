// trie_engine.v
// this module is the brain of our project. it implements the WordPiece algorithm in hardware.
// it receives mapped alphabet indices from the Pre-Tokenizer and produces BERT token IDs.

module trie_engine #(
    // parameter section
    parameter ROOT_NUM_NODES = 56719, // total nodes in the root trie - taken from python output
    parameter ROOT_NUM_EDGES = 56718, // total edges in the root trie - taken from python output
    parameter CONT_NUM_NODES = 7864, // total nodes in the continuation trie - taken from python output
    parameter CONT_NUM_EDGES = 7863, // total edges in the continuation trie - taken from python output
    // edges = nodes - 1, this is logical because edges will always be 1 less than the num of nodes
    parameter BUF_DEPTH = 32, // the backtracking buffer which holds 32 character. fine because the longest token in BERTs vocabulary is ~28 characters
    parameter TOKEN_W = 16, // the token IDs consist of 16 bits -> 65,535 >> 30,522 BERT's token limit
    parameter NODE_W = 17, // node IDs are 17 bits wide, 2^17 = 131,072 >> 56,719 maximum node count from the python output
    parameter EDGE_ADDR_W = 16, // edge array addresses are 16 bits, 2^16 = 65,536 > 56,718 maximum edge count from the python output
    parameter CHAR_W = 10 // 10 bits of the alphabet index, 2^10 = 1024 > ~1008 unique characters
)(
    // inputs and outputs section
    input wire clk, // clk_100 100 MHz clock
    input wire rst, // synchronous active-high reset

    // upstream - data which comes from the pre-tokenizer
    input wire [CHAR_W-1:0] in_char, // the 10-bit mapped alphabet index
    input wire in_char_valid, // a flag which indicates 1 where the pre-tokenizer has a character ready for us
    input wire in_word_done, // a flag which indicated 1 where the pre-tokenizer has a word boundary
    output reg ready, // this goes back to the pre-tokenizer - a flag which indicates 1 if the trie engine is free to accept new characters or 0 if it is busy.

    // downstream - to the output FIFO in tokenizer_axi_lite.v
    output reg [TOKEN_W-1:0] out_token_id, // the 16-bit result BERT token
    output reg out_token_valid // a signal which pulses HIGH when a token is being emitted
);

    // FSM (finite state machine) encoding
    // localparam means a compile-time constants, they are not represented in the hardware
    // we use 4 bits to represent 10 states
    localparam [3:0] S_IDLE = 4'd0,
                     S_ROW_WAIT = 4'd1,
                     S_ROW_READ = 4'd2,
                     S_CALC_MID = 4'd3,
                     S_SEARCH_WAIT = 4'd4,
                     S_EVAL = 4'd5,
                     S_SEARCH = 4'd6,
                     S_TERMINAL_WAIT = 4'd7,
                     S_TERM_READ = 4'd8,
                     S_EMIT = 4'd9;

    reg [3:0] state; //  a 4-bit flip-flop that holds the current FSM state

    // root-trie bram declarations
    // the following lines instantiate 4 BRAM arrays to hold the data from the .mem files
    // "block" tells Vivado to implement this is BRAM instead of LUTRAM.
    // instantiate these arrays in memory
    (* ram_style = "block" *) reg [31:0] root_csr_row_ptr [0:ROOT_NUM_NODES-1]; // array for root row_ptr
    (* ram_style = "block" *) reg [31:0] root_csr_edges [0:ROOT_NUM_EDGES-1]; // array for root edges
    (* ram_style = "block" *) reg [7:0] root_is_terminal [0:ROOT_NUM_NODES-1]; // array for root is_terminal
    (* ram_style = "block" *) reg [TOKEN_W-1:0] root_token_ids [0:ROOT_NUM_NODES-1]; // array for root token_ids

    // at synthesis, this line hardcodes the hexadecimal values from the .mem files to their respective arrays
    initial begin
        $readmemh("root_csr_row_ptr.mem", root_csr_row_ptr);
        $readmemh("root_csr_edges.mem", root_csr_edges);
        $readmemh("root_is_terminal.mem", root_is_terminal);
        $readmemh("root_token_ids.mem", root_token_ids);
    end
    
    // continuation-trie bram declarations
    // the following lines instantiate 4 BRAM arrays to hold the data from the .mem files
    // "block" tells Vivado to implement this is BRAM instead of LUTRAM.
    // instantiate these arrays in memory
    (* ram_style = "block" *) reg [31:0] cont_csr_row_ptr [0:CONT_NUM_NODES-1]; // array for continuation row_ptr
    (* ram_style = "block" *) reg [31:0] cont_csr_edges [0:CONT_NUM_EDGES-1]; // array for continuation edges
    (* ram_style = "block" *) reg [7:0] cont_is_terminal [0:CONT_NUM_NODES-1]; // array for continuation is_terminal
    (* ram_style = "block" *) reg [TOKEN_W-1:0] cont_token_ids [0:CONT_NUM_NODES-1]; // array for continuation token_ids

    // at synthesis, this line hardcodes the hexadecimal values from the .mem files to their respective arrays
    initial begin
        $readmemh("cont_csr_row_ptr.mem", cont_csr_row_ptr);
        $readmemh("cont_csr_edges.mem", cont_csr_edges);
        $readmemh("cont_is_terminal.mem", cont_is_terminal);
        $readmemh("cont_token_ids.mem", cont_token_ids);
    end
    
    // trie selection register - we choose which trie to use
    reg use_root; // this bit selects which trie is active: 1 - root trie, 0 - continuation trie
    // it first starts at 1, emits the longest match word-initial token
    // and switches to 0 and emits the middle/end tokens of the word.
    // resets to 1 when word_done arrives.

    // BRAM address registers
    reg [NODE_W-1:0] row_rd_addr; // this register hold the address for row_ptr lookup
    reg [EDGE_ADDR_W-1:0] edge_rd_addr; // this register hold the address for edge lookup
    reg [NODE_W-1:0] term_rd_addr; // this register hold the address for terminal and token_id lookup
    // these address registers are shared between the root and continuation tries

    // 4 registers that hold the BRAM read results - for the root trie
    // these hold the data returned from root BRAM 1 clock cycle after the address is set
    // this is the 1st set - because both tries are read simultaneously every cycle
    reg [31:0] root_row_data; // root row_ptr (offset | count) 
    reg [31:0] root_edge_data; // root edge (character index | destination node)
    reg [7:0] root_terminal_data; // root terminal flag: 0x01 if terminal node, 0x00 otherwise 
    reg [TOKEN_W-1:0] root_tid_data; // root token ID: 16-bit BERT token ID

    // 4 registers that hold the BRAM read results - for the continuation trie
    // these hold the data returned from continuation BRAM 1 clock cycle after the address is set
    // this is the 2nd set - because both tries are read simultaneously every cycle
    reg [31:0] cont_row_data; // continuation row_ptr (offset | count) 
    reg [31:0] cont_edge_data; // continuation edge ((character index | destination node)
    reg [7:0] cont_terminal_data; // continuation terminal flag: 0x01 if terminal node, 0x00 otherwise
    reg [TOKEN_W-1:0] cont_tid_data; // continuation token ID: 16-bit BERT token ID

    // synchronous BRAM read block
    // this block reads from both of the tries at their respective current addresses
    // this is because use_root (the register which chooses which trie we are using) might change
    // by reading both tries every cycle, when use_root changes, the mux can switch immediately using already-registered data, avoiding an extra wait cycle
    // also, the <= operator means the data will be available only at the next clock cycle
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

    // muxes: four 2 to 1 multiplexers
    // the multiplexers do not access the arrays directly - they use the registers we've defined
    // depending on use_root, we know which register to choose
    wire [31:0] bram_row_data = use_root ? root_row_data : cont_row_data;
    wire [31:0] bram_edge_data = use_root ? root_edge_data : cont_edge_data;
    wire [7:0] bram_terminal_data = use_root ? root_terminal_data : cont_terminal_data;
    wire [TOKEN_W-1:0] bram_tid_data = use_root ? root_tid_data : cont_tid_data;

    // trie walker registers
    reg [NODE_W-1:0] current_node; // holds the current node we're traversing in the trie. always starts at the root (node 0).
    reg [CHAR_W-1:0] target_char; // holds the alphabet index we are searching for in the binary search

    // binary search bounds
    reg [EDGE_ADDR_W-1:0] bs_lo; // lower bound of the binary search
    reg [EDGE_ADDR_W-1:0] bs_hi; // upper bound of the binary search

    // best match tracking - this is to find the longest-matching token in the root trie (word-initial pieces of a word)
    // these registers update every time a terminal node it hit
    reg has_best_match; // 1 - at least 1 valid token was found, 0 - no valid tokens were found
    reg [TOKEN_W-1:0] best_match_tid; // this holds the token ID of the longest match we have found so far
    reg [4:0] best_end; // the position of where the longest-matching token ends

    // backtracking buffer
    // this line declares a 32-entry array, each entry 10 bits wide.
    // "distributed" tells Vivado to implement this is LUTRAM instead of BRAM.
    // this is a small array (32 x 10 = 320 bits) and LUTRAM provides combinational read access:
    // meaning address comes in and data comes out in the same clock cycle with no delay. BRAM requires a 1 cycle latency.
    // this array stores the characters that come from the pre-tokenizer.
    // when backtracking is needed, characters are replayed from this buffer without needing to re-read the input FIFO.
    (* ram_style = "distributed" *) reg [CHAR_W-1:0] char_buf [0:BUF_DEPTH-1];

    // 3 pointers to manage the character buffer, all are 5 bits, 2^5 = 32 values
    reg [4:0] m_start; // this is the start position of the current token search within the buffer.
    reg [4:0] scan_ptr; // when backtracking, this is the read pointer. it starts at m_start and finished at scan_ptr = buf_end
    reg [4:0] buf_end; // this is the write pointer, it writes to a free empty slot.

    
    reg word_active; // 1 - signals we are currently processing a word, otherwise 0
    reg word_done_pending; // this "saves" the state of the in_word_done signal from the pre-tokenizer.
    // because the in_word_done pulses for only 1 clock cycle and resets, we "save" and hold it until the FSM can handle it.
    reg replaying; // 1 if the engine is replaying buffered characters after a backtrack.
    // during replay, the engine reads from char_buf instead from the pre-tokenizer input and ready stays at 0 to prevent from new characters to come in.

    // UNK Token ID
    localparam [TOKEN_W-1:0] UNK_TOKEN_ID = 16'd100; // a local parameter which represents the unknown token [UNK] - token ID 100
    
    reg [CHAR_W-1:0] pending_char; // tracks the pending character
    reg pending_char_valid; // a flag if the pending character is valid

    // main FSM - the sequential logic
    always @(posedge clk) begin // this block executes on every rising clock edge
        if (rst) begin // on reset - everything zeros out except use_root = 1, we default to selecting the root trie
            use_root <= 1'b1;   // we default to selecting the root trie
            state <= S_IDLE; // FSM starts in idle state
            current_node <= {NODE_W{1'b0}}; // cleared
            ready <= 1'b1; // we set ready = 1, meaning the engine can immediately accept characters
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
            // drive output to output FIFO.
            // every cycle, out_token_valid default to 0.
            // we make them HIGH when a token is actually emitted in S_EMIT.
            // this guarantees they are HIGH for only 1 clock cycle and so the output FIFO would not read the same token twice
            // even if we set out_token_valid here to 0 using <= and later we set it to 1 using <=, only the last assignment wins.
            out_token_valid <= 1'b0; // for every cycle, we clear the token output pulse

            // this block runs every clock cycle, regardless of the fsm state
            // whenever in_word_done is HIGH, word_done_pending "saves" the state of the in_word_done signal from the pre-tokenizer.
            // because the in_word_done pulses for only 1 clock cycle and resets, we "save" and hold it until the FSM can handle it.
            // if we catch a high pulse of in_word_done when we are busy,
            // (maybe while we're mid-binary-search or backtracking)
            // we can't stop and handle it immediately.
            // so we latch onto word_done_pending as a "sticky" flag.
            // The FSM will check this flag when it's ready (in S_IDLE or S_EMIT).
            // also, we immediately block new characters
            if (in_word_done) begin
                word_done_pending <= 1'b1;
            end

            // the fsm different states
            case (state)
                S_IDLE: begin // S_IDLE state
                    // if a word boundary is pending and we are not replaying (backtracking)
                    if (word_done_pending && !replaying) begin
                        // if we have a best_match - meaning a valid token was found while traversing the characters of this word
                        if (has_best_match) begin
                            // capture another character so the is isn't lost
                            // this is an edge case - the pre-tokenizer might send the first character of the next word on the same cycle as word_done
                            if (in_char_valid && ready) begin // if the pre-tokenizer has a character ready for us and we can accept it
                                pending_char <= in_char; // we track the pending character
                                pending_char_valid <= 1'b1; // we set the character as valid 
                            end
                            // go to S_EMIT to output the token
                            // we deliberately do NOT clear word_done_pending here - S_EMIT needs to see it to know it should reset use_root for the next word.
                            state <= S_EMIT;
                        end else begin // if we don't have a best match
                            // the word ended but no valid token was found
                            if (in_char_valid && ready) begin
                                pending_char <= in_char; // track any pending character
                                pending_char_valid <= 1'b1; // we set the character as valid 
                            end
                            // in this path the word ended and no valid token was found
                            // no token is emitted here - effectively the word is silently dropped
                            word_done_pending <= 1'b0; // clear the pending flag
                            // reset everything to the next word
                            use_root     <= 1'b1; // cleared
                            word_active  <= 1'b0; // cleared
                            m_start      <= 5'd0; // cleared
                            scan_ptr     <= 5'd0; // cleared
                            buf_end      <= 5'd0; // cleared
                        end

                    // we emitted the longest-best-matching token but there are more characters
                    // so right now we are in replay (backtracking) mode
                    end else if (replaying) begin
                        // if the pointers of the scanning character and the end of the backtracking buffer match
                        // effectively meaning that all characters have been replayed
                        if (scan_ptr == buf_end) begin
                            replaying <= 1'b0; // we set the replaying flag to 0, indicating we finished replaying
                            // if we finished the entire word
                            if (word_done_pending) begin
                                // H1 FIX: word_done_pending is intentionally NOT cleared here. S_EMIT is the
                                // single owner of this flag and finalizes the word. Clearing it early made
                                // S_EMIT's (best_end==buf_end) branch skip finalization -- holding the FSM
                                // in S_EMIT and emitting a spurious [UNK] (token 100); and on the
                                // (best_end!=buf_end) path it dropped the final continuation piece.
                                // Leave it set -- S_EMIT clears it (~line 415). 
                                use_root <= 1'b1; // we initialize the use_root to use the root trie for the next word
                                // If we found a match during replay, we emit what we have (best match or [UNK])
                                if (has_best_match) begin
                                    state <= S_EMIT; // go to S_EMIT
                                end else begin
                                    // if we didn't find a anything, force [UNK] token
                                    best_match_tid <= UNK_TOKEN_ID; // set the best match as the [UNK] token ID 100
                                    has_best_match <= 1'b1; // we set the best match flag to 1, indicating we have a best match token
                                    best_end <= buf_end; // we set the position of the longest matching token as the end of the backtracking buffer
                                    state <= S_EMIT; // we go to S_EMIT
                                end
                            end else begin
                                // we set the ready flag to 1, indicating we are ready to get more character
                                ready <= 1'b1; // ready for next character
                            end
                        end else begin
                            // we enter this path where scan_ptr != buf_end
                            // meaning there are more characters to replay
                            target_char <= char_buf[scan_ptr[4:0]]; // get the next character from the character buffer, at index scan_ptr
                            scan_ptr <= scan_ptr + 1'b1; // advance the scan_ptr pointer
                            row_rd_addr <= current_node; // set the current node as the row we need to read from the BRAM
                            state <= S_ROW_WAIT; // we move to S_ROW_WAIT, waiting for the BRAM to return the node
                            ready <= 1'b0; // ready stays 0 because we're still busy replaying
                        end

                    // this is the normal operation - meaning there is no word_done, and we aren't backtracking
                    end else if (in_char_valid && ready) begin
                        word_active  <= 1'b1; // we set the word_active flag to 1, indicating we are inside a word
                        target_char  <= in_char; // we mark the inputted character as the target to search
                        char_buf[buf_end[4:0]] <= in_char; // storing the incoming character in the backtracking buffer
                        buf_end <= buf_end + 1'b1; // advance the write pointer
                        row_rd_addr <= current_node; // issue the BRAM read for the current node (which we copy to the row we look for)
                        state <= S_ROW_WAIT; // go to S_ROW_WAIT, waiting for the BRAM read
                        ready <= 1'b0; // not ready for new input
                    end
                end
                
                // S_ROW_WAIT is a pure wait state
                // we wait 1 clock cycle for the BRAM to read the node at the row_rd_addr and return it
                // on the next cycle, the data will be valid.
                S_ROW_WAIT: begin
                    state <= S_ROW_READ; // wait one cycle, then jump to S_ROW_READ to read the data
                end

                // now BRAM data is now valid and can be read
                // bram_row_data is 32 bit value (offset (16) | count (16))
                // if count == 0, then we got a dead end -> go to S_EMIT
                S_ROW_READ: begin
                    // we check if count (lower 16 bits) are 0, the node is a leaf, so dead end. go to S_EMIT.
                    if (bram_row_data[15:0] == 16'd0) begin
                        state <= S_EMIT; // go to S_EMIT
                    end else begin // if count != 0, set up the binary search bounds
                        bs_lo <= bram_row_data[31:16]; // offset will be the lowest bound
                        bs_hi <= bram_row_data[31:16] + bram_row_data[15:0] - 16'd1; // offset + count - 1 will be the highest bound
                        state <= S_CALC_MID;  // go to S_CALC_MID to compute the midpoint of the binary search
                    end  
                end
                
                S_CALC_MID: begin // this state computes the binary search midpoint
                    edge_rd_addr <= bs_lo + ((bs_hi - bs_lo) >> 1); // standard midpoint calculation which prevents integer overflow
                    // (bs_lo + bs_hi) / 2 could overflow, and the >> 1 basically does division by 2.
                    // so at the end, edge_rd_addr holds the midpoint
                    state <= S_SEARCH_WAIT; // go to S_SEARCH_WAIT, issue a BRAM read of the middle point
                end
                
                // S_SEARCH: Compute new midpoint after narrowing bounds
                S_SEARCH: begin // compute the new midpoint after narrowing the bs_lo and bs_hi bounds
                    if (bs_lo > bs_hi) begin // checks if the the lower bound > higher bound. if so, we exceeded the bounds and no character was found
                        state <= S_EMIT;   // no character was found, so we just to S_EMIT, emit what we have
                    end else begin // if we didn't finish the search yet, we compute the new midpoint
                        edge_rd_addr <= bs_lo + ((bs_hi - bs_lo) >> 1); // standard midpoint calculation which prevents integer overflow
                        // (bs_lo + bs_hi) / 2 could overflow, and the >> 1 basically does division by 2.
                        state <= S_SEARCH_WAIT; // Go to S_SEARCH_WAIT, issue another BRAM READ
                    end
                end

                S_SEARCH_WAIT: begin // a pure wait state, waiting for BRAM read for the edge data
                    state <= S_EVAL;   // wait one cycle, then jump to S_EVAL to evaluate if we found the node
                end
                           
                S_EVAL: begin // S_EVAL is the core of the binary search comparison
                    // bram_edge_data is 32-bit value (character index (15) | destination node ID (17))
                    if (bram_edge_data[31:17] == target_char) begin // if we found the character in the binary search
                        current_node <= bram_edge_data[NODE_W-1:0]; // update the current node to the destination node
                        term_rd_addr <= bram_edge_data[NODE_W-1:0]; // set the terminal address to the same destination address to check if it is terminal
                        state <= S_TERMINAL_WAIT; // go to S_TERMINAL_WAIT to check if the node is terminal and the token ID
                    end else if (bram_edge_data[31:17] < target_char) begin // if the edge character < target (smaller)
                        // the target is in the upper half
                        bs_lo <= edge_rd_addr + 16'd1; // we set the lower bound 1 above the current midpoint
                        state <= S_SEARCH; // go to S_SEARCH to compute the new midpoint after we narrowed it down
                    end else begin // if the edge character > target (greater)
                        // the target is in the lower half [bs_lo, edge_rd_addr-1].
                        // H2 FIX: if the midpoint is already at the low bound, that lower half
                        // is empty -> the character is absent. Computing edge_rd_addr-1 here would
                        // underflow when edge_rd_addr==0 (only possible at a node whose edges start
                        // at offset 0, i.e. node 0): bs_hi would wrap to 0xFFFF, the (bs_lo > bs_hi)
                        // guard in S_SEARCH would fail, and the search would read out-of-range edges.
                        // Treat it as not-found instead (also avoids one extra search iteration).
                        if (edge_rd_addr == bs_lo) begin
                            state <= S_EMIT; // lower half empty -> character not found, emit what we have
                        end else begin
                            bs_hi <= edge_rd_addr - 16'd1; // we set the higher bound 1 below the current midpoint
                            state <= S_SEARCH; // go to S_SEARCH to compute the new midpoint after we narrowed it down
                        end
                    end
                end 

                // wait 1 cycle BRAM latency for terminal read (BRAM read for terminal flag and token ID)
                S_TERMINAL_WAIT: begin // a pure wait state, wait for BRAM to read is_terminal and token_ids data at term_rd_addr.
                    state <= S_TERM_READ; // go to S_TERM_READ to read the is_terminal flag and token_ids data
                end

                S_TERM_READ: begin // S_TERM_READ reds the is_terminal and token_ids data at term_rd_addr
                    if (bram_terminal_data != 8'd0) begin // if the node is terminal, meaning it is the end of a token
                        // This node IS terminal -> record as best match
                        has_best_match <= 1'b1; // set has_best_match to 1 indicating we have a best match
                        best_match_tid <= bram_tid_data; // update the best match token
                        best_end <= replaying ? scan_ptr : buf_end; // the buffer position on the mode
                        // if we are in normal operation (not backtracking) - set best_end to the end of the character buffer (buf_end)
                        // if we are in backtracking - set best_end to the scan_ptr pointer position (could be the middle of a word token, not the end yet)
                        // best_end indicates in S_EMIT if we have more characters we haven't consumed yet
                    end
                    // if we are replaying, do not enable the ready signal. we are not ready to receive new character.
                    if (replaying) begin
                        state <= S_IDLE; // jump back to S_IDLE
                    end else begin // if we aren't replaying
                        ready <= 1'b1; // enable the ready signal, signaling we are ready to receive new characters.
                        state <= S_IDLE; // jump back to S_IDLE
                    end
                end

                S_EMIT: begin // in this state we emit the best match token or [UNK] token ID 100
                    // if we found best match (best longest-matching token)
                    if (has_best_match) begin
                        out_token_id <= best_match_tid; // we set the out_token_id (the token id which goes to the output FIFO) as the best matching token we've found
                        out_token_valid <= 1'b1; // we set out_token_valid flag to 1, indicating we've found a token
                        has_best_match <= 1'b0; // clear the has_best_match flag since we've finished emitting it
                        current_node <= {NODE_W{1'b0}}; // reset the current node to 0 (root node in the trie)
                
                        // this is the backtracking path
                        // this is where we started backtracking and we found a token (such as in the middle of a word)
                        // the pointer which points to the end of the token we've found is not at the end of the character buffer
                        // meaning there are still characters to be consumed!
                        if (best_end != buf_end) begin
                            use_root <= 1'b0; // we switch use_root to use the continuation trie for the remaining characters
                            m_start <= best_end; // m_start pointer points to where the best longest matching token ended
                            scan_ptr <= best_end; // scan_ptr pointer points to where the best longest matching token ended
                            replaying <= 1'b1; // we set the replaying flag to 1, indicating we are in backtracking mode
                            ready <= 1'b0; // we are busy replaying so we set ready flag to 0, indicating we are not ready to receive more characters
                            state <= S_IDLE; // we jump to S_IDLE
                        end else begin // the best longest-matching token consumed all of the characters in the character buffer
                            m_start <= buf_end; // m_start pointer points to the end of the character buffer
                            scan_ptr <= buf_end; // scan_ptr pointer points to the end of the character buffer
                            replaying <= 1'b0; // we are not replaying, so we set 0
                
                            if (word_done_pending) begin // if consumed everything and we hit a word boundary
                                word_done_pending <= 1'b0; // cleared
                                word_active <= 1'b0; // cleared
                                use_root <= 1'b1; // set use_root to 1, indicating that for the next word we use the root trie
                                m_start <= 5'd0; // cleared
                                scan_ptr <= 5'd0; // cleared
                                buf_end <= 5'd0; // cleared
                                
                                if(pending_char_valid) begin // immediately check if a character from the next word was captured earlier
                                    word_active <= 1'b1; // we set the word_active flag to 1, indicating that we are in the middle of a word
                                    target_char <= pending_char; // set the target character to search for from the incoming character
                                    char_buf[0] <= pending_char; // set the first character of the character buffer as the incoming character
                                    buf_end <= 5'd1; // sets the pointer to the end of the buffer to 1
                                    row_rd_addr <= {NODE_W{1'b0}}; // set the address row to the root node 0
                                    pending_char_valid <= 1'b0; // set the pending character flag to 0 because we've consumed it
                                    ready    <= 1'b0; // not ready - we're processing pending char
                                    state    <= S_ROW_WAIT; // go process it through the trie
                                end else begin // if there is no pending character
                                    ready <= 1'b1; // set the ready flag to 1, indicating we are ready for a new character
                                    state <= S_IDLE; // jump to S_IDLE
                                end
                            end else begin
                                // H1 FIX (defensive): every branch must assign a next state. With the
                                // premature word_done_pending clear removed above, reaching here -- a
                                // match consumed the whole buffer with no word boundary pending -- is
                                // not expected; return to a safe IDLE rather than holding S_EMIT.
                                ready <= 1'b1;
                                state <= S_IDLE;
                            end
                        end                                            
                    
                    // no match was ever found, the entire word couldn't be tokenized, emit [UNK] token ID 100
                    end else begin                        
                        out_token_id <= UNK_TOKEN_ID; // set the outputted token to [UNK]
                        out_token_valid <= 1'b1; // we set that we've outputted a token
                        has_best_match <= 1'b0; // cleared
                        current_node <= {NODE_W{1'b0}}; // cleared - point to node 0 (root node)
                        word_active <= 1'b0; // cleared
                        use_root <= 1'b1; // for the next word, we use the root trie
                        m_start <= 5'd0; // cleared
                        scan_ptr <= 5'd0; // cleared
                        buf_end  <= 5'd0; // cleared
                        replaying <= 1'b0; // cleared
                        ready <= 1'b1; // set the ready flag to 1, indicating we are ready for a new character 
                        state <= S_IDLE; // jump to S_IDLE
                    end
                end 

                // safety net. if the fsm state register (state) gets corrupted, we fall into IDLE
                default: begin
                    state <= S_IDLE;
                end

            endcase
        end
    end
endmodule