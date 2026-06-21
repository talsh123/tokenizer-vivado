`timescale 1ns / 1ps

// ============================================================================
// tb_axi_pipeline.v
//
// AXI-level testbench that mirrors the (new) MicroBlaze firmware flow to verify
// two changes together:
//
//   P1  (pre-tokenizer pure flow control): a word's first character is never lost
//        across a word boundary -> multi-word sentences tokenize correctly.
//   M4  (pipeline_busy STATUS bit + deterministic drain): software waits on
//        STATUS bit 3 instead of a fixed delay, and the drain retrieves EVERY
//        token (no early exit, no blind delay).
//
// For each test it does exactly what echo.c now does:
//   - write each byte to TX_DATA (polling STATUS bit 0 for input space),
//     draining any already-available tokens after each byte;
//   - then run the final drain:  while (pipeline_busy() || has_token()) drain;
// and then checks the collected token IDs against the known-good values and that
// the pipeline returned fully idle (STATUS bits 1 and 3 both low).
//
// STATUS bits: 0 = input has space, 1 = token available, 3 = pipeline busy.
//
// Expected on the fixed RTL+flow: "AXI PIPELINE TESTS PASSED".
// Needs the same .mem files as the other sims.
// ============================================================================

module tb_axi_pipeline;

    parameter C_S_AXI_DATA_WIDTH = 32;
    parameter C_S_AXI_ADDR_WIDTH = 4;
    parameter CLK_PERIOD         = 10;   // 100 MHz

    localparam ADDR_TX_DATA = 4'h0;
    localparam ADDR_RX_DATA = 4'h4;
    localparam ADDR_STATUS  = 4'h8;

    // ------------------------------------------------------------------ signals
    reg                            clk;
    reg                            aresetn;

    reg  [C_S_AXI_ADDR_WIDTH-1:0]  s_axi_awaddr;
    reg                            s_axi_awvalid;
    wire                           s_axi_awready;
    reg  [C_S_AXI_DATA_WIDTH-1:0]  s_axi_wdata;
    reg  [3:0]                     s_axi_wstrb;
    reg                            s_axi_wvalid;
    wire                           s_axi_wready;
    wire [1:0]                     s_axi_bresp;
    wire                           s_axi_bvalid;
    reg                            s_axi_bready;
    reg  [C_S_AXI_ADDR_WIDTH-1:0]  s_axi_araddr;
    reg                            s_axi_arvalid;
    wire                           s_axi_arready;
    wire [C_S_AXI_DATA_WIDTH-1:0]  s_axi_rdata;
    wire [1:0]                     s_axi_rresp;
    wire                           s_axi_rvalid;
    reg                            s_axi_rready;

    // ------------------------------------------------------------------ DUT (default 256-deep FIFOs)
    tokenizer_axi_lite #(
        .C_S_AXI_DATA_WIDTH (C_S_AXI_DATA_WIDTH),
        .C_S_AXI_ADDR_WIDTH (C_S_AXI_ADDR_WIDTH)
    ) uut (
        .s_axi_aclk     (clk),
        .s_axi_aresetn  (aresetn),
        .s_axi_awaddr   (s_axi_awaddr),
        .s_axi_awvalid  (s_axi_awvalid),
        .s_axi_awready  (s_axi_awready),
        .s_axi_wdata    (s_axi_wdata),
        .s_axi_wstrb    (s_axi_wstrb),
        .s_axi_wvalid   (s_axi_wvalid),
        .s_axi_wready   (s_axi_wready),
        .s_axi_bresp    (s_axi_bresp),
        .s_axi_bvalid   (s_axi_bvalid),
        .s_axi_bready   (s_axi_bready),
        .s_axi_araddr   (s_axi_araddr),
        .s_axi_arvalid  (s_axi_arvalid),
        .s_axi_arready  (s_axi_arready),
        .s_axi_rdata    (s_axi_rdata),
        .s_axi_rresp    (s_axi_rresp),
        .s_axi_rvalid   (s_axi_rvalid),
        .s_axi_rready   (s_axi_rready),
        // AXI-Stream ports unused in this AXI-Lite testbench (DMA datapath) -- tie inputs off
        .s_axis_tdata   (8'd0),
        .s_axis_tvalid  (1'b0),
        .s_axis_tlast   (1'b0),
        .m_axis_tready  (1'b0)
    );

    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    integer total_errors;
    integer saw_busy;                 // set if STATUS bit 3 was ever observed high
    reg [15:0] captured [0:63];
    reg [15:0] expected [0:15];
    integer    ntok;

    // ------------------------------------------------------------------ AXI tasks
    task axi_write;
        input [C_S_AXI_ADDR_WIDTH-1:0] addr;
        input [C_S_AXI_DATA_WIDTH-1:0] data;
        begin
            @(posedge clk);
            s_axi_awaddr  <= addr;  s_axi_awvalid <= 1'b1;
            s_axi_wdata   <= data;  s_axi_wstrb   <= 4'hF; s_axi_wvalid <= 1'b1;
            s_axi_bready  <= 1'b1;
            @(posedge clk);
            while (!(s_axi_awready || s_axi_wready)) @(posedge clk);
            if (s_axi_awready) s_axi_awvalid <= 1'b0;
            if (s_axi_wready)  s_axi_wvalid  <= 1'b0;
            @(posedge clk);
            s_axi_awvalid <= 1'b0; s_axi_wvalid <= 1'b0;
            while (!s_axi_bvalid) @(posedge clk);
            @(posedge clk);
            s_axi_bready <= 1'b0;
        end
    endtask

    task axi_read;
        input  [C_S_AXI_ADDR_WIDTH-1:0] addr;
        output [C_S_AXI_DATA_WIDTH-1:0] data;
        begin
            @(posedge clk);
            s_axi_araddr  <= addr; s_axi_arvalid <= 1'b1; s_axi_rready <= 1'b1;
            @(posedge clk);
            while (!s_axi_rvalid) @(posedge clk);
            data = s_axi_rdata;
            s_axi_arvalid <= 1'b0;
            @(posedge clk);
            s_axi_rready <= 1'b0;
        end
    endtask

    // write one byte to TX_DATA, polling input-has-space (STATUS bit 0)
    task tok_send_byte;
        input [7:0] b;
        reg [31:0] st;
        begin
            st = 0;
            while (!(st & 32'h1)) axi_read(ADDR_STATUS, st);
            axi_write(ADDR_TX_DATA, {24'd0, b});
        end
    endtask

    // collect every token currently available in the output FIFO
    task drain_available;
        reg [31:0] st;
        reg [31:0] rd;
        begin
            axi_read(ADDR_STATUS, st);
            while (st & 32'h2) begin           // bit 1 = token available
                axi_read(ADDR_RX_DATA, rd);
                captured[ntok] = rd[15:0];
                ntok = ntok + 1;
                axi_read(ADDR_STATUS, st);
            end
        end
    endtask

    // send a whole sentence exactly the way echo.c now does it
    task send_sentence;
        input [8*64-1:0] str;
        input integer    len;
        integer k;
        reg [7:0] ch;
        reg [31:0] st;
        reg [31:0] rd;
        begin
            ntok = 0;
            // send + interleaved drain
            for (k = 0; k < len; k = k + 1) begin
                ch = str[8*(len-1-k) +: 8];
                tok_send_byte(ch);
                drain_available;
            end
            // deterministic final drain: while (pipeline_busy || has_token) drain
            axi_read(ADDR_STATUS, st);
            while ((st & 32'h8) || (st & 32'h2)) begin   // bit 3 busy, bit 1 token
                if (st & 32'h8) saw_busy = 1;
                if (st & 32'h2) begin
                    axi_read(ADDR_RX_DATA, rd);
                    captured[ntok] = rd[15:0];
                    ntok = ntok + 1;
                end
                axi_read(ADDR_STATUS, st);
            end
        end
    endtask

    // same as send_sentence, but with a large idle gap between bytes to mimic the board's very
    // slow MMIO byte cadence (~3000 cycles/byte), where the trie goes fully idle between every
    // character. exposes finalization edges the fast (FIFO-buffered) path never hits.
    task send_sentence_slow;
        input [8*64-1:0] str;
        input integer    len;
        integer k;
        reg [7:0] ch;
        reg [31:0] st;
        reg [31:0] rd;
        begin
            ntok = 0;
            for (k = 0; k < len; k = k + 1) begin
                ch = str[8*(len-1-k) +: 8];
                tok_send_byte(ch);
                repeat (1000) @(posedge clk);   // big inter-byte idle gap (board is slower still)
                drain_available;
            end
            // deterministic final drain
            axi_read(ADDR_STATUS, st);
            while ((st & 32'h8) || (st & 32'h2)) begin
                if (st & 32'h8) saw_busy = 1;
                if (st & 32'h2) begin
                    axi_read(ADDR_RX_DATA, rd);
                    captured[ntok] = rd[15:0];
                    ntok = ntok + 1;
                end
                axi_read(ADDR_STATUS, st);
            end
        end
    endtask

    // compare collected tokens to expected[], and confirm the pipeline is idle
    task check_tokens;
        input [8*40-1:0] name;
        input integer    n;
        integer j;
        reg pass;
        reg [31:0] st;
        begin
            pass = 1'b1;
            if (ntok !== n) begin
                $display("  [%s] FAIL: expected %0d tokens, got %0d", name, n, ntok);
                $write("       got ->"); for (j=0;j<ntok;j=j+1) $write(" %0d", captured[j]); $display("");
                pass = 1'b0;
            end else begin
                for (j = 0; j < n; j = j + 1)
                    if (captured[j] !== expected[j]) begin
                        $display("  [%s] FAIL: token[%0d] expected %0d, got %0d",
                                 name, j, expected[j], captured[j]);
                        pass = 1'b0;
                    end
            end
            // pipeline must be fully idle now (no leftover token, not busy)
            axi_read(ADDR_STATUS, st);
            if (st & 32'h2) begin
                $display("  [%s] FAIL: token still available after drain (STATUS=0x%08x)", name, st);
                pass = 1'b0;
            end
            if (st & 32'h8) begin
                $display("  [%s] FAIL: pipeline still busy after drain (STATUS=0x%08x)", name, st);
                pass = 1'b0;
            end
            if (pass) begin
                $write("  [%s] PASS (%0d tokens) ->", name, ntok);
                for (j = 0; j < ntok; j = j + 1) $write(" %0d", captured[j]);
                $display("");
            end else
                total_errors = total_errors + 1;
        end
    endtask

    // L2: digit / alphanumeric coverage. Plain a-z/0-9 input can never legitimately produce
    // [UNK] (token 100) -- every single character is itself a token -- so this checks the
    // invariant (no 100, at least one token, pipeline returns idle) without needing reference IDs.
    // Digits map to alphabet indices below the letters, so this also exercises the binary-search
    // lower bound that H2 hardened.
    task check_no_unk;
        input [8*40-1:0] name;
        integer j;
        reg pass;
        reg [31:0] st;
        begin
            pass = 1'b1;
            if (ntok == 0) begin
                $display("  [%s] FAIL: no tokens produced", name);
                pass = 1'b0;
            end
            for (j = 0; j < ntok; j = j + 1)
                if (captured[j] === 16'd100) begin
                    $display("  [%s] FAIL: spurious [UNK] (100) at token %0d", name, j);
                    pass = 1'b0;
                end
            axi_read(ADDR_STATUS, st);
            if (st & 32'h2) begin
                $display("  [%s] FAIL: token still available after drain (STATUS=0x%08x)", name, st);
                pass = 1'b0;
            end
            if (st & 32'h8) begin
                $display("  [%s] FAIL: pipeline still busy after drain (STATUS=0x%08x)", name, st);
                pass = 1'b0;
            end
            if (pass) begin
                $write("  [%s] PASS (%0d tokens, no [UNK]) ->", name, ntok);
                for (j = 0; j < ntok; j = j + 1) $write(" %0d", captured[j]);
                $display("");
            end else
                total_errors = total_errors + 1;
        end
    endtask

    // ------------------------------------------------------------------ stimulus
    initial begin
        aresetn = 1'b0;
        s_axi_awaddr=0; s_axi_awvalid=0; s_axi_wdata=0; s_axi_wstrb=0; s_axi_wvalid=0; s_axi_bready=0;
        s_axi_araddr=0; s_axi_arvalid=0; s_axi_rready=0;
        total_errors = 0; saw_busy = 0; ntok = 0;

        repeat (10) @(posedge clk);
        aresetn = 1'b1;
        repeat (5) @(posedge clk);

        $display("============================================================");
        $display(" tb_axi_pipeline : multi-word + pipeline_busy drain (P1 / M4)");
        $display("============================================================");

        // Test 1 - two single-token words across a boundary (P1).
        send_sentence("hello hardware ", 15);
        expected[0]=16'd7592; expected[1]=16'd8051;
        check_tokens("hello hardware", 2);

        // Test 2 - one multi-piece word (M4 drains several tokens from one word).
        send_sentence("embedding ", 10);
        expected[0]=16'd7861; expected[1]=16'd8270; expected[2]=16'd4667;
        check_tokens("embedding", 3);

        // Test 3 - multi-piece + boundary + multi-piece (P1 stress: the 'u' of the
        // second word must not be lost right after the first word's tokens emit).
        send_sentence("embedding unquestionably ", 25);
        expected[0]=16'd7861; expected[1]=16'd8270; expected[2]=16'd4667;
        expected[3]=16'd4895; expected[4]=16'd15500; expected[5]=16'd3258; expected[6]=16'd8231;
        check_tokens("embedding unquestionably", 7);

        // Test 4 - 9-word pangram (thorough multi-word, known-good IDs).
        send_sentence("the quick brown fox jumps over the lazy dog ", 44);
        expected[0]=16'd1996;  expected[1]=16'd4248;  expected[2]=16'd2829;
        expected[3]=16'd4419;  expected[4]=16'd14523; expected[5]=16'd2058;
        expected[6]=16'd1996;  expected[7]=16'd13971; expected[8]=16'd3899;
        check_tokens("pangram", 9);

        // Test 5 - "embed " on its own. Reproduces the on-board spurious [UNK] (100):
        // "embed" = em + ##bed; its continuation replay ends exactly at the buffer end on a
        // terminal-with-children node. tb_tokenizer_axi_lite (fast, FIFO-buffered) tokenizes it
        // correctly, but the firmware's drain-while-sending feeds bytes slowly with idle gaps,
        // which is what this testbench mimics.
        send_sentence("embed ", 6);
        expected[0]=16'd7861; expected[1]=16'd8270;
        check_tokens("embed", 2);

        // Test 6 - "embed hardware ": embed followed by another word (the on-board "embed ding"
        // shape, with a known second word). A spurious [UNK] would appear between 8270 and 8051.
        send_sentence("embed hardware ", 15);
        expected[0]=16'd7861; expected[1]=16'd8270; expected[2]=16'd8051;
        check_tokens("embed hardware", 3);

        // Test 7 - "embed " under the board's SLOW byte cadence (trie idle between every char).
        // On the board this returns the spurious 7861 8270 100; the fast tests above do not.
        send_sentence_slow("embed ", 6);
        expected[0]=16'd7861; expected[1]=16'd8270;
        check_tokens("embed (slow)", 2);

        // Test 8 - "embed hardware " slow (board "embed ding"/"embed hardware" shape).
        send_sentence_slow("embed hardware ", 15);
        expected[0]=16'd7861; expected[1]=16'd8270; expected[2]=16'd8051;
        check_tokens("embed hardware (slow)", 3);

        // Test 9 - digit / alphanumeric coverage (L2). Pure a-z/0-9 words must tokenize with no
        // [UNK]; exercises digit alphabet indices (below the letters) through the trie search.
        send_sentence("2024 ", 5);
        check_no_unk("digits 2024");
        send_sentence("abc123 ", 7);
        check_no_unk("alnum abc123");

        // M4 sanity: STATUS bit 3 must have actually asserted during the run
        // (otherwise the drain would be relying on bit 1 alone / the bit is stuck low).
        if (!saw_busy) begin
            $display("  [pipeline_busy] FAIL: STATUS bit 3 never observed high");
            total_errors = total_errors + 1;
        end else
            $display("  [pipeline_busy] PASS (STATUS bit 3 observed high during processing)");

        $display("============================================================");
        if (total_errors == 0) $display(" AXI PIPELINE TESTS PASSED");
        else                   $display(" AXI PIPELINE TESTS FAILED (%0d error(s))", total_errors);
        $display("============================================================");

        repeat (20) @(posedge clk);
        $finish;
    end

    // ===== TEMP DEBUG PROBE (char handoff at the embed->hardware boundary) =====
    always @(posedge clk) begin
        if (uut.u_tokenizer.pt_out_char_valid)
            $display("[%0t] CHAR idx=%0d -> trie | ready=%b state=%0d rep=%b wdp=%b pcv=%b best_end=%0d buf_end=%0d wact=%b",
                $time, uut.u_tokenizer.pt_out_char,
                uut.u_tokenizer.u_trie_engine.ready,
                uut.u_tokenizer.u_trie_engine.state,
                uut.u_tokenizer.u_trie_engine.replaying,
                uut.u_tokenizer.u_trie_engine.word_done_pending,
                uut.u_tokenizer.u_trie_engine.pending_char_valid,
                uut.u_tokenizer.u_trie_engine.best_end,
                uut.u_tokenizer.u_trie_engine.buf_end,
                uut.u_tokenizer.u_trie_engine.word_active);
        if (uut.u_tokenizer.pt_out_word_done)
            $display("[%0t] WORD_DONE -> trie | ready=%b state=%0d rep=%b best_end=%0d buf_end=%0d",
                $time, uut.u_tokenizer.u_trie_engine.ready,
                uut.u_tokenizer.u_trie_engine.state,
                uut.u_tokenizer.u_trie_engine.replaying,
                uut.u_tokenizer.u_trie_engine.best_end,
                uut.u_tokenizer.u_trie_engine.buf_end);
        // every S_EMIT cycle: shows whether it will emit a real token or a forced [UNK]
        // (has_best=0), plus the pointers that drive the finalize-vs-replay decision.
        if (uut.u_tokenizer.u_trie_engine.state == 4'd9)
            $display("[%0t] S_EMIT | has_best=%b best_tid=%0d best_end=%0d buf_end=%0d m_start=%0d scan_ptr=%0d wdp=%b rep=%b pcv=%b",
                $time,
                uut.u_tokenizer.u_trie_engine.has_best_match,
                uut.u_tokenizer.u_trie_engine.best_match_tid,
                uut.u_tokenizer.u_trie_engine.best_end,
                uut.u_tokenizer.u_trie_engine.buf_end,
                uut.u_tokenizer.u_trie_engine.m_start,
                uut.u_tokenizer.u_trie_engine.scan_ptr,
                uut.u_tokenizer.u_trie_engine.word_done_pending,
                uut.u_tokenizer.u_trie_engine.replaying,
                uut.u_tokenizer.u_trie_engine.pending_char_valid);
        if (uut.u_tokenizer.u_trie_engine.out_token_valid)
            $display("[%0t] EMIT %0d", $time, uut.u_tokenizer.u_trie_engine.out_token_id);
    end
    // ===== END TEMP DEBUG PROBE =====

    // ------------------------------------------------------------------ watchdog
    initial begin
        #20_000_000;   // 20 ms; MMIO drain is slower than HW, but this is plenty
        $display("ERROR: tb_axi_pipeline TIMED OUT");
        $display(" AXI PIPELINE TESTS FAILED (timeout)");
        $finish;
    end

endmodule
