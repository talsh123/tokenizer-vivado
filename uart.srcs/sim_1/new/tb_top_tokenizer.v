`timescale 1ns / 1ps

// ============================================================================
// tb_top_tokenizer.v
//
// Testbench for top_tokenizer.v (Pre-Tokenizer + Trie Engine)
//
// This testbench feeds RAW ASCII strings (including spaces) into the
// top_tokenizer and verifies that the correct BERT Token IDs come out.
// Unlike tb_trie_engine which feeds pre-mapped alphabet indices,
// this testbench tests the full pipeline end-to-end.
//
// TEST VECTORS (from Python dual-trie verifier / HuggingFace):
//   Input: "hello "         -> ['hello']                          -> [7592]
//   Input: "hardware "      -> ['hardware']                       -> [8051]
//   Input: "embedding "     -> ['em', '##bed', '##ding']          -> [7861, 8270, 4667]
//   Input: "unquestionably "-> ['un','##quest','##ion','##ably']   -> [4895, 15500, 3258, 8231]
//   Input: "hello hardware "-> ['hello', 'hardware']              -> [7592, 8051]
//
// Note: Each word is terminated by a space character (0x20) which the
//       pre-tokenizer uses to detect word boundaries and pulse word_done.
//
// Test Plan:
//
// Test 1: "hello " (single word, single token)
//         Verifies: Basic end-to-end pipeline for a complete vocabulary word
//
// Test 2: "hardware " (single word, single token)
//         Verifies: Longer single-token word through full pipeline
//
// Test 3: "embedding " (single word, 3 tokens with backtracking)
//         Verifies: Dual-trie switching and backtracking through full pipeline
//                   Root trie finds "em", continuation finds "##bed", "##ding"
//
// Test 4: "unquestionably " (single word, 4 tokens with backtracking)
//         Verifies: Multiple continuation tokens with complex backtracking
//
// Test 5: "hello hardware " (two words, 2 tokens)
//         Verifies: Multi-word input with word boundary detection
//                   use_root must reset between words
//
// ============================================================================

module tb_top_tokenizer;

    // ========================================================================
    // Parameters
    // ========================================================================
    parameter CHAR_W     = 10;
    parameter TOKEN_W    = 16;
    parameter CLK_PERIOD = 10; // 100 MHz

    // ========================================================================
    // DUT Signals
    // ========================================================================
    reg                 clk;
    reg                 rst;

    // Input FIFO interface
    reg  [7:0]          fifo_in_data;
    reg                 fifo_in_valid;
    wire                fifo_in_ready;

    // Output FIFO interface
    wire [TOKEN_W-1:0]  fifo_out_data;
    wire                fifo_out_valid;

    // ========================================================================
    // DUT Instantiation
    // ========================================================================
    top_tokenizer #(
        .CHAR_W  (CHAR_W),
        .TOKEN_W (TOKEN_W)
    ) uut (
        .clk            (clk),
        .rst            (rst),
        .fifo_in_data   (fifo_in_data),
        .fifo_in_valid  (fifo_in_valid),
        .fifo_in_ready  (fifo_in_ready),
        .fifo_out_data  (fifo_out_data),
        .fifo_out_valid (fifo_out_valid)
    );

    // ========================================================================
    // Clock Generation
    // ========================================================================
    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // ========================================================================
    // Token Capture
    // ========================================================================
    reg [TOKEN_W-1:0] captured_tokens [0:31];
    integer           token_count;

    always @(posedge clk) begin
        if (rst) begin
            token_count <= 0;
        end else if (fifo_out_valid) begin
            captured_tokens[token_count] <= fifo_out_data;
            token_count <= token_count + 1;
        end
    end

    // ========================================================================
    // Test Tracking
    // ========================================================================
    integer test_num;
    integer total_errors;

    // ========================================================================
    // Helper Tasks
    // ========================================================================

    // Send a single raw ASCII byte through the input FIFO interface.
    // Waits for fifo_in_ready before presenting data (respects backpressure).
    task send_byte;
        input [7:0] ascii_byte;
        begin
            @(posedge clk);
            while (!fifo_in_ready) @(posedge clk); // wait for ready

            fifo_in_data  <= ascii_byte;
            fifo_in_valid <= 1'b1;
            @(posedge clk);
            fifo_in_valid <= 1'b0;
            @(posedge clk); // extra cycle to let output settle
        end
    endtask

    // Send a full ASCII string, one byte at a time.
    // The string must include a trailing space or punctuation to trigger word_done.
    task send_string;
        input [255:0] str_packed;  // packed ASCII string (up to 32 chars)
        input integer str_len;
        integer i;
        reg [7:0] ch;
        begin
            $display("\n--- Sending string (length=%0d) ---", str_len);
            for (i = 0; i < str_len; i = i + 1) begin
                // Extract character from packed string (MSB first)
                ch = str_packed[8*(31-i) +: 8];
                if (ch == 8'h20)
                    $display("  Sending ' ' (space, 0x20)");
                else
                    $display("  Sending '%c' (ASCII 0x%02X)", ch, ch);
                send_byte(ch);
            end

            // Wait for all tokens to be emitted
            // Allow enough cycles for backtracking and emission
            repeat(500) @(posedge clk);
        end
    endtask

    // Verify captured tokens against expected values.
    // Supports up to 4 expected tokens per test.
    task verify_tokens;
        input integer  num_expected;
        input [TOKEN_W-1:0] exp0, exp1, exp2, exp3;
        integer j;
        reg [TOKEN_W-1:0] expected [0:3];
        reg pass;
        begin
            expected[0] = exp0;
            expected[1] = exp1;
            expected[2] = exp2;
            expected[3] = exp3;

            pass = 1'b1;
            if (token_count !== num_expected) begin
                $display("  FAIL: Expected %0d tokens, got %0d",
                         num_expected, token_count);
                pass = 1'b0;
            end else begin
                for (j = 0; j < num_expected; j = j + 1) begin
                    if (captured_tokens[j] !== expected[j]) begin
                        $display("  FAIL: Token[%0d] expected %0d, got %0d",
                                 j, expected[j], captured_tokens[j]);
                        pass = 1'b0;
                    end
                end
            end

            if (pass)
                $display("  PASS!");
            else begin
                $display("  *** TEST FAILED ***");
                total_errors = total_errors + 1;
            end

            // Reset token counter for next test
            token_count <= 0;
            @(posedge clk); // let the reset take effect
        end
    endtask

    // Verify captured tokens for multi-word tests (up to 8 expected tokens).
    task verify_tokens_8;
        input integer  num_expected;
        input [TOKEN_W-1:0] exp0, exp1, exp2, exp3;
        input [TOKEN_W-1:0] exp4, exp5, exp6, exp7;
        integer j;
        reg [TOKEN_W-1:0] expected [0:7];
        reg pass;
        begin
            expected[0] = exp0;
            expected[1] = exp1;
            expected[2] = exp2;
            expected[3] = exp3;
            expected[4] = exp4;
            expected[5] = exp5;
            expected[6] = exp6;
            expected[7] = exp7;

            pass = 1'b1;
            if (token_count !== num_expected) begin
                $display("  FAIL: Expected %0d tokens, got %0d",
                         num_expected, token_count);
                pass = 1'b0;
            end else begin
                for (j = 0; j < num_expected; j = j + 1) begin
                    if (captured_tokens[j] !== expected[j]) begin
                        $display("  FAIL: Token[%0d] expected %0d, got %0d",
                                 j, expected[j], captured_tokens[j]);
                        pass = 1'b0;
                    end
                end
            end

            if (pass)
                $display("  PASS!");
            else begin
                $display("  *** TEST FAILED ***");
                total_errors = total_errors + 1;
            end

            // Reset token counter for next test
            token_count <= 0;
            @(posedge clk);
        end
    endtask

    // ========================================================================
    // Main Test Sequence
    // ========================================================================
    initial begin
        // Initialize signals
        rst           = 1'b1;
        fifo_in_data  = 8'h00;
        fifo_in_valid = 1'b0;
        token_count   = 0;
        total_errors  = 0;

        // Reset for several cycles
        repeat(10) @(posedge clk);
        rst = 1'b0;
        repeat(5) @(posedge clk);

        $display("============================================");
        $display(" Top Tokenizer Testbench - Full Pipeline");
        $display("============================================");

        // ----------------------------------------------------------
        // Test 1: "hello " -> single token [7592]
        // Raw ASCII including trailing space to trigger word_done.
        // Verifies basic end-to-end: ASCII input -> token ID output.
        // ----------------------------------------------------------
        test_num = 1;
        $display("\n===== TEST %0d: \"hello \" =====", test_num);
        // h=0x68, e=0x65, l=0x6C, l=0x6C, o=0x6F, space=0x20
        send_string({8'h68, 8'h65, 8'h6C, 8'h6C, 8'h6F, 8'h20, {26{8'h00}}}, 6);
        verify_tokens(1, 16'd7592, 16'd0, 16'd0, 16'd0);

        // ----------------------------------------------------------
        // Test 2: "hardware " -> single token [8051]
        // Verifies longer single-token word through full pipeline.
        // ----------------------------------------------------------
        test_num = 2;
        $display("\n===== TEST %0d: \"hardware \" =====", test_num);
        // h=0x68, a=0x61, r=0x72, d=0x64, w=0x77, a=0x61, r=0x72, e=0x65, space=0x20
        send_string({8'h68, 8'h61, 8'h72, 8'h64, 8'h77, 8'h61, 8'h72, 8'h65,
                     8'h20, {23{8'h00}}}, 9);
        verify_tokens(1, 16'd8051, 16'd0, 16'd0, 16'd0);

        // ----------------------------------------------------------
        // Test 3: "embedding " -> 3 tokens [7861, 8270, 4667]
        // Verifies dual-trie switching and backtracking:
        //   "em" from root trie, "##bed" and "##ding" from continuation.
        // The pre-tokenizer sends raw ASCII, no ## needed.
        // ----------------------------------------------------------
        test_num = 3;
        $display("\n===== TEST %0d: \"embedding \" =====", test_num);
        // e=0x65, m=0x6D, b=0x62, e=0x65, d=0x64, d=0x64, i=0x69, n=0x6E, g=0x67, space=0x20
        send_string({8'h65, 8'h6D, 8'h62, 8'h65, 8'h64, 8'h64, 8'h69, 8'h6E,
                     8'h67, 8'h20, {22{8'h00}}}, 10);
        verify_tokens(3, 16'd7861, 16'd8270, 16'd4667, 16'd0);

        // ----------------------------------------------------------
        // Test 4: "unquestionably " -> 4 tokens [4895, 15500, 3258, 8231]
        // Verifies multiple continuation tokens with backtracking:
        //   "un" from root, "##quest", "##ion", "##ably" from continuation.
        // ----------------------------------------------------------
        test_num = 4;
        $display("\n===== TEST %0d: \"unquestionably \" =====", test_num);
        // u=0x75, n=0x6E, q=0x71, u=0x75, e=0x65, s=0x73, t=0x74,
        // i=0x69, o=0x6F, n=0x6E, a=0x61, b=0x62, l=0x6C, y=0x79, space=0x20
        send_string({8'h75, 8'h6E, 8'h71, 8'h75, 8'h65, 8'h73, 8'h74,
                     8'h69, 8'h6F, 8'h6E, 8'h61, 8'h62, 8'h6C, 8'h79,
                     8'h20, {17{8'h00}}}, 15);
        verify_tokens(4, 16'd4895, 16'd15500, 16'd3258, 16'd8231);

        // ----------------------------------------------------------
        // Test 5: "hello hardware " -> 2 tokens [7592, 8051]
        // Verifies multi-word input:
        //   The space between "hello" and "hardware" triggers word_done,
        //   resetting use_root so "hardware" is searched in root trie.
        //   The trailing space triggers word_done for "hardware".
        // ----------------------------------------------------------
        test_num = 5;
        $display("\n===== TEST %0d: \"hello hardware \" =====", test_num);
        // h=0x68, e=0x65, l=0x6C, l=0x6C, o=0x6F, space=0x20,
        // h=0x68, a=0x61, r=0x72, d=0x64, w=0x77, a=0x61, r=0x72, e=0x65, space=0x20
        send_string({8'h68, 8'h65, 8'h6C, 8'h6C, 8'h6F, 8'h20,
                     8'h68, 8'h61, 8'h72, 8'h64, 8'h77, 8'h61, 8'h72, 8'h65,
                     8'h20, {17{8'h00}}}, 15);
        verify_tokens_8(2, 16'd7592, 16'd8051, 16'd0, 16'd0,
                           16'd0, 16'd0, 16'd0, 16'd0);

        // ----------------------------------------------------------
        // Summary
        // ----------------------------------------------------------
        $display("\n============================================");
        if (total_errors == 0)
            $display(" ALL TESTS PASSED");
        else
            $display(" %0d TEST(S) FAILED", total_errors);
        $display("============================================");

        repeat(20) @(posedge clk);
        $finish;
    end

    // ========================================================================
    // Timeout Watchdog
    // ========================================================================
    initial begin
        #10_000_000; // 10ms at 1ns resolution
        $display("ERROR: Simulation timed out!");
        $finish;
    end

endmodule