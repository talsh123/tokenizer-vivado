`timescale 1ns / 1ps

// ============================================================================
// tb_h1_bug_investigation.v
//
// Standalone testbench for H1 bug investigation.
// Tests 11 multi-piece words from HuggingFace ground truth to verify
// that no spurious [UNK] (token 100) is emitted after the final piece.
//
// H1 detection criteria:
//   - Any token 100 ([UNK]) on clean lowercase ASCII input = Variant A
//   - Token count mismatch vs HuggingFace reference = Variant B
//
// Ground truth generated with:
//   from transformers import BertTokenizer
//   tok = BertTokenizer.from_pretrained("bert-base-uncased")
//   tok.encode(word, add_special_tokens=False)
//
// ============================================================================

module tb_h1_bug_investigation;

    parameter CHAR_W     = 10;
    parameter TOKEN_W    = 16;
    parameter CLK_PERIOD = 10;

    reg                 clk;
    reg                 rst;
    reg  [7:0]          fifo_in_data;
    reg                 fifo_in_valid;
    wire                fifo_in_ready;
    wire [TOKEN_W-1:0]  fifo_out_data;
    wire                fifo_out_valid;

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

    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    reg [TOKEN_W-1:0] captured_tokens [0:31];
    integer           token_count;

    always @(posedge clk) begin
        if (rst)
            token_count <= 0;
        else if (fifo_out_valid) begin
            captured_tokens[token_count] <= fifo_out_data;
            token_count <= token_count + 1;
        end
    end

    integer test_num;
    integer total_errors;
    integer total_tests;
    integer unk_count;

    // ========================================================================
    // Helper tasks
    // ========================================================================

    task send_byte;
        input [7:0] ascii_byte;
        begin
            @(posedge clk);
            while (!fifo_in_ready) @(posedge clk);
            fifo_in_data  <= ascii_byte;
            fifo_in_valid <= 1'b1;
            @(posedge clk);
            fifo_in_valid <= 1'b0;
            @(posedge clk);
        end
    endtask

    task send_string;
        input [255:0] str_packed;
        input integer str_len;
        integer i;
        reg [7:0] ch;
        begin
            for (i = 0; i < str_len; i = i + 1) begin
                ch = str_packed[8*(31-i) +: 8];
                send_byte(ch);
            end
            repeat(500) @(posedge clk);
        end
    endtask

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
                $display("  FAIL: Expected %0d tokens, got %0d", num_expected, token_count);
                pass = 1'b0;
            end else begin
                for (j = 0; j < num_expected; j = j + 1) begin
                    if (captured_tokens[j] !== expected[j]) begin
                        $display("  FAIL: Token[%0d] expected %0d, got %0d", j, expected[j], captured_tokens[j]);
                        pass = 1'b0;
                    end
                end
            end

            for (j = 0; j < token_count; j = j + 1) begin
                if (captured_tokens[j] == 16'd100) begin
                    $display("  *** H1 VARIANT A: Spurious [UNK] at Token[%0d] ***", j);
                    unk_count = unk_count + 1;
                end
            end

            if (pass)
                $display("  PASS!");
            else begin
                $display("  *** TEST FAILED ***");
                total_errors = total_errors + 1;
            end

            for (j = 0; j < token_count; j = j + 1)
                $display("    Token[%0d] = %0d", j, captured_tokens[j]);

            total_tests = total_tests + 1;
            token_count <= 0;
            @(posedge clk);
        end
    endtask

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
                $display("  FAIL: Expected %0d tokens, got %0d", num_expected, token_count);
                pass = 1'b0;
            end else begin
                for (j = 0; j < num_expected; j = j + 1) begin
                    if (captured_tokens[j] !== expected[j]) begin
                        $display("  FAIL: Token[%0d] expected %0d, got %0d", j, expected[j], captured_tokens[j]);
                        pass = 1'b0;
                    end
                end
            end

            for (j = 0; j < token_count; j = j + 1) begin
                if (captured_tokens[j] == 16'd100) begin
                    $display("  *** H1 VARIANT A: Spurious [UNK] at Token[%0d] ***", j);
                    unk_count = unk_count + 1;
                end
            end

            if (pass)
                $display("  PASS!");
            else begin
                $display("  *** TEST FAILED ***");
                total_errors = total_errors + 1;
            end

            for (j = 0; j < token_count; j = j + 1)
                $display("    Token[%0d] = %0d", j, captured_tokens[j]);

            total_tests = total_tests + 1;
            token_count <= 0;
            @(posedge clk);
        end
    endtask

    // ========================================================================
    // Main test sequence
    // ========================================================================
    initial begin
        rst           = 1'b1;
        fifo_in_data  = 8'h00;
        fifo_in_valid = 1'b0;
        token_count   = 0;
        total_errors  = 0;
        total_tests   = 0;
        unk_count     = 0;

        repeat(10) @(posedge clk);
        rst = 1'b0;
        repeat(5) @(posedge clk);

        $display("============================================");
        $display(" H1 Bug Investigation Testbench");
        $display(" 11 multi-piece words from HuggingFace");
        $display("============================================");

        // ----------------------------------------------------------
        // Test 1: "embedding " -> [7861, 8270, 4667] (3 tokens)
        // em + ##bed + ##ding
        // ----------------------------------------------------------
        test_num = 1;
        $display("\n===== TEST %0d: \"embedding\" (3 tokens) =====", test_num);
        send_string({8'h65, 8'h6D, 8'h62, 8'h65, 8'h64, 8'h64, 8'h69, 8'h6E,
                     8'h67, 8'h20, {22{8'h00}}}, 10);
        verify_tokens(3, 16'd7861, 16'd8270, 16'd4667, 16'd0);

        // ----------------------------------------------------------
        // Test 2: "unquestionably " -> [4895, 15500, 3258, 8231] (4 tokens)
        // un + ##quest + ##ion + ##ably
        // ----------------------------------------------------------
        test_num = 2;
        $display("\n===== TEST %0d: \"unquestionably\" (4 tokens) =====", test_num);
        send_string({8'h75, 8'h6E, 8'h71, 8'h75, 8'h65, 8'h73, 8'h74,
                     8'h69, 8'h6F, 8'h6E, 8'h61, 8'h62, 8'h6C, 8'h79,
                     8'h20, {17{8'h00}}}, 15);
        verify_tokens(4, 16'd4895, 16'd15500, 16'd3258, 16'd8231);

        // ----------------------------------------------------------
        // Test 3: "internationalization " -> [2248, 3989] (2 tokens)
        // international + ##ization
        // ----------------------------------------------------------
        test_num = 3;
        $display("\n===== TEST %0d: \"internationalization\" (2 tokens) =====", test_num);
        send_string({8'h69, 8'h6E, 8'h74, 8'h65, 8'h72, 8'h6E, 8'h61, 8'h74,
                     8'h69, 8'h6F, 8'h6E, 8'h61, 8'h6C, 8'h69, 8'h7A, 8'h61,
                     8'h74, 8'h69, 8'h6F, 8'h6E, 8'h20, {11{8'h00}}}, 21);
        verify_tokens(2, 16'd2248, 16'd3989, 16'd0, 16'd0);

        // ----------------------------------------------------------
        // Test 4: "snowboarding " -> [4586, 21172] (2 tokens)
        // snow + ##boarding
        // ----------------------------------------------------------
        test_num = 4;
        $display("\n===== TEST %0d: \"snowboarding\" (2 tokens) =====", test_num);
        send_string({8'h73, 8'h6E, 8'h6F, 8'h77, 8'h62, 8'h6F, 8'h61, 8'h72,
                     8'h64, 8'h69, 8'h6E, 8'h67, 8'h20, {19{8'h00}}}, 13);
        verify_tokens(2, 16'd4586, 16'd21172, 16'd0, 16'd0);

        // ----------------------------------------------------------
        // Test 5: "tokenization " -> [19204, 3989] (2 tokens)
        // token + ##ization
        // ----------------------------------------------------------
        test_num = 5;
        $display("\n===== TEST %0d: \"tokenization\" (2 tokens) =====", test_num);
        send_string({8'h74, 8'h6F, 8'h6B, 8'h65, 8'h6E, 8'h69, 8'h7A, 8'h61,
                     8'h74, 8'h69, 8'h6F, 8'h6E, 8'h20, {19{8'h00}}}, 13);
        verify_tokens(2, 16'd19204, 16'd3989, 16'd0, 16'd0);

        // ----------------------------------------------------------
        // Test 6: "tokenizer " -> [19204, 17629] (2 tokens)
        // token + ##izer
        // ----------------------------------------------------------
        test_num = 6;
        $display("\n===== TEST %0d: \"tokenizer\" (2 tokens) =====", test_num);
        send_string({8'h74, 8'h6F, 8'h6B, 8'h65, 8'h6E, 8'h69, 8'h7A, 8'h65,
                     8'h72, 8'h20, {22{8'h00}}}, 10);
        verify_tokens(2, 16'd19204, 16'd17629, 16'd0, 16'd0);

        // ----------------------------------------------------------
        // Test 7: "nanotechnology " -> [28991, 15007, 21020] (3 tokens)
        // nano + ##tech + ##nology
        // ----------------------------------------------------------
        test_num = 7;
        $display("\n===== TEST %0d: \"nanotechnology\" (3 tokens) =====", test_num);
        send_string({8'h6E, 8'h61, 8'h6E, 8'h6F, 8'h74, 8'h65, 8'h63, 8'h68,
                     8'h6E, 8'h6F, 8'h6C, 8'h6F, 8'h67, 8'h79, 8'h20,
                     {17{8'h00}}}, 15);
        verify_tokens(3, 16'd28991, 16'd15007, 16'd21020, 16'd0);

        // ----------------------------------------------------------
        // Test 8: "multiprocessing " -> [4800, 21572, 9623, 7741] (4 tokens)
        // multi + ##pro + ##ces + ##sing
        // ----------------------------------------------------------
        test_num = 8;
        $display("\n===== TEST %0d: \"multiprocessing\" (4 tokens) =====", test_num);
        send_string({8'h6D, 8'h75, 8'h6C, 8'h74, 8'h69, 8'h70, 8'h72, 8'h6F,
                     8'h63, 8'h65, 8'h73, 8'h73, 8'h69, 8'h6E, 8'h67, 8'h20,
                     {16{8'h00}}}, 16);
        verify_tokens(4, 16'd4800, 16'd21572, 16'd9623, 16'd7741);

        // ----------------------------------------------------------
        // Test 9: "preprocessing " -> [17463, 3217, 9623, 7741] (4 tokens)
        // prep + ##ro + ##ces + ##sing
        // ----------------------------------------------------------
        test_num = 9;
        $display("\n===== TEST %0d: \"preprocessing\" (4 tokens) =====", test_num);
        send_string({8'h70, 8'h72, 8'h65, 8'h70, 8'h72, 8'h6F, 8'h63, 8'h65,
                     8'h73, 8'h73, 8'h69, 8'h6E, 8'h67, 8'h20,
                     {18{8'h00}}}, 14);
        verify_tokens(4, 16'd17463, 16'd3217, 16'd9623, 16'd7741);

        // ----------------------------------------------------------
        // Test 10: "microcontroller " -> [12702, 8663, 13181, 10820] (4 tokens)
        // micro + ##con + ##tro + ##ller
        // ----------------------------------------------------------
        test_num = 10;
        $display("\n===== TEST %0d: \"microcontroller\" (4 tokens) =====", test_num);
        send_string({8'h6D, 8'h69, 8'h63, 8'h72, 8'h6F, 8'h63, 8'h6F, 8'h6E,
                     8'h74, 8'h72, 8'h6F, 8'h6C, 8'h6C, 8'h65, 8'h72, 8'h20,
                     {16{8'h00}}}, 16);
        verify_tokens(4, 16'd12702, 16'd8663, 16'd13181, 16'd10820);

        // ----------------------------------------------------------
        // Test 11: "cryptocurrency " -> [19888, 10085, 3126, 7389, 5666] (5 tokens)
        // crypt + ##oc + ##ur + ##ren + ##cy
        // THIS IS THE WORD THAT ORIGINALLY TRIGGERED H1
        // ----------------------------------------------------------
        test_num = 11;
        $display("\n===== TEST %0d: \"cryptocurrency\" (5 tokens) - H1 TRIGGER WORD =====", test_num);
        send_string({8'h63, 8'h72, 8'h79, 8'h70, 8'h74, 8'h6F, 8'h63, 8'h75,
                     8'h72, 8'h72, 8'h65, 8'h6E, 8'h63, 8'h79, 8'h20,
                     {17{8'h00}}}, 15);
        verify_tokens_8(5, 16'd19888, 16'd10085, 16'd3126, 16'd7389,
                           16'd5666, 16'd0, 16'd0, 16'd0);

        // ==============================================================
        // Summary
        // ==============================================================
        $display("\n============================================");
        $display(" H1 BUG INVESTIGATION RESULTS");
        $display("============================================");
        $display(" Tests run: %0d", total_tests);
        $display(" Failures: %0d", total_errors);
        $display(" [UNK] appearances: %0d", unk_count);
        $display("============================================");
        if (total_errors == 0 && unk_count == 0)
            $display(" ALL TESTS PASSED - H1 NOT TRIGGERED");
        else begin
            if (unk_count > 0)
                $display(" *** H1 VARIANT A DETECTED: %0d spurious [UNK] ***", unk_count);
            if (total_errors > 0 && unk_count == 0)
                $display(" *** POSSIBLE H1 VARIANT B: check token counts ***");
        end
        $display("============================================");

        repeat(20) @(posedge clk);
        $finish;
    end

    initial begin
        #20_000_000;
        $display("ERROR: Simulation timed out!");
        $finish;
    end

endmodule