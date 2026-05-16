`timescale 1ns / 1ps

// ============================================================================
// pre_tokenizer.v
//
// Pre-Tokenizer for FPGA WordPiece Tokenization
// Converts ASCII to alphabet index, detects word boundaries,
// and applies lowercase conversion for BERT base-uncased.
// ============================================================================

module pre_tokenizer #(
    parameter CHAR_W = 10 // 2^10 = 1024 > 997 unique characters in the vocabulary
)(
    input wire clk, // out clock wire
    input wire rst, // our reset wire - provides the reset signal
    
    // Upstream - data that comes from the input FIFO buffer
    input wire [7:0] fifo_data, // raw ascii text (a single character)
    input wire fifo_valid, // a flag which says if the input FIFO buffer has data ready
    output reg fifo_ready, // a flag which says that we are ready to consume that character
    
    // Downstream: to trie engine
    output reg [CHAR_W-1:0] out_char, // drives out the raw ascii text (a single character)
    output reg out_char_valid, // a flag which says that the Pre-Tokenizer has data available for the Trie Engine
    output reg out_word_done, // a flag if 'high' then the character is the final letter in the token
    
    // Backpressure from the trie engine
    input wire trie_ready, // when the trie engine deasserts ready, the pre-tokenizer stops pulling from the FIFO
    output wire word_boundary_busy // an output port for the ack wait state 
);

    // ========================================================================
    // Character Map LUT (ASCII -> alphabet index)
    // Loaded from .mem file. Unmapped chars = 0xFFFF.
    // ========================================================================
     // ram_style="distributed" - telling Vivado to implement a memory array on the FPGA
    (* ram_style = "distributed" *) reg [CHAR_W-1:0] char_map [0:127]; // array of 128 implemented in memory
    
    initial begin
        $readmemh("char_to_index_map.mem", char_map); // read hexadecimal values from .mem file and load to the array
    end
    
    // ========================================================================
    // Internal signals
    // ========================================================================
    // internal state
    reg word_active; // tracks if we are currently inside a word or between words
    // its purpose is to prevent duplicate word_done pulses.
    
    // holding register: stores a mapped character that is ready to be sent
    reg [CHAR_W-1:0] hold_char; // where the mapped character will be stored
    reg hold_valid; // if this flag is 1 - holding register has data for trie
    reg hold_word_done; // if this flag is 1 - holding register has a word_done pulse
    
    reg word_done_ack_wait;  // 1 = waiting for trie to acknowledge word_done
    reg trie_ready_seen_low; // 1 = trie_ready went low after word_done (trie is processing)
    
    reg [2:0] word_done_ack_wait_count;
    
    // Lowercase conversion (combinational)
    // BERT base-uncased requires all text in lowercase.
    // ASCII uppercase A-Z = 0x41-0x5A, add 0x20 to get lowercase.
    // we subtract 32 decimal (20 hex) to convert uppercase to lowecase - BERT limitation
    wire [7:0] lower_byte; // will contain the lowercase character
    // does the lower case conversion
    assign lower_byte = (fifo_data >= 8'h41 && fifo_data <= 8'h5A) ? (fifo_data + 8'h20) : fifo_data;
    
    // Boundary detection (combinational)
    // A "boundary" is any character that separates words.
    // Basically - space, punctuation, control chars etc... IS a boundary.
    wire is_letter_lower = (lower_byte >= 8'h61 && lower_byte <= 8'h7A); // checks if it not a letter
    wire is_digit = (lower_byte >= 8'h30 && lower_byte <= 8'h39); // checks if it is not a digit
    wire is_word_char = is_letter_lower || is_digit; // checks if it is a valid characted
    wire is_boundary_w = ~is_word_char; // if valid character, then it isn't a boundary. Else, it is a boundary.
    
    // we can accept from FIFO buffer (raw ascii -> Pre-Tokenizer)
    // when our holding register is empty, OR when it's about to be drained
    // by the trie engine this cycle
    wire can_accept = !hold_valid || trie_ready;
    
    assign word_boundary_busy = word_done_ack_wait || hold_word_done; // word_boundary_busy is high when the pre-tokenizer is in the middle of handling a word boundary
    
    // ========================================================================
    // Main sequential logic
    // ========================================================================
    always @(posedge clk) begin
        // if reset - we set all reg to 0
        if (rst) begin
            out_char       <= {CHAR_W{1'b0}}; // the output character is cleared
            out_char_valid <= 1'b0; // flag is cleared
            out_word_done  <= 1'b0; // cleared
            fifo_ready     <= 1'b0; // cleared
            word_active    <= 1'b0; // cleared
            hold_char      <= {CHAR_W{1'b0}}; // cleared
            hold_valid     <= 1'b0; // cleared
            hold_word_done <= 1'b0; // cleared
            word_done_ack_wait <= 1'b0; // cleared
            trie_ready_seen_low <= 1'b0; // cleared
            word_done_ack_wait_count <= 3'd0;
         end else begin
            // drive outputs to trie engine
            // defaults: all output pulses are cleared - they only go high when needed.
            out_char_valid <= 1'b0;
            out_word_done  <= 1'b0;
            
            // Word-done acknowledgment state machine
            if (word_done_ack_wait) begin
                if (!trie_ready_seen_low) begin
                    // Phase 1: waiting for trie_ready to go low
                    if (!trie_ready) begin
                        trie_ready_seen_low <= 1'b1;
                    end else if (word_done_ack_wait_count >= 4) begin
                        // Trie never went busy - it handled word_done instantly
                        // Release after a few cycles of grace period
                        word_done_ack_wait  <= 1'b0;
                        trie_ready_seen_low <= 1'b0;
                    end
                end else begin
                    // Phase 2: trie_ready went low, wait for it to come back high
                    if (trie_ready) begin
                        word_done_ack_wait  <= 1'b0;
                        trie_ready_seen_low <= 1'b0;
                    end
                end
            end 
            
            // Counter for ack wait timeout
            if (word_done_ack_wait && !trie_ready_seen_low)
                word_done_ack_wait_count <= word_done_ack_wait_count + 1;
            else
                word_done_ack_wait_count <= 3'd0;
             
            // if trie is ready and we have a character waiting
            if (trie_ready && hold_valid && !hold_word_done && !word_done_ack_wait) begin
               out_char <= hold_char; // we set the outputted char to the character we got
               out_char_valid <= 1'b1; // we set it as valid
               hold_valid <= 1'b0; // we clear the holding register
            end
             
            // if we get a word_done signal (meaning we've reached the end of a word)
            if (hold_word_done) begin
               // word_done doesn't need trie_ready, it is a seperate signal
               out_word_done <= 1'b1; // this is the final letter in the token
               hold_word_done <= 1'b0; // we clear the word_done signal (we've consumed the character!)
               word_done_ack_wait  <= 1'b1;
               trie_ready_seen_low <= 1'b0;
            end
            
            // accept from FIFO and map
            fifo_ready <= can_accept;
            // if the input FIFO buffer isn't empty and we can accept
            if (fifo_valid && can_accept) begin
                // if the character is not a boundary
                if (is_boundary_w) begin
                    // if we are inside a word
                    if (word_active) begin
                        hold_word_done <= 1'b1; // we've reached the end of the word
                        word_active    <= 1'b0; // we reset the flag - we are not inside a word anymore!
                    end
                end else begin
                    hold_char  <= char_map[lower_byte[6:0]]; // we get the next characted from the char_map
                    hold_valid <= 1'b1; // we set so that the holding register is not empty
                    word_active <= 1'b1; // we set so that we are inside a word
                end
            end
        end
    end    
endmodule
