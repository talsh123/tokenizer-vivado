`timescale 1ns / 1ps

// ============================================================================
// tb_h1_h2_m1.v
//
// Regression + targeted testbench for the bug fixes applied to trie_engine.v:
//
//   H1 - Spurious [UNK]/dropped token when a word boundary lands during a
//        backtrack replay. Decisive detector: a CORRECT tokenizer never emits
//        [UNK] (token 100) for plain a-z/0-9 input, because every single
//        letter/digit is its own vocab token. So ANY 100 on English words = bug,
//        and a wrong token COUNT on a known multi-piece word = dropped/extra token.
//
//   H2 - Binary-search index underflow (bs_hi = mid-1 at mid==0). Latent on the
//        current vocab and not deterministically reachable from a black-box
//        testbench, but the fixed code path (the "edge > target" branch) is
//        exercised heavily by every longest-match dead-end in the multi-piece
//        words below. If those still pass, the guard is correct and benign.
//
//   M1 - Over-long word (> buffer capacity) used to wrap buf_end and corrupt the
//        buffer. Now it must NOT hang, must emit a single [UNK] (100) sentinel,
//        and the engine must recover (the next word tokenizes correctly).
//
// This drives trie_engine directly with mapped alphabet indices (like
// tb_trie_engine.v). Run it with tb_h1_h2_m1 set as the simulation top.
//
// Expected result on the FIXED RTL:  "ALL FIX TESTS PASSED".
// On the UNFIXED RTL you should see H1 failures (extra/short token counts and/or
// 100s) and, for M1, a corrupted/hung over-long-word result.
// ============================================================================

module tb_h1_h2_m1;

    // ------------------------------------------------------------------ params
    parameter ROOT_NUM_NODES = 56719;
    parameter ROOT_NUM_EDGES = 56718;
    parameter CONT_NUM_NODES = 7864;
    parameter CONT_NUM_EDGES = 7863;
    parameter TOKEN_W        = 16;
    parameter NODE_W         = 17;
    parameter EDGE_ADDR_W    = 16;
    parameter CHAR_W         = 10;
    parameter BUF_DEPTH      = 32;
    parameter CLK_PERIOD     = 10;     // 100 MHz

    localparam [TOKEN_W-1:0] UNK = 16'd100;

    // ------------------------------------------------------------------ signals
    reg                 clk;
    reg                 rst;
    reg  [CHAR_W-1:0]   in_char;
    reg                 in_char_valid;
    reg                 in_word_done;
    wire                ready;
    wire [TOKEN_W-1:0]  out_token_id;
    wire                out_token_valid;

    // ------------------------------------------------------------------ DUT
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

    // ------------------------------------------------------------------ clock
    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // ------------------------------------------------------------------ char map
    reg [CHAR_W-1:0] char_map [0:127];
    integer cm_i;
    initial begin
        for (cm_i = 0; cm_i < 128; cm_i = cm_i + 1)
            char_map[cm_i] = {CHAR_W{1'b1}};
        $readmemh("char_to_index_map.mem", char_map);
    end

    // ------------------------------------------------------------------ capture
    reg [TOKEN_W-1:0] captured [0:127];
    integer           token_count;

    always @(posedge clk) begin
        if (rst)
            token_count <= 0;
        else if (out_token_valid) begin
            captured[token_count] <= out_token_id;
            token_count <= token_count + 1;
        end
    end

    integer total_errors;

    // ------------------------------------------------------------------ drivers
    // send one ASCII char (mapped) respecting backpressure
    task send_char;
        input [7:0] ascii;
        reg [CHAR_W-1:0] mapped;
        begin
            mapped = char_map[ascii[6:0]];
            while (!ready) @(posedge clk);
            in_char       <= mapped;
            in_char_valid <= 1'b1;
            @(posedge clk);
            in_char_valid <= 1'b0;
            @(posedge clk);
        end
    endtask

    // send a word stored as a right-justified string literal, then word_done
    task send_str;
        input [8*32-1:0] str;
        input integer    len;
        integer k;
        reg [7:0] ch;
        begin
            for (k = 0; k < len; k = k + 1) begin
                ch = str[8*(len-1-k) +: 8];   // k-th char from the left
                send_char(ch);
            end
            @(posedge clk);
            in_word_done <= 1'b1;
            @(posedge clk);
            in_word_done <= 1'b0;
            repeat (1000) @(posedge clk);     // allow backtracking + emission
        end
    endtask

    // send the same char 'n' times then word_done (for over-long M1 word)
    task send_repeated;
        input [7:0] ascii;
        input integer n;
        integer k;
        begin
            for (k = 0; k < n; k = k + 1)
                send_char(ascii);
            @(posedge clk);
            in_word_done <= 1'b1;
            @(posedge clk);
            in_word_done <= 1'b0;
            repeat (1500) @(posedge clk);     // extra time to drain a long word
        end
    endtask

    task clear_capture;
        begin
            token_count <= 0;
            @(posedge clk);
        end
    endtask

    // print the captured token IDs for the current test (detailed transcript)
    task print_tokens;
        integer i;
        begin
            $write("       -> tokens:");
            if (token_count == 0) $write(" (none)");
            for (i = 0; i < token_count; i = i + 1)
                $write(" %0d", captured[i]);
            $display("");
        end
    endtask

    // ------------------------------------------------------------------ checkers
    integer ci;
    integer found_unk;

    // exact match against up to 4 expected IDs (also catches stray 100s)
    task check_exact;
        input [8*48-1:0] name;
        input integer     n;
        input [TOKEN_W-1:0] e0, e1, e2, e3;
        reg [TOKEN_W-1:0] exp [0:3];
        reg pass;
        begin
            exp[0]=e0; exp[1]=e1; exp[2]=e2; exp[3]=e3;
            pass = 1'b1;
            if (token_count !== n) begin
                $display("  [%s] FAIL: expected %0d tokens, got %0d", name, n, token_count);
                pass = 1'b0;
            end else begin
                for (ci = 0; ci < n; ci = ci + 1)
                    if (captured[ci] !== exp[ci]) begin
                        $display("  [%s] FAIL: token[%0d] expected %0d, got %0d",
                                 name, ci, exp[ci], captured[ci]);
                        pass = 1'b0;
                    end
            end
            if (pass) $display("  [%s] PASS (%0d tokens, exact match)", name, token_count);
            else      total_errors = total_errors + 1;
            print_tokens;
            clear_capture;
        end
    endtask

    // invariant for any real a-z/0-9 word: at least one token, and NO [UNK]
    task check_no_unk;
        input [8*48-1:0] name;
        reg pass;
        begin
            pass = 1'b1;
            found_unk = 0;
            for (ci = 0; ci < token_count; ci = ci + 1)
                if (captured[ci] === UNK) found_unk = 1;
            if (token_count == 0) begin
                $display("  [%s] FAIL: no tokens emitted", name); pass = 1'b0;
            end
            if (found_unk) begin
                $display("  [%s] FAIL: output contains [UNK]=100 (H1 symptom)", name); pass = 1'b0;
            end
            if (pass) $display("  [%s] PASS (%0d tokens, no [UNK])", name, token_count);
            else      total_errors = total_errors + 1;
            print_tokens;
            clear_capture;
        end
    endtask

    // M1: over-long word must produce >=1 token and contain a [UNK] sentinel
    task check_has_unk;
        input [8*48-1:0] name;
        reg pass;
        begin
            pass = 1'b0;
            for (ci = 0; ci < token_count; ci = ci + 1)
                if (captured[ci] === UNK) pass = 1'b1;
            if (pass) $display("  [%s] PASS (%0d tokens, contains [UNK] sentinel as required)",
                               name, token_count);
            else begin
                $display("  [%s] FAIL: over-long word did not emit [UNK] (count=%0d)",
                         name, token_count);
                total_errors = total_errors + 1;
            end
            print_tokens;
            clear_capture;
        end
    endtask

    // ------------------------------------------------------------------ stimulus
    initial begin
        rst           = 1'b1;
        in_char       = {CHAR_W{1'b0}};
        in_char_valid = 1'b0;
        in_word_done  = 1'b0;
        token_count   = 0;
        total_errors  = 0;

        repeat (10) @(posedge clk);
        rst = 1'b0;
        repeat (5) @(posedge clk);

        $display("============================================================");
        $display(" tb_h1_h2_m1 : regression + H1 / H2 / M1 targeted tests");
        $display("============================================================");

        // ---- Section A : regression (known-good vectors, exact match) --------
        // These exercise the H2-fixed binary-search branch on every dead-end and
        // the H1 backtracking/word-done path on the multi-piece words.
        $display("\n-- Section A: regression (exact match) --");
        send_str("hello", 5);            check_exact("hello",          1, 16'd7592, 0, 0, 0);
        send_str("hardware", 8);         check_exact("hardware",       1, 16'd8051, 0, 0, 0);
        send_str("embedding", 9);        check_exact("embedding",      3, 16'd7861, 16'd8270, 16'd4667, 0);
        send_str("unquestionably", 14);  check_exact("unquestionably", 4, 16'd4895, 16'd15500, 16'd3258, 16'd8231);

        // ---- Section B : H1 broad coverage (multi-piece, must have NO [UNK]) --
        // A correct tokenizer never returns 100 for these. Any 100 = H1 Variant A.
        $display("\n-- Section B: H1 invariant (no [UNK] on real words) --");
        send_str("tokenization", 12);     check_no_unk("tokenization");
        send_str("snowboarding", 12);     check_no_unk("snowboarding");
        send_str("preprocessing", 13);    check_no_unk("preprocessing");
        send_str("biotechnology", 13);    check_no_unk("biotechnology");
        send_str("misunderstanding", 16); check_no_unk("misunderstanding");
        send_str("transformation", 14);   check_no_unk("transformation");
        send_str("microcontroller", 15);  check_no_unk("microcontroller");
        send_str("internationalization", 20); check_no_unk("internationalization");

        // ---- Section C : M1 over-long word handling --------------------------
        $display("\n-- Section C: M1 over-long word --");
        // 40 identical chars (> BUF_DEPTH=32): must not hang/corrupt and must
        // flush a [UNK] sentinel.
        send_repeated("a", 40);          check_has_unk("aaaa..x40 (over-long)");
        // recovery: a normal word right after must tokenize correctly -> clean reset
        send_str("hello", 5);            check_exact("hello (after over-long)", 1, 16'd7592, 0, 0, 0);
        // control: a long-but-fitting real word (<=31 chars) must have NO [UNK]
        send_str("antidisestablishmentarianism", 28); check_no_unk("antidisestablishmentarianism (28<=31)");

        // ---- summary ---------------------------------------------------------
        $display("\n============================================================");
        if (total_errors == 0) $display(" ALL FIX TESTS PASSED");
        else                   $display(" %0d FIX TEST(S) FAILED", total_errors);
        $display("============================================================");

        repeat (20) @(posedge clk);
        $finish;
    end

    // ------------------------------------------------------------------ watchdog
    initial begin
        #5_000_000;   // 5 ms : if we get here, the FSM hung (e.g. M1 corruption)
        $display("ERROR: simulation TIMED OUT -- likely a hang (check M1/H2).");
        $display(" %0d FIX TEST(S) FAILED (timeout)", total_errors + 1);
        $finish;
    end

endmodule
