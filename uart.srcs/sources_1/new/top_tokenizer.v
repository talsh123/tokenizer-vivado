`timescale 1ns / 1ps // simulation time resolution: 1ns - time unit, 1ps - precision

// top_tokenizer.v
// the simplest out of all the custom modules we've built in this project.
// it basically acts as a wrapper that wires the pre-tokenizer and the trie engine together.
// it contains no logic - just instantiations and connections.

module top_tokenizer #(
    // parameter section - these parameters get passed down to both pre_tokenizer.v and trie_engine.v
    parameter CHAR_W = 10, // 10 bits of the alphabet index, 2^10 = 1024 > ~1008 unique characters
    parameter TOKEN_W = 16 // the token IDs consist of 16 bits -> 65,535 >> 30,522 BERT's token limit
    )(
    // clk and rst get passed down to both pre_tokenizer.v and trie_engine.v
    // these come from tokenizer_axi_lite.v
    input wire clk, // clk_100 100 MHz clock
    input wire rst, // synchronous active-high reset
    
    // upstream - data that comes from the input FIFO - raw ASCII from MicroBlaze -> pre_tokenizer.v
    input wire [7:0] fifo_in_data, // raw ascii byte (8 bits) from input FIFO
    input wire fifo_in_valid, // a flag which is 1 if the input FIFO has data available to the pre_tokenizer.v, otherwise 0
    output wire fifo_in_ready, // a flag which is 1 if the pre_tokenizer.v is ready to consume a byte, otherwise 0
    
    // downstream - output FIFO - tokens from trie_engine.v to MicroBlaze
    output wire [TOKEN_W-1:0] fifo_out_data, // the 16-bit token ID going out from trie_engine.v to the MicroBlaze
    output wire fifo_out_valid, // a flag which is 1 if a token ID is valid, otherwise 0
    
    // goes to tokenizer_axi_lite.v
    output wire word_boundary_busy, // gates the input FIFO, comes from the pre_tokenizer.v

    // goes to tokenizer_axi_lite.v - high while anything is still in flight in either stage
    // (pre-tokenizer or trie engine). the AXI wrapper combines this with the FIFO states to
    // form the pipeline-busy status the firmware polls instead of waiting a fixed delay.
    output wire pipeline_busy
);

    // internal wires: these connect the pre_tokenizer.v outputs to trie_engine.v inputs
    wire [CHAR_W-1:0] pt_out_char; // carries the 10-bit alphabet index from the pre_tokenizer.v to the trie_engine.v
    wire pt_out_char_valid; // carries the signal if the alphabet index is valid (1) or not (0)
    wire pt_out_word_done; // carries the signal when the pre_tokenizer.v outputs word_done to the trie_engine.v
    wire trie_ready; // a signal which comes from trie_engine.v to the pre_tokenizer.v which represents when the trie_engine is ready to receive new characters.
    wire pt_word_boundary_busy; // a signal which indicates for the input FIFO that the pre-tokenizer is busy waiting for the trie engine to acknowledge the word boundary.
    wire pt_busy;   // pre-tokenizer has a character/boundary in flight
    wire trie_busy; // trie engine is still working on the current word

    // connect the top tokenizer output ports to the pre-tokenizer instance
    assign word_boundary_busy = pt_word_boundary_busy; // this signals from the pre_tokenizer.v to the top_tokenizer.v to tell the input FIFO to stop sending more characters. the trie_engine hasn't acknowledged the word boundary.

    // pipeline is busy while either stage still has work in flight
    assign pipeline_busy = pt_busy || trie_busy;
    
    // pre-tokenizer instance
    pre_tokenizer #(
        .CHAR_W(CHAR_W) // instantiates it with the CHAR_W parameter
    ) u_pre_tokenizer ( // u_pre_tokenizer is the instance name
        // these come from tokenizer_axi_lite.v
        .clk (clk), // clk_100 100 MHz clock
        .rst (rst), // synchronous active-high reset
        
        // these come from upstream - from input FIFO to the pre-tokenizer
        .fifo_data (fifo_in_data), // raw ascii byte (8 bits) from input FIFO
        .fifo_valid (fifo_in_valid), // input FIFO has data available to the pre-tokenizer
        .fifo_ready (fifo_in_ready), // pre-tokenizer is ready to consume a byte
        
        // these come from downstream - from the pre-tokenizer to the trie engine
        .out_char (pt_out_char), // the 10-bit alphabet index the pre-tokenizer sends to the trie engine's in_char
        .out_char_valid (pt_out_char_valid), // a signal which pulses HIGH when pre-tokenizer has a valid character ready to send to the trie engine
        .out_word_done (pt_out_word_done), //  a signal which pulses HIGH when pre-tokenizer detects a word boundary
        
        // signals back from the trie engine to the pre-tokenizer
        .trie_ready (trie_ready), // a signal which represents if the trie engine is ready to receive new characters (1) or busy (0)
        .word_boundary_busy (pt_word_boundary_busy), // this signal goes to tokenizer_axi_lite.v, indicating the that the pre-tokenizer is waiting for the trie_engine to acknowledge the word boundary, and to gate the input FIFO.
        .pt_busy (pt_busy) // high while the pre-tokenizer still has a character or boundary in flight
    );
    
    // trie engine instance
    trie_engine #(
        .CHAR_W(CHAR_W), // instantiates it with the CHAR_W parameter
        .TOKEN_W(TOKEN_W) // instantiates it with the TOKEN_W parameter
    ) u_trie_engine (
        // these come from tokenizer_axi_lite.v
        .clk (clk), // clk_100 100 MHz clock
        .rst (rst), // synchronous active-high reset
    
        // these come from upstream - from pre-tokenizer to the trie engine
        .in_char (pt_out_char), // the 10-bit mapped alphabet index
        .in_char_valid (pt_out_char_valid), // a signal which represents if the character is valid (1) or not (0)
        .in_word_done (pt_out_word_done), // a signal which goes HIGH when a word boundary is sent (1) or not (0)
        .ready (trie_ready), // a signal the trie engine sends the pre-tokenizer indicating it is ready to accept new characters
    
        // these get sent downstream - from the trie engine to the output FIFO
        .out_token_id (fifo_out_data), // the 16-bit token ID
        .out_token_valid(fifo_out_valid), // a flag which represents if the token ID is valid (1) or not (0)
        .busy (trie_busy) // high while the trie engine is still processing the current word
    );
endmodule
