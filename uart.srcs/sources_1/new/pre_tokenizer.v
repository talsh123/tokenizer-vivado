`timescale 1ns / 1ps // simulation time resolution: 1ns - time unit, 1ps - precision

// pre_tokenizer.v
// description:
// The Pre-Tokenizer sits between the input FIFO (tokenizer_axi_lite.v) and the trie engine (trie_engine.v).
// The main purpose of the Pre-Tokenizer is to take the raw ASCII bytes and prepare them for the trie engine.
// The 3 functions of the Pre-Tokenizer:
// 1. Lowercase conversion
// 2. Character Mapping
// 3. Word Boundary Detection

module pre_tokenizer #(
    // parameter section
    parameter CHAR_W = 10 // 10 bits of the alphabet index, 2^10 = 1024 > ~1008 unique characters
)(
    // inputs and outputs section
    input wire clk, // clk_100 100 MHz clock
    input wire rst, // synchronous active-high reset
    
    // upstream - data that comes from FIFO - which comes before the pre-tokenizer
    input wire [7:0] fifo_data, // 8 bits of raw ascii text (a single character)
    input wire fifo_valid, // a flag which says if the input FIFO buffer has a byte available for us
    output reg fifo_ready, // a flag which says that we are ready to consume that character
    
    // downstream - data that is being sent down to the trie engine - which comes after the pre-tokenizer
    output reg [CHAR_W-1:0] out_char, // this is the mapped alphabet index (10 bits)
    output reg out_char_valid, // a flag which pulses HIGH for 1 cycle when a character is ready
    output reg out_word_done, // a flag which pulses HIGH when a word boundary is detected
    
    // from Downstream to us - from the trie engine (backpressure)
    input wire trie_ready, // when trie_ready turns to 0, the trie is busy and can't accept new characters.
    output wire word_boundary_busy, // this goes out to the tokenizer_axi_lite - stops the input FIFO from sending new characters while the trie engine is still processing word boundary

    // tells the rest of the pipeline that the pre-tokenizer still has work in flight
    // (a character held for the trie, a pending word boundary, or a pulse being driven this cycle).
    // used by top_tokenizer to build the overall pipeline-busy status the firmware polls.
    output wire pt_busy
);

     // this line declares a 128-entry array, each entry 10 bits wide.
     // "distributed" tells Vivado to implement this is LUTRAM instead of BRAM.
     // this is a small array (128 x 10 = 1,280 bits) and LUTRAM provides combinational read access:
     // meaning address comes in and data comes out in the same clock cycle with no delay. BRAM requires a 1 cycle latency. 
    (* ram_style = "distributed" *) reg [CHAR_W-1:0] char_map [0:127]; // array of 128 implemented in memory
    
    // at synthesis, this line hardcodes the hex values of the indexes to the array we've just created.
    initial begin
        $readmemh("char_to_index_map.mem", char_map); // read hexadecimal values from .mem file and load to the array
    end
    
    // internal state registers
    
    // tracks if we are currently inside a word.
    // 1 - when a letter/digit arrives, 0 - when a word boundary arrives.
    // This is to prevent sending duplicate word_done (HIGH) signals for multiple boundaries in a row.
    reg word_active;
    
    reg [CHAR_W-1:0] hold_char; // stores the mapped alphabet index
    reg hold_valid; // a flag which indicates that a character is waiting to be sent to the trie engine and the holding register is full.
    // 1 - holding register has data for trie, 0 - empty holding register 
    reg hold_word_done; // a flag which indicates that a word boundary needs to be signaled
    // 1 - a word_done signal needs to be sent, otherwise 0

    // lowercase conversion (combinational) - add 0x20 to convert uppercase to lowercase
    wire [7:0] lower_byte; // lower_byte will contain the lowercase letter
    // checks if it is between 41 hex to 5A hex (A - Z). if so, add 20 hex, otherwise keep as is.
    assign lower_byte = (fifo_data >= 8'h41 && fifo_data <= 8'h5A) ? (fifo_data + 8'h20) : fifo_data;    
    
    // boundary detection (combinational)
    wire is_letter_lower = (lower_byte >= 8'h61 && lower_byte <= 8'h7A); // checks if it is between 61 hex to 7A hex (a - z). 1 if yes, 0 if no.
    wire is_digit = (lower_byte >= 8'h30 && lower_byte <= 8'h39); // checks if it is between 30 hex to 39 hex (0 - 9). 1 if yes, 0 if no.
    wire is_word_char = is_letter_lower || is_digit; // checks if it is a valid character - meaning either a letter or a digit. 1 - if yes, 0 - if no.
    wire is_boundary_w = ~is_word_char; // if it is not a word character, then it is a boundary.
    
    // this is the acceptance condition from the FIFO (take a byte from the FIFO)
    //1 - if the holding register is empty OR the trie engine is ready to receive new characters, otherwise 0.
    wire can_accept = !hold_valid || trie_ready;
    
    // this is the signal that is being sent to tokenizer_axi_lite.v which prevents new bytes from being presented from the FIFO while a word boundary is being handed to the trie engine.
    // 1 only while a word boundary is held waiting to be sent; the trie engine's own ready line provides all other backpressure.
    assign word_boundary_busy = hold_word_done;

    // high whenever the pre-tokenizer still has work in flight: a character held for the
    // trie, a word boundary held, or either output pulse being driven this cycle. the
    // out_* pulse terms close the one-cycle gap while data is in flight to the trie engine.
    assign pt_busy = hold_valid || hold_word_done || out_char_valid || out_word_done;
    
    // the sequential logic
    always @(posedge clk) begin
        // on reset - everything zeros out
        if (rst) begin
            out_char       <= {CHAR_W{1'b0}}; // replicate bit 0 CHAR_W times, produces a 10-bit 0 value.
            out_char_valid <= 1'b0; // cleared.
            out_word_done  <= 1'b0; // cleared.
            fifo_ready     <= 1'b0; // cleared. it also starts at 0, meaning we do not accept data during reset.
            word_active    <= 1'b0; // cleared.
            hold_char      <= {CHAR_W{1'b0}}; // cleared
            hold_valid     <= 1'b0; // cleared
            hold_word_done <= 1'b0; // cleared
         end else begin
            // drive outputs to trie engine.
            // every cycle, out_char_valid and out_word_done default to 0.
            // we make them HIGH only when needed depending on the condition, and that guarantees they are HIGH for only 1 clock cycle.
            // even if we set them here to 0 using <= and later we set them to 1 using <=, only the last assignnment wins.
            out_char_valid <= 1'b0;
            out_word_done  <= 1'b0;

            // character delivery to the trie engine (pure valid/ready flow control):
            // trie_ready is 1 - meaning the trie engine can accept new characters
            // hold_valid is 1 - we have a character to send
            // hold_word_done is 0 - meaning we're not in the middle of sending a word_done signal
            if (trie_ready && hold_valid && !hold_word_done) begin
               out_char <= hold_char; // we copy the character to the output which goes to the trie engine
               out_char_valid <= 1'b1; // we pulse that it is valid
               hold_valid <= 1'b0; // we signal that the holding register is empty
            end

            // word-done delivery to the trie engine
            // the boundary pulse is sent and the gate (word_boundary_busy = hold_word_done)
            // drops immediately; the trie engine's ready line is the only backpressure, so no
            // acknowledge handshake is needed. the trie engine lowers ready while it emits and
            // captures any character that races into its single word-done cycle, so the next
            // word's first character is never lost.
            if (hold_word_done) begin // if a word boundary needs to be signaled
               out_word_done <= 1'b1; // pulse that a word boundary is detected
               hold_word_done <= 1'b0; // clear the holding register's word
            end
            
            // accept from FIFO and map
            fifo_ready <= can_accept; // if we can accept from the FIFO, we set the fifo_ready flag as 1, meaning we are ready to consume a character
            if (fifo_valid && can_accept) begin // if a new byte is available and we can accept it
                if (is_boundary_w) begin // if the character is a boundary
                    if (word_active) begin // if we are inside a word, but we got a boundary, we need to finish the word!
                        hold_word_done <= 1'b1; // we've reached the end of the word, we need to signal a word_done 
                        word_active    <= 1'b0; // we reset the flag - we are not inside a word anymore!
                    end
                end else begin // the incoming byte is a word character
                    hold_char  <= char_map[lower_byte[6:0]]; // we get the character's index and store it in our dedicated register
                    hold_valid <= 1'b1; // set so that the holding register is not empty
                    word_active <= 1'b1; // we set so that we are inside a word
                end
            end
        end
    end    
endmodule
