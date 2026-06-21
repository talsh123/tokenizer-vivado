`timescale 1ns / 1ps
// tb_word_boundary.v
// Regression for the #2 fix: a 1-character word that immediately follows a multi-piece word
// must NOT merge into the next word. Before the fix, the single-bit word_done_pending merged
// the two boundaries (the 1-char word's boundary arrived during the previous word's replay),
// producing "a long"->"along" and "vocab t vocab"-> the middle "t" gluing into "tvocab".
//
// It streams whole phrases through tokenizer_axi_lite's AXI4-Stream datapath (the same path the
// DMA drives), one transfer per phrase with tlast on the final byte, and checks the full token
// sequence against the HuggingFace bert-base-uncased reference IDs. The 9 trie .mem files must
// be visible to xsim (same as the other testbenches). Run with: restart; run all.

module tb_word_boundary;

    localparam TOKEN_W    = 16;
    localparam CLK_PERIOD = 10; // 100 MHz

    reg clk = 1'b0;
    reg aresetn = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // AXI-Stream slave (input bytes) -- driven here like a DMA MM2S channel
    reg  [7:0]         s_axis_tdata;
    reg                s_axis_tvalid;
    wire               s_axis_tready;
    reg                s_axis_tlast;
    // AXI-Stream master (output tokens) -- consumed here like a DMA S2MM channel
    wire [TOKEN_W-1:0] m_axis_tdata;
    wire               m_axis_tvalid;
    reg                m_axis_tready;
    wire               m_axis_tlast;

    // AXI-Lite -- tied off idle (this test reads tokens only off the stream)
    reg  [3:0]  s_axi_awaddr;  reg  s_axi_awvalid; wire s_axi_awready;
    reg  [31:0] s_axi_wdata;   reg  [3:0] s_axi_wstrb; reg s_axi_wvalid; wire s_axi_wready;
    wire [1:0]  s_axi_bresp;   wire s_axi_bvalid;  reg  s_axi_bready;
    reg  [3:0]  s_axi_araddr;  reg  s_axi_arvalid; wire s_axi_arready;
    wire [31:0] s_axi_rdata;   wire [1:0] s_axi_rresp; wire s_axi_rvalid; reg s_axi_rready;

    integer total_errors = 0;
    reg [TOKEN_W-1:0] expected [0:15];

    // ------------------------------------------------------------------ DUT
    tokenizer_axi_lite #( .TOKEN_W (TOKEN_W) ) uut (
        .s_axi_aclk    (clk),
        .s_axi_aresetn (aresetn),
        .s_axi_awaddr  (s_axi_awaddr), .s_axi_awvalid (s_axi_awvalid), .s_axi_awready (s_axi_awready),
        .s_axi_wdata   (s_axi_wdata),  .s_axi_wstrb   (s_axi_wstrb),   .s_axi_wvalid  (s_axi_wvalid), .s_axi_wready (s_axi_wready),
        .s_axi_bresp   (s_axi_bresp),  .s_axi_bvalid  (s_axi_bvalid),  .s_axi_bready  (s_axi_bready),
        .s_axi_araddr  (s_axi_araddr), .s_axi_arvalid (s_axi_arvalid), .s_axi_arready (s_axi_arready),
        .s_axi_rdata   (s_axi_rdata),  .s_axi_rresp   (s_axi_rresp),   .s_axi_rvalid  (s_axi_rvalid), .s_axi_rready (s_axi_rready),
        .s_axis_tdata  (s_axis_tdata),  .s_axis_tvalid (s_axis_tvalid), .s_axis_tready (s_axis_tready), .s_axis_tlast (s_axis_tlast),
        .m_axis_tdata  (m_axis_tdata),  .m_axis_tvalid (m_axis_tvalid), .m_axis_tready (m_axis_tready), .m_axis_tlast (m_axis_tlast)
    );

    // ------------------------------------------------------------------ token collector
    reg [TOKEN_W-1:0] captured [0:63];
    integer ntok;
    reg     last_seen;
    integer tlast_index;
    reg     clr;
    always @(posedge clk) begin
        if (!aresetn || clr) begin
            ntok <= 0; last_seen <= 1'b0; tlast_index <= -1;
        end else if (m_axis_tvalid && m_axis_tready) begin
            captured[ntok] <= m_axis_tdata;
            if (m_axis_tlast) begin last_seen <= 1'b1; tlast_index <= ntok; end
            ntok <= ntok + 1;
        end
    end

    // ------------------------------------------------------------------ MM2S byte stream
    // streams len bytes of str (MSB-first), asserting tlast on the final byte (the boundary that
    // finalizes the last word -- callers always end the phrase with a trailing space).
    task axis_send;
        input [8*48-1:0] str;
        input integer    len;
        integer k;
        begin
            for (k = 0; k < len; k = k + 1) begin
                @(negedge clk);
                s_axis_tdata  = str[8*(len-1-k) +: 8];
                s_axis_tvalid = 1'b1;
                s_axis_tlast  = (k == len-1);
                @(posedge clk);
                while (!s_axis_tready) begin @(negedge clk); @(posedge clk); end
            end
            @(negedge clk);
            s_axis_tvalid = 1'b0;
            s_axis_tlast  = 1'b0;
        end
    endtask

    // ------------------------------------------------------------------ one phrase
    task run_case;
        input [8*32-1:0] name;
        input [8*48-1:0] str;
        input integer    len; // bytes to stream (phrase incl. trailing space)
        input integer    n;   // expected token count
        integer j;
        reg     pass;
        begin
            clr = 1'b1; @(posedge clk); clr = 1'b0;
            axis_send(str, len);
            j = 0;
            while (!last_seen && j < 20000) begin @(posedge clk); j = j + 1; end

            pass = 1'b1;
            if (!last_seen) begin
                $display("  [%0s] FAIL: never saw m_axis_tlast (timeout)", name); pass = 1'b0;
            end else begin
                if (ntok !== n) begin
                    $display("  [%0s] FAIL: expected %0d tokens, got %0d", name, n, ntok); pass = 1'b0;
                end
                for (j = 0; j < n; j = j + 1)
                    if (captured[j] !== expected[j]) begin
                        $display("  [%0s] FAIL: token[%0d] expected %0d, got %0d",
                                 name, j, expected[j], captured[j]); pass = 1'b0;
                    end
                if (tlast_index !== (n-1)) begin
                    $display("  [%0s] FAIL: tlast on token %0d, expected last (%0d)",
                             name, tlast_index, n-1); pass = 1'b0;
                end
            end
            if (pass) begin
                $write("  [%0s] PASS (%0d tok) ->", name, ntok);
                for (j = 0; j < ntok; j = j + 1) $write(" %0d", captured[j]);
                $display("");
            end else total_errors = total_errors + 1;
            repeat (10) @(posedge clk);
        end
    endtask

    // ------------------------------------------------------------------ stimulus
    initial begin
        s_axis_tdata = 8'd0; s_axis_tvalid = 1'b0; s_axis_tlast = 1'b0;
        m_axis_tready = 1'b1;
        s_axi_awaddr=0; s_axi_awvalid=0; s_axi_wdata=0; s_axi_wstrb=0; s_axi_wvalid=0; s_axi_bready=0;
        s_axi_araddr=0; s_axi_arvalid=0; s_axi_rready=0;
        clr = 1'b0; aresetn = 1'b0;
        repeat (10) @(posedge clk);
        aresetn = 1'b1;
        repeat (5) @(posedge clk);

        $display("============================================================");
        $display(" tb_word_boundary : 1-char word after a multi-piece word (#2)");
        $display("============================================================");

        // --- the two real bug patterns (must pass with the fix) ---
        // "summarize a long " -> sum ##mar ##ize a long
        expected[0]=7680; expected[1]=7849; expected[2]=4697; expected[3]=1037; expected[4]=2146;
        run_case("summarize a long", "summarize a long ", 17, 5);

        // "vocab t vocab " -> vo ##ca ##b t vo ##ca ##b  (the second "t" must not merge)
        expected[0]=29536; expected[1]=3540; expected[2]=2497; expected[3]=1056;
        expected[4]=29536; expected[5]=3540; expected[6]=2497;
        run_case("vocab t vocab", "vocab t vocab ", 14, 7);

        // "embed embedding a hi " -> em ##bed em ##bed ##ding a hi  (two multi-piece, then 1-char)
        expected[0]=7861; expected[1]=8270; expected[2]=7861; expected[3]=8270; expected[4]=4667;
        expected[5]=1037; expected[6]=7632;
        run_case("embed embedding a hi", "embed embedding a hi ", 21, 7);

        // --- controls that already worked (regression guards) ---
        // single-piece word before a 1-char word: "map t vocab "
        expected[0]=4949; expected[1]=1056; expected[2]=29536; expected[3]=3540; expected[4]=2497;
        run_case("map t vocab", "map t vocab ", 12, 5);

        // 1-char word FIRST (no preceding multi-piece): "a long "
        expected[0]=1037; expected[1]=2146;
        run_case("a long", "a long ", 7, 2);

        // plain words, the classic vectors
        expected[0]=7592;
        run_case("hello", "hello ", 6, 1);
        expected[0]=7861; expected[1]=8270;
        run_case("embed", "embed ", 6, 2);
        expected[0]=7861; expected[1]=8270; expected[2]=4667;
        run_case("embedding", "embedding ", 10, 3);

        $display("============================================================");
        if (total_errors == 0) $display(" WORD-BOUNDARY TESTS PASSED");
        else                   $display(" WORD-BOUNDARY TESTS FAILED (%0d error(s))", total_errors);
        $display("============================================================");
        repeat (20) @(posedge clk);
        $finish;
    end

    // watchdog
    initial begin
        #5_000_000;
        $display("ERROR: tb_word_boundary TIMED OUT");
        $finish;
    end

endmodule
