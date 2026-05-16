`timescale 1ns / 1ps

// ============================================================================
// top_tokenizer.v
//
// Top-level wrapper connecting Pre-Tokenizer to Trie Engine.
// Input:  Raw ASCII bytes from input FIFO (MicroBlaze/lwIP)
// Output: 16-bit BERT Token IDs to output FIFO (MicroBlaze/lwIP)
// ============================================================================

module top_tokenizer #(
    parameter CHAR_W = 10, // amount of unique characters in the vocabulary (2^10 = 1024 > 1008 unique chars)
    parameter TOKEN_W = 16 // BERT token ID width
    )(
    input wire clk, // system clock
    input wire rst, // synchronous reset signal
    
    // input FIFOs - raw ASCII from MicroBlaze -> Pre-Tokenizer
    input wire [7:0] fifo_in_data, // raw ascii byte (8 bits) from input FIFO
    input wire fifo_in_valid, // input FIFO has data available to the Pre-Tokenizer
    output wire fifo_in_ready, // Pre-Tokenizer is ready to consume a byte
    
    // output FIFOs - Trie Engine to MicroBlaze
    output wire [TOKEN_W-1:0] fifo_out_data, // 16 bits token ID going out to the MicroBlaze
    output wire fifo_out_valid, // token ID is valid this cycle
    
    output wire word_boundary_busy // top_tokenizer output ports
);

// ========================================================================
// Internal wires: These signal connect the Pre-Tokenizer's output to the
// Tri engine's input
// ========================================================================
wire [CHAR_W-1:0] pt_out_char; // the 10 alphabet index the Pre-Tokenizer sends to the Trie engine's in_char
wire pt_out_char_valid; // pulses high for 1 cycle when the Pre-Tokenizer has a valid character ready
wire pt_out_word_done; // pulses high when Pre-Tokenizer detects a word boundary
wire trie_ready; // a signal which represents when the trie engine can accept a character

wire pt_word_boundary_busy; // flag so that we can know when we are handling a word boundary

// connect the top tokenizer output ports to the pre-tokenizer instance
assign word_boundary_busy = pt_word_boundary_busy;

// ========================================================================
// Pre-Tokenizer Instance
// ========================================================================
pre_tokenizer #(
    .CHAR_W(CHAR_W)
) u_pre_tokenizer (
    .clk (clk),
    .rst (rst),
    
    // Upstream: from input FIFO
    .fifo_data (fifo_in_data), // raw ascii byte (8 bits) from input FIFO
    .fifo_valid (fifo_in_valid), // input FIFO has data available to the Pre-Tokenizer
    .fifo_ready (fifo_in_ready), // Pre-Tokenizer is ready to consume a byte
    
    // Downstream: to trie engine (internal wires)
    .out_char (pt_out_char), // the 10 alphabet index the Pre-Tokenizer sends to the Trie engine's in_char
    .out_char_valid (pt_out_char_valid), // pulses high for 1 cycle when the Pre-Tokenizer has a valid character ready
    .out_word_done (pt_out_word_done), // pulses high when Pre-Tokenizer detects a word boundary
    
    // Backpressure from trie engine
    .trie_ready (trie_ready), // a signal which represents when the trie engine can accept a character
    
    .word_boundary_busy (pt_word_boundary_busy) // pre-tokenizer instance
);

// ========================================================================
// Trie Engine Instance
// ========================================================================
trie_engine #(
    .CHAR_W(CHAR_W),
    .TOKEN_W(TOKEN_W)
) u_trie_engine (
    .clk (clk), // system clock
    .rst (rst), // synchronous reset signal

    // Upstream: from pre-tokenizer (internal wires)
    .in_char (pt_out_char), // mapped alphabet index
    .in_char_valid (pt_out_char_valid), // character is valid
    .in_word_done (pt_out_word_done), // word boundary signal
    .ready (trie_ready), // backpressure to pre-tokenizer

    // Downstream: to output FIFO
    .out_token_id (fifo_out_data), // 16-bit BERT token ID
    .out_token_valid(fifo_out_valid) // token ID is valid this cycle
);
    
endmodule
