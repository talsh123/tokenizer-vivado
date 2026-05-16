`timescale 1ns / 1ps

// ============================================================================
// tb_trie_engine.v
//
// Testbench for trie_engine.v (Dual-Trie CSR + Binary Search)
//
// TEST VECTORS (from Python dual-trie verifier):
//   Word: "hello"          -> ['hello']                          -> [7592]
//   Word: "hardware"       -> ['hardware']                       -> [8051]
//   Word: "embedding"      -> ['em', '##bed', '##ding']          -> [7861, 8270, 4667]
//   Word: "unquestionably" -> ['un','##quest','##ion','##ably']   -> [4895, 15500, 3258, 8231]
//
// KEY CHANGE FROM V2:
//   With the dual-trie architecture, the testbench sends raw characters
//   without any ## prefix. The trie engine internally switches between
//   root and continuation tries using the use_root flag.
//   "embedding" is sent as: e,m,b,e,d,d,i,n,g (one word, one word_done)
//
// Test Plan:
//
// Test 1: "hello" (single token, root trie only)
//         Input: h,e,l,l,o + word_done
//         Expected: [7592]
//         Verifies: Basic root trie lookup for a complete word
//
// Test 2: "hardware" (single token, root trie only)
//         Input: h,a,r,d,w,a,r,e + word_done
//         Expected: [8051]
//         Verifies: Longer single-token word in root trie
//
// Test 3: "embedding" (3 tokens, root + continuation trie)
//         Input: e,m,b,e,d,d,i,n,g + word_done
//         Expected: [7861, 8270, 4667]
//         Verifies: Dual-trie switching and backtracking
//                   "em" found in root, "bed" and "ding" in continuation
//
// Test 4: "unquestionably" (4 tokens, root + continuation trie)
//         Input: u,n,q,u,e,s,t,i,o,n,a,b,l,y + word_done
//         Expected: [4895, 15500, 3258, 8231]
//         Verifies: Multiple continuation tokens with backtracking
//
// ============================================================================

module tb_trie_engine;

    // ========================================================================
    // Parameters (must match trie_engine)
    // ========================================================================
    parameter ROOT_NUM_NODES = 56719;
    parameter ROOT_NUM_EDGES = 56718;
    parameter CONT_NUM_NODES = 7864;
    parameter CONT_NUM_EDGES = 7863;
    parameter TOKEN_W        = 16;
    parameter NODE_W         = 17;
    parameter EDGE_ADDR_W    = 16;
    parameter CHAR_W         = 10;
    parameter BUF_DEPTH      = 32;
    parameter CLK_PERIOD     = 10; // 100 MHz

    // ========================================================================
    // DUT Signals
    // ========================================================================
    reg                 clk;
    reg                 rst;
    reg  [CHAR_W-1:0]   in_char;
    reg                 in_char_valid;
    reg                 in_word_done;
    wire                ready;
    wire [TOKEN_W-1:0]  out_token_id;
    wire                out_token_valid;

    // ========================================================================
    // DUT Instantiation
    // ========================================================================
    trie_engine #(
        .ROOT_NUM_NODES (ROOT_NUM_NODES),
        .ROOT_NUM_EDGES (ROOT_NUM_EDGES),
        .CONT_NUM_NODES (CONT_NUM_NODES),
        .CONT_NUM_EDGES (CONT_NUM_EDGES),
        .TOKEN_W        (TOKEN_W),
        .NODE_W         (NODE_W),
        .EDGE_ADDR_W    (EDGE_ADDR_W),
        .CHAR_W         (CHAR_W),
        .BUF_DEPTH      (BUF_DEPTH)
    ) uut (
        .clk            (clk),
        .rst            (rst),
        .in_char        (in_char),
        .in_char_valid  (in_char_valid),
        .in_word_done   (in_word_done),
        .ready          (ready),
        .out_token_id   (out_token_id),
        .out_token_valid(out_token_valid)
    );

    // ========================================================================
    // Clock Generation
    // ========================================================================
    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // ========================================================================
    // Character Map (ASCII -> alphabet index)
    // ========================================================================
    reg [CHAR_W-1:0] char_map [0:127];
    integer cm_i;

    initial begin
        for (cm_i = 0; cm_i < 128; cm_i = cm_i + 1)
            char_map[cm_i] = {CHAR_W{1'b1}};
        $readmemh("char_to_index_map.mem", char_map);
    end

    // ========================================================================
    // Token Capture
    // ========================================================================
    reg [TOKEN_W-1:0] captured_tokens [0:31];
    integer           token_count;

    always @(posedge clk) begin
        if (rst) begin
            token_count <= 0;
        end else if (out_token_valid) begin
            captured_tokens[token_count] <= out_token_id;
            token_count <= token_count + 1;
        end
    end

    // ========================================================================
    // Helper Tasks
    // ========================================================================

    // Send a single character to the engine (mapped from ASCII)
    task send_char;
        input [7:0] ascii_char;
        reg [CHAR_W-1:0] mapped;
        begin
            mapped = char_map[ascii_char[6:0]];
            if (mapped == {CHAR_W{1'b1}}) begin
                $display("WARNING: ASCII char '%c' (0x%02X) not in alphabet!",
                         ascii_char, ascii_char);
            end

            // Wait for ready
            while (!ready) @(posedge clk);

            in_char       <= mapped;
            in_char_valid <= 1'b1;
            @(posedge clk);
            in_char_valid <= 1'b0;
            @(posedge clk); // extra cycle to avoid ready race condition
        end
    endtask

    // Send a word (raw ASCII characters) followed by word_done
    // No ## prefix needed - the dual-trie handles continuation internally
    task send_word;
        input [255:0] word_packed; // Packed ASCII string (up to 32 chars)
        input integer  word_len;
        integer k;
        reg [7:0] ch;
        begin
            $display("\n--- Sending word (length=%0d) ---", word_len);
            for (k = 0; k < word_len; k = k + 1) begin
                // Extract character from packed string (MSB first)
                ch = word_packed[8*(31-k) +: 8];
                $display("  Sending char '%c' (ASCII 0x%02X)", ch, ch);
                send_char(ch);
            end

            // Pulse word_done
            @(posedge clk);
            in_word_done <= 1'b1;
            @(posedge clk);
            in_word_done <= 1'b0;

            // Wait for all tokens to be emitted
            // (give enough cycles for backtracking + emission)
            repeat(500) @(posedge clk);
        end
    endtask

    // Verify captured tokens against expected values
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
            else
                $display("  *** TEST FAILED ***");

            // Reset token counter for next test
            token_count <= 0;
        end
    endtask

    // ========================================================================
    // Main Test Sequence
    // ========================================================================
    initial begin
        // Initialize signals
        rst           = 1'b1;
        in_char       = {CHAR_W{1'b0}};
        in_char_valid = 1'b0;
        in_word_done  = 1'b0;
        token_count   = 0;

        // Reset for several cycles
        repeat(10) @(posedge clk);
        rst = 1'b0;
        repeat(5) @(posedge clk);
        
        // Debug: verify root trie BRAM loaded correctly
        $display("============================================");
        $display(" Trie Engine Testbench - Dual Trie");
        $display("============================================");

        // ----------------------------------------------------------
        // Test 1: "hello" -> single token [7592]
        // Root trie only - "hello" is a complete word in the vocabulary
        // ----------------------------------------------------------
        $display("\n===== TEST 1: 'hello' =====");
        send_word({8'h68, 8'h65, 8'h6C, 8'h6C, 8'h6F, {27{8'h00}}}, 5);
        verify_tokens(1, 16'd7592, 16'd0, 16'd0, 16'd0);

        // ----------------------------------------------------------
        // Test 2: "hardware" -> single token [8051]
        // Root trie only - "hardware" is a complete word in the vocabulary
        // ----------------------------------------------------------
        $display("\n===== TEST 2: 'hardware' =====");
        send_word({8'h68, 8'h61, 8'h72, 8'h64, 8'h77, 8'h61, 8'h72, 8'h65,
                   {24{8'h00}}}, 8);
        verify_tokens(1, 16'd8051, 16'd0, 16'd0, 16'd0);

        // ----------------------------------------------------------
        // Test 3: "embedding" -> 3 tokens [7861, 8270, 4667]
        // Tests the dual-trie architecture:
        //   "em" found in root trie (token 7861)
        //   use_root switches to 0
        //   "bed" found in continuation trie (token 8270 = ##bed)
        //   "ding" found in continuation trie (token 4667 = ##ding)
        // All sent as one continuous word: e,m,b,e,d,d,i,n,g
        // ----------------------------------------------------------
        $display("\n===== TEST 3: 'embedding' =====");
        // e=0x65, m=0x6D, b=0x62, e=0x65, d=0x64, d=0x64, i=0x69, n=0x6E, g=0x67
        send_word({8'h65, 8'h6D, 8'h62, 8'h65, 8'h64, 8'h64, 8'h69, 8'h6E,
                   8'h67, {23{8'h00}}}, 9);
        verify_tokens(3, 16'd7861, 16'd8270, 16'd4667, 16'd0);

        // ----------------------------------------------------------
        // Test 4: "unquestionably" -> 4 tokens [4895, 15500, 3258, 8231]
        // Tests multiple continuation tokens with backtracking:
        //   "un" found in root trie (token 4895)
        //   "question" -> "quest" found in continuation trie (token 15500 = ##quest)
        //   "ion" found in continuation trie (token 3258 = ##ion)
        //   "ably" found in continuation trie (token 8231 = ##ably)
        // Sent as: u,n,q,u,e,s,t,i,o,n,a,b,l,y
        // ----------------------------------------------------------
        $display("\n===== TEST 4: 'unquestionably' =====");
        // u=0x75, n=0x6E, q=0x71, u=0x75, e=0x65, s=0x73, t=0x74,
        // i=0x69, o=0x6F, n=0x6E, a=0x61, b=0x62, l=0x6C, y=0x79
        send_word({8'h75, 8'h6E, 8'h71, 8'h75, 8'h65, 8'h73, 8'h74,
                   8'h69, 8'h6F, 8'h6E, 8'h61, 8'h62, 8'h6C, 8'h79,
                   {18{8'h00}}}, 14);
        verify_tokens(4, 16'd4895, 16'd15500, 16'd3258, 16'd8231);

        // ----------------------------------------------------------
        // Summary
        // ----------------------------------------------------------
        $display("\n============================================");
        $display(" All tests complete");
        $display("============================================");

        repeat(20) @(posedge clk);
        $finish;
    end

    // ========================================================================
    // Timeout Watchdog
    // ========================================================================
    initial begin
        #5_000_000; // 5ms at 1ns resolution (longer for backtracking tests)
        $display("ERROR: Simulation timed out!");
        $finish;
    end

endmodule