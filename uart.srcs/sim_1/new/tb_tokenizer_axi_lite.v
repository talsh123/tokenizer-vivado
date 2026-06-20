`timescale 1ns / 1ps

// ============================================================================
// tb_tokenizer_axi_lite.v
//
// Testbench for tokenizer_axi_lite.v (AXI-Lite Wrapper)
//
// Simulates the MicroBlaze's perspective:
//   1. Write ASCII bytes to TX_DATA register (0x00)
//   2. Poll STATUS register (0x08) for readiness
//   3. Read Token IDs from RX_DATA register (0x04)
//
// This tests the COMPLETE chain:
//   AXI Write -> Input FIFO -> Pre-Tokenizer -> Trie Engine -> Output FIFO -> AXI Read
//
// TEST VECTORS (from HuggingFace / Python verifier):
//   "hello "          -> [7592]
//   "hardware "       -> [8051]
//   "embedding "      -> [7861, 8270, 4667]
//   "unquestionably " -> [4895, 15500, 3258, 8231]
//   "hello hardware " -> [7592, 8051]
//
// ============================================================================

module tb_tokenizer_axi_lite;

    // ========================================================================
    // Parameters
    // ========================================================================
    parameter C_S_AXI_DATA_WIDTH = 32;
    parameter C_S_AXI_ADDR_WIDTH = 4;
    parameter CLK_PERIOD = 10; // 100 MHz

    // Register addresses
    localparam ADDR_TX_DATA = 4'h0; // 0x00
    localparam ADDR_RX_DATA = 4'h4; // 0x04
    localparam ADDR_STATUS  = 4'h8; // 0x08

    // ========================================================================
    // DUT Signals
    // ========================================================================
    reg clk;
    reg aresetn;

    // AXI-Lite Write Address Channel
    reg  [C_S_AXI_ADDR_WIDTH-1:0] s_axi_awaddr;
    reg                            s_axi_awvalid;
    wire                           s_axi_awready;

    // AXI-Lite Write Data Channel
    reg  [C_S_AXI_DATA_WIDTH-1:0] s_axi_wdata;
    reg  [3:0]                     s_axi_wstrb;
    reg                            s_axi_wvalid;
    wire                           s_axi_wready;

    // AXI-Lite Write Response Channel
    wire [1:0]                     s_axi_bresp;
    wire                           s_axi_bvalid;
    reg                            s_axi_bready;

    // AXI-Lite Read Address Channel
    reg  [C_S_AXI_ADDR_WIDTH-1:0] s_axi_araddr;
    reg                            s_axi_arvalid;
    wire                           s_axi_arready;

    // AXI-Lite Read Data Channel
    wire [C_S_AXI_DATA_WIDTH-1:0] s_axi_rdata;
    wire [1:0]                     s_axi_rresp;
    wire                           s_axi_rvalid;
    reg                            s_axi_rready;

    // ========================================================================
    // DUT Instantiation
    // ========================================================================
    tokenizer_axi_lite #(
        .C_S_AXI_DATA_WIDTH(C_S_AXI_DATA_WIDTH),
        .C_S_AXI_ADDR_WIDTH(C_S_AXI_ADDR_WIDTH)
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
        .s_axi_rready   (s_axi_rready)
    );

    // ========================================================================
    // Clock Generation
    // ========================================================================
    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // ========================================================================
    // Test Tracking
    // ========================================================================
    integer test_num;
    integer total_errors;

    // Token capture
    reg [15:0] captured_tokens [0:31];
    integer token_count;

    // ========================================================================
    // AXI-Lite Helper Tasks
    // ========================================================================

    // AXI-Lite Write: write a 32-bit value to an address
    task axi_write;
        input [C_S_AXI_ADDR_WIDTH-1:0] addr;
        input [C_S_AXI_DATA_WIDTH-1:0] data;
        begin
            // Present address and data simultaneously
            @(posedge clk);
            s_axi_awaddr  <= addr;
            s_axi_awvalid <= 1'b1;
            s_axi_wdata   <= data;
            s_axi_wstrb   <= 4'hF;
            s_axi_wvalid  <= 1'b1;
            s_axi_bready  <= 1'b1;

            // Wait for both address and data to be accepted
            @(posedge clk);
            while (!(s_axi_awready || s_axi_wready)) @(posedge clk);

            // Deassert after acceptance
            if (s_axi_awready) s_axi_awvalid <= 1'b0;
            if (s_axi_wready)  s_axi_wvalid  <= 1'b0;

            @(posedge clk);
            s_axi_awvalid <= 1'b0;
            s_axi_wvalid  <= 1'b0;

            // Wait for write response
            while (!s_axi_bvalid) @(posedge clk);
            @(posedge clk);
            s_axi_bready <= 1'b0;
        end
    endtask

    // AXI-Lite Read: read a 32-bit value from an address
    task axi_read;
        input  [C_S_AXI_ADDR_WIDTH-1:0] addr;
        output [C_S_AXI_DATA_WIDTH-1:0] data;
        begin
            @(posedge clk);
            s_axi_araddr  <= addr;
            s_axi_arvalid <= 1'b1;
            s_axi_rready  <= 1'b1;

            // Wait for read data to be valid
            @(posedge clk);
            while (!s_axi_rvalid) @(posedge clk);

            data = s_axi_rdata;
            s_axi_arvalid <= 1'b0;

            @(posedge clk);
            s_axi_rready <= 1'b0;
        end
    endtask

    // ========================================================================
    // Higher-Level Helper Tasks
    // ========================================================================

    // Write a single ASCII byte to the tokenizer (mimics tok_send_byte in C)
    task tok_send_byte;
        input [7:0] byte_val;
        reg [31:0] status;
        begin
            // Poll STATUS until input FIFO is not full (bit 0)
            status = 0;
            while (!(status & 32'h1)) begin
                axi_read(ADDR_STATUS, status);
            end
            // Write the byte to TX_DATA
            axi_write(ADDR_TX_DATA, {24'd0, byte_val});
        end
    endtask

    // Read one token ID from the tokenizer (mimics tok_read_token in C)
    task tok_read_token;
        output [15:0] token_id;
        reg [31:0] rdata;
        reg [31:0] status;
        begin
            // Poll STATUS until output FIFO is not empty (bit 1)
            status = 0;
            while (!(status & 32'h2)) begin
                axi_read(ADDR_STATUS, status);
            end
            // Read RX_DATA
            axi_read(ADDR_RX_DATA, rdata);
            token_id = rdata[15:0];
        end
    endtask

    // Check if output FIFO has a token available
    task tok_check_has_token;
        output has_token;
        reg [31:0] status;
        begin
            axi_read(ADDR_STATUS, status);
            has_token = (status & 32'h2) ? 1'b1 : 1'b0;
        end
    endtask

    // Send a string byte-by-byte to the tokenizer
    task send_string;
        input [255:0] str_packed;
        input integer  str_len;
        integer i;
        reg [7:0] ch;
        begin
            for (i = 0; i < str_len; i = i + 1) begin
                ch = str_packed[8*(31-i) +: 8];
                if (ch == 8'h20)
                    $display("  TX: ' ' (space)");
                else
                    $display("  TX: '%c' (0x%02X)", ch, ch);
                tok_send_byte(ch);
            end
        end
    endtask

    // Wait for processing and collect all tokens
    task collect_tokens;
        reg [15:0] tid;
        reg has;
        integer wait_cycles;
        begin
            token_count = 0;

            // Wait for the pipeline to process everything
            // (binary search + backtracking takes many cycles)
            repeat(2000) @(posedge clk);

            // Read all available tokens
            tok_check_has_token(has);
            while (has) begin
                tok_read_token(tid);
                captured_tokens[token_count] = tid;
                $display("  RX: Token[%0d] = %0d (0x%04X)", token_count, tid, tid);
                token_count = token_count + 1;
                // Check for more
                tok_check_has_token(has);
            end
        end
    endtask

    // Verify captured tokens against expected values
    task verify_tokens;
        input integer num_expected;
        input [15:0] exp0, exp1, exp2, exp3;
        integer j;
        reg [15:0] expected [0:3];
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
        end
    endtask

    // Verify for multi-word tests (up to 8 tokens)
    task verify_tokens_8;
        input integer num_expected;
        input [15:0] exp0, exp1, exp2, exp3;
        input [15:0] exp4, exp5, exp6, exp7;
        integer j;
        reg [15:0] expected [0:7];
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
        end
    endtask

    // ========================================================================
    // Main Test Sequence
    // ========================================================================
    initial begin
        // Initialize all AXI signals
        s_axi_awaddr  = 0;
        s_axi_awvalid = 0;
        s_axi_wdata   = 0;
        s_axi_wstrb   = 0;
        s_axi_wvalid  = 0;
        s_axi_bready  = 0;
        s_axi_araddr  = 0;
        s_axi_arvalid = 0;
        s_axi_rready  = 0;
        aresetn       = 0;
        total_errors  = 0;
        token_count   = 0;

        // Reset
        repeat(20) @(posedge clk);
        aresetn = 1;
        repeat(10) @(posedge clk);

        $display("============================================");
        $display(" AXI-Lite Tokenizer Wrapper Testbench");
        $display(" Full Chain: AXI -> FIFO -> Tokenizer -> FIFO -> AXI");
        $display("============================================");

        // ----------------------------------------------------------
        // Test 1: "hello " -> [7592]
        // ----------------------------------------------------------
        test_num = 1;
        $display("\n===== TEST %0d: \"hello \" =====", test_num);
        send_string({8'h68, 8'h65, 8'h6C, 8'h6C, 8'h6F, 8'h20, {26{8'h00}}}, 6);
        collect_tokens;
        verify_tokens(1, 16'd7592, 16'd0, 16'd0, 16'd0);

        // ----------------------------------------------------------
        // Test 2: "hardware " -> [8051]
        // ----------------------------------------------------------
        test_num = 2;
        $display("\n===== TEST %0d: \"hardware \" =====", test_num);
        send_string({8'h68, 8'h61, 8'h72, 8'h64, 8'h77, 8'h61, 8'h72, 8'h65,
                     8'h20, {23{8'h00}}}, 9);
        collect_tokens;
        verify_tokens(1, 16'd8051, 16'd0, 16'd0, 16'd0);

        // ----------------------------------------------------------
        // Test 3: "embedding " -> [7861, 8270, 4667]
        // ----------------------------------------------------------
        test_num = 3;
        $display("\n===== TEST %0d: \"embedding \" =====", test_num);
        send_string({8'h65, 8'h6D, 8'h62, 8'h65, 8'h64, 8'h64, 8'h69, 8'h6E,
                     8'h67, 8'h20, {22{8'h00}}}, 10);
        collect_tokens;
        verify_tokens(3, 16'd7861, 16'd8270, 16'd4667, 16'd0);

        // ----------------------------------------------------------
        // Test 4: "unquestionably " -> [4895, 15500, 3258, 8231]
        // ----------------------------------------------------------
        test_num = 4;
        $display("\n===== TEST %0d: \"unquestionably \" =====", test_num);
        send_string({8'h75, 8'h6E, 8'h71, 8'h75, 8'h65, 8'h73, 8'h74,
                     8'h69, 8'h6F, 8'h6E, 8'h61, 8'h62, 8'h6C, 8'h79,
                     8'h20, {17{8'h00}}}, 15);
        collect_tokens;
        verify_tokens(4, 16'd4895, 16'd15500, 16'd3258, 16'd8231);

        // ----------------------------------------------------------
        // Test 5: "hello hardware " -> [7592, 8051]
        // ----------------------------------------------------------
        test_num = 5;
        $display("\n===== TEST %0d: \"hello hardware \" =====", test_num);
        send_string({8'h68, 8'h65, 8'h6C, 8'h6C, 8'h6F, 8'h20,
                     8'h68, 8'h61, 8'h72, 8'h64, 8'h77, 8'h61, 8'h72, 8'h65,
                     8'h20, {17{8'h00}}}, 15);
        collect_tokens;
        verify_tokens_8(2, 16'd7592, 16'd8051, 16'd0, 16'd0,
                           16'd0, 16'd0, 16'd0, 16'd0);

        // ----------------------------------------------------------
        // Test 6: "embed " -> [7861, 8270]  (em + ##bed, NO [UNK])
        // reproduces the on-board anomaly where "embed" emitted a spurious
        // [UNK] (100). "embed" is "embedding" minus "ding": its continuation
        // replay ends exactly at the buffer end on a terminal node that still
        // has children -- a finalization path the other vectors don't hit.
        // ----------------------------------------------------------
        test_num = 6;
        $display("\n===== TEST %0d: \"embed \" =====", test_num);
        send_string({8'h65, 8'h6D, 8'h62, 8'h65, 8'h64, 8'h20, {26{8'h00}}}, 6);
        collect_tokens;
        verify_tokens(2, 16'd7861, 16'd8270, 16'd0, 16'd0);

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
        #50_000_000; // 50ms
        $display("ERROR: Simulation timed out!");
        $finish;
    end

endmodule