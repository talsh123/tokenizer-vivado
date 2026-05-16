`timescale 1ns / 1ps

// ============================================================================
// tb_pre_tokenizer.v
//
// Testbench for pre_tokenizer.v
// Tests ASCII->index mapping, lowercase conversion, and boundary detection.
// ============================================================================

module tb_pre_tokenizer;

    // ========================================================================
    // Parameters
    // ========================================================================
    parameter CHAR_W = 10; // 2^10 = 1024 > 977 unique characters in BERT vocabulary
    parameter CLK_PERIOD = 10; // 100MHz
    
    // ========================================================================
    // DUT Signals
    // ========================================================================
    // wires and signals
    // fifo_ready, out_char, out_char_valid, out_word_done are wire -  driven by the DUT.
    // Everything else is reg since the testbench drives them.
    reg clk;
    reg rst;
    reg [7:0] fifo_data;
    reg fifo_valid;
    wire fifo_ready;
    wire [CHAR_W-1:0] out_char;
    wire out_char_valid;
    wire out_word_done;
    reg trie_ready;
    
    // ========================================================================
    // DUT Instantiation
    // ========================================================================
    // Instantiating all of the above (wires and signals)
    pre_tokenizer #(
        .CHAR_W(CHAR_W)
    ) uut (
        .clk (clk),
        .rst (rst),
        .fifo_data (fifo_data),
        .fifo_valid (fifo_valid),
        .fifo_ready (fifo_ready),
        .out_char (out_char),
        .out_char_valid (out_char_valid),
        .out_word_done (out_word_done),
        .trie_ready (trie_ready)
    );
    
    // ========================================================================
    // Clock Generation
    // ========================================================================
    initial clk = 0;
    // generates the clock signal.
    // wait 5ns and then flip the clock to the opposite value
    always #(CLK_PERIOD/2) clk = ~clk;

    // ========================================================================
    // Character Map (for verification - same table the DUT uses)
    // ========================================================================
    reg [CHAR_W-1:0] expected_map [0:127];
    initial begin
        $readmemh("char_to_index_map.mem", expected_map);
    end
    
    
    
    // ========================================================================
    // Test tracking
    // ========================================================================
    integer test_num; // number of tests
    integer errors; // number of errors catched

    // ========================================================================
    // Helper Tasks
    // ========================================================================

    // Send a single ASCII byte to the pre-tokenizer
    task send_byte;
        input [7:0] ascii_byte;
        begin
            // Wait for fifo_ready to be high
            @(posedge clk);
            while (!fifo_ready) @(posedge clk); // we're running the clock here and waiting...

            fifo_data  <= ascii_byte; // send the raw ascii data
            fifo_valid <= 1'b1; // make sure the FIFO has data ready
            @(posedge clk);
            fifo_valid <= 1'b0; // wait a clock and set the flag to 0
            @(posedge clk); // extra cycle to let output settle
            @(posedge clk); // extra cycle to let the output to be driven to trie engine
        end
    endtask

    // Check that a character output was produced with the expected index
    task expect_char; // the name of the task
        input [CHAR_W-1:0] expected_index; // the expected character index according to the mapping
        begin
            // If we don't have data available to the Trie engine
            if (!out_char_valid) begin
                $display("  FAIL: expected out_char_valid=1, got 0");
                errors = errors + 1; // increase the error count
            end else if (out_char !== expected_index) begin // if the character doesn't match with the expected index
                $display("  FAIL: expected out_char=%0d, got %0d",
                         expected_index, out_char);
                errors = errors + 1; // increase the error count
            end else begin
                // the character matched!
                $display("  OK: out_char=%0d", out_char);
            end
        end
    endtask

    // Check that word_done was pulsed
    task expect_word_done; // the name of the task
        begin
            // If we don't have data available to the Trie engine
            if (!out_word_done) begin
                $display("  FAIL: expected out_word_done=1, got 0");
                errors = errors + 1; // increase the error count
            end else begin
                // We issued a word_done after finishing the word.
                $display("  OK: word_done pulsed");
            end
        end
    endtask

    // Check that neither char_valid nor word_done is asserted
    task expect_nothing; // the name of the task
        begin
            // If we have data available to the Trie engine
            if (out_char_valid) begin
                $display("  FAIL: unexpected out_char_valid=1");
                errors = errors + 1; // increase the error count
            end else if (out_word_done) begin // if final letter
                $display("  FAIL: unexpected out_word_done=1");
                errors = errors + 1; // increase the error count
            end else begin
                // if we got nothing
                $display("  OK: no output (as expected)");
            end
        end
    endtask
    
    // Simulate trie engine acknowledging word_done
    // this task simulates the trie engine's behavior by breifly dropping trie_ready
    // (briefly drop trie_ready to mimic trie processing the boundary)
    task ack_word_done;
        begin
            @(posedge clk);
            trie_ready = 1'b0;  // trie starts processing word_done
            @(posedge clk);
            trie_ready = 1'b1;  // trie finishes, ready again
            @(posedge clk);     // let pre-tokenizer see the rising edge
        end
    endtask
    
    // ========================================================================
    // Test Plan:
    //
    // Test 1: lowercase 'h'
    //         Input: 'h' (0x68)
    //         Expected: mapped char index for 'h'
    //         Verifies: Basic ASCII -> alphabet index mapping
    //
    // Test 2: uppercase 'H'
    //         Input: 'H' (0x48)
    //         Expected: same mapped index as lowercase 'h'
    //         Verifies: Lowercase conversion (BERT base-uncased)
    //
    // Test 3: space after word
    //         Input: space (0x20)
    //         Expected: word_done pulse
    //         Verifies: Boundary detection triggers after a word
    //
    // Test 4: consecutive space
    //         Input: space (0x20) again
    //         Expected: nothing (no output)
    //         Verifies: No duplicate word_done for consecutive boundaries
    //
    // Test 5: full word "hi" + space
    //         Input: 'h', 'i', space
    //         Expected: mapped 'h', mapped 'i', word_done
    //         Verifies: Full word processing end-to-end
    //
    // Test 6: digit '5'
    //         Input: '5' (0x35)
    //         Expected: mapped char index for '5'
    //         Verifies: Digits treated as word characters, not boundaries
    //
    // Test 7: punctuation '.'
    //         Input: '.' (0x2E)
    //         Expected: word_done pulse
    //         Verifies: Punctuation is detected as a boundary
    //
    // Test 8: backpressure
    //         Input: 'a' with trie_ready=0
    //         Expected: nothing (no output)
    //         Verifies: Backpressure from trie engine stops processing
    // ========================================================================
    // ========================================================================
    // Main Test Sequence
    // ========================================================================
    initial begin
        // Initialize signals
        rst        = 1'b1;
        fifo_data  = 8'h00;
        fifo_valid = 1'b0;
        trie_ready = 1'b1; // trie engine ready by default

        errors   = 0;
        test_num = 0;

        // Reset
        repeat(10) @(posedge clk);
        rst = 1'b0;
        repeat(5) @(posedge clk);

        $display("============================================");
        $display(" Pre-Tokenizer Testbench");
        $display("============================================");

        // ----------------------------------------------------------
        // Test 1: Single lowercase letter 'h'
        // Should output the mapped index for 'h'
        // ----------------------------------------------------------
        test_num = 1;
        $display("\n===== TEST %0d: lowercase 'h' =====", test_num);
        send_byte(8'h68); // 'h'
        expect_char(expected_map[8'h68]); // 'h' is already lowercase

        // ----------------------------------------------------------
        // Test 2: Uppercase letter 'H'
        // Should be converted to lowercase, same output as test 1
        // ----------------------------------------------------------
        test_num = 2;
        $display("\n===== TEST %0d: uppercase 'H' -> lowercase =====", test_num);
        send_byte(8'h48); // 'H'
        expect_char(expected_map[8'h68]); // should map to lowercase 'h'

        // ----------------------------------------------------------
        // Test 3: Space character (boundary)
        // Should pulse word_done since we were inside a word
        // ----------------------------------------------------------
        test_num = 3;
        $display("\n===== TEST %0d: space (boundary after word) =====", test_num);
        send_byte(8'h20); // space
        expect_word_done;
        ack_word_done;     // ADD THIS

        // ----------------------------------------------------------
        // Test 4: Second space (consecutive boundary)
        // Should produce nothing - no duplicate word_done
        // ----------------------------------------------------------
        test_num = 4;
        $display("\n===== TEST %0d: second space (no output) =====", test_num);
        send_byte(8'h20); // space again
        expect_nothing;

        // ----------------------------------------------------------
        // Test 5: Full word "hi" followed by space
        // Should output mapped 'h', mapped 'i', then word_done
        // ----------------------------------------------------------
        test_num = 5;
        $display("\n===== TEST %0d: word 'hi' + space =====", test_num);

        send_byte(8'h68); // 'h'
        expect_char(expected_map[8'h68]);

        send_byte(8'h69); // 'i'
        expect_char(expected_map[8'h69]);

        send_byte(8'h20); // space
        expect_word_done;
        ack_word_done;     // ADD THIS

        // ----------------------------------------------------------
        // Test 6: Digit '5'
        // Should be treated as a word character, not a boundary
        // ----------------------------------------------------------
        test_num = 6;
        $display("\n===== TEST %0d: digit '5' =====", test_num);
        send_byte(8'h35); // '5'
        expect_char(expected_map[8'h35]);

        // ----------------------------------------------------------
        // Test 7: Punctuation '.' (boundary)
        // Should pulse word_done since digit made word_active
        // ----------------------------------------------------------
        test_num = 7;
        $display("\n===== TEST %0d: period (boundary) =====", test_num);
        send_byte(8'h2E); // '.'
        expect_word_done;
        ack_word_done;     // ADD THIS

        // ----------------------------------------------------------
        // Test 8: Backpressure test
        // Deassert trie_ready, send a byte, verify nothing happens
        // ----------------------------------------------------------
        test_num = 8;
        $display("\n===== TEST %0d: backpressure =====", test_num);
        trie_ready = 1'b0;
        fifo_data  = 8'h61; // 'a'
        fifo_valid = 1'b1;
        @(posedge clk);
        @(posedge clk);
        expect_nothing;
        fifo_valid = 1'b0;
        trie_ready = 1'b1; // release backpressure
        @(posedge clk);
        @(posedge clk);

        // ----------------------------------------------------------
        // Summary
        // ----------------------------------------------------------
        $display("\n============================================");
        if (errors == 0)
            $display(" ALL TESTS PASSED");
        else
            $display(" %0d ERROR(S) DETECTED", errors);
        $display("============================================");

        repeat(10) @(posedge clk);
        $finish;
    end

    // ========================================================================
    // Timeout Watchdog
    // ========================================================================
    initial begin
        #100_000;
        $display("ERROR: Simulation timed out!");
        $finish;
    end

endmodule
