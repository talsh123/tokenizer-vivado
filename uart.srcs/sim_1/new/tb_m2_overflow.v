`timescale 1ns / 1ps

// ============================================================================
// tb_m2_overflow.v
//
// Targeted testbench for the M2 fix in tokenizer_axi_lite.v:
//   "output-FIFO overflow is silent".
//
// The fix adds a sticky out_fifo_overflow flag, exposed as STATUS bit 2, that is
// set whenever the trie engine emits a token while the output FIFO is full (the
// token is still dropped -- prevention needs interleaved drain in firmware -- but
// the loss is now DETECTABLE), and cleared by reset or by a write to STATUS.
//
// To reach overflow quickly, the DUT is instantiated with a deliberately small
// 8-deep output FIFO (OUT_FIFO_DEPTH_LOG2 = 3). The test floods it with single-
// character words (each "a " -> 1 token) WITHOUT reading RX_DATA, so the FIFO
// fills and drops the surplus.
//
// Checks:
//   1. overflow flag starts clear
//   2. overflow flag is SET after producing more tokens than the FIFO holds
//   3. overflow flag CLEARS after a write to STATUS (write-to-clear)
//
// Expected on the FIXED RTL:  "M2 TEST PASSED".
// On the UNFIXED RTL: STATUS bit 2 never asserts -> test 2 FAILS (loss is silent).
//
// Needs the same .mem files as the other sims (the AXI wrapper contains the full
// pre-tokenizer + trie engine, which $readmemh their tables).
// ============================================================================

module tb_m2_overflow;

    parameter C_S_AXI_DATA_WIDTH = 32;
    parameter C_S_AXI_ADDR_WIDTH = 4;
    parameter CLK_PERIOD         = 10;   // 100 MHz
    parameter SMALL_OUT_LOG2     = 3;    // 8-deep output FIFO -> overflow after 8 tokens

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

    // ------------------------------------------------------------------ DUT
    tokenizer_axi_lite #(
        .C_S_AXI_DATA_WIDTH (C_S_AXI_DATA_WIDTH),
        .C_S_AXI_ADDR_WIDTH (C_S_AXI_ADDR_WIDTH),
        .OUT_FIFO_DEPTH_LOG2(SMALL_OUT_LOG2)     // small FIFO so overflow is easy to reach
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

    // ------------------------------------------------------------------ AXI tasks
    task axi_write;
        input [C_S_AXI_ADDR_WIDTH-1:0] addr;
        input [C_S_AXI_DATA_WIDTH-1:0] data;
        begin
            @(posedge clk);
            s_axi_awaddr  <= addr;
            s_axi_awvalid <= 1'b1;
            s_axi_wdata   <= data;
            s_axi_wstrb   <= 4'hF;
            s_axi_wvalid  <= 1'b1;
            s_axi_bready  <= 1'b1;
            @(posedge clk);
            while (!(s_axi_awready || s_axi_wready)) @(posedge clk);
            if (s_axi_awready) s_axi_awvalid <= 1'b0;
            if (s_axi_wready)  s_axi_wvalid  <= 1'b0;
            @(posedge clk);
            s_axi_awvalid <= 1'b0;
            s_axi_wvalid  <= 1'b0;
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
            s_axi_araddr  <= addr;
            s_axi_arvalid <= 1'b1;
            s_axi_rready  <= 1'b1;
            @(posedge clk);
            while (!s_axi_rvalid) @(posedge clk);
            data = s_axi_rdata;
            s_axi_arvalid <= 1'b0;
            @(posedge clk);
            s_axi_rready <= 1'b0;
        end
    endtask

    // write one byte to TX_DATA, polling input-FIFO-not-full (STATUS bit 0)
    task tok_send_byte;
        input [7:0] b;
        reg [31:0] status;
        begin
            status = 0;
            while (!(status & 32'h1)) axi_read(ADDR_STATUS, status);
            axi_write(ADDR_TX_DATA, {24'd0, b});
        end
    endtask

    // read STATUS and assert overflow (bit 2) equals 'exp'
    task check_overflow;
        input            exp;
        input [8*40-1:0] name;
        reg [31:0] status;
        begin
            axi_read(ADDR_STATUS, status);
            if (status[2] === exp)
                $display("  [%s] PASS (STATUS=0x%08x, overflow bit=%0d)", name, status, status[2]);
            else begin
                $display("  [%s] FAIL: expected overflow bit=%0d, got %0d (STATUS=0x%08x)",
                         name, exp, status[2], status);
                total_errors = total_errors + 1;
            end
        end
    endtask

    // ------------------------------------------------------------------ stimulus
    integer w;
    reg [31:0] dummy;
    initial begin
        aresetn       = 1'b0;
        s_axi_awaddr  = 0; s_axi_awvalid = 0;
        s_axi_wdata   = 0; s_axi_wstrb = 0; s_axi_wvalid = 0; s_axi_bready = 0;
        s_axi_araddr  = 0; s_axi_arvalid = 0; s_axi_rready = 0;
        total_errors  = 0;

        repeat (10) @(posedge clk);
        aresetn = 1'b1;
        repeat (5) @(posedge clk);

        $display("============================================================");
        $display(" tb_m2_overflow : output-FIFO overflow detection (M2)");
        $display(" (output FIFO forced to %0d entries)", (1<<SMALL_OUT_LOG2));
        $display("============================================================");

        // 1) overflow starts clear
        check_overflow(1'b0, "initial: overflow clear");

        // 2) flood: 20 single-char words (each 'a ' -> 1 token), never read RX_DATA
        $display("  flooding 20 single-char words without draining RX_DATA ...");
        for (w = 0; w < 20; w = w + 1) begin
            tok_send_byte("a");
            tok_send_byte(" ");
        end
        repeat (4000) @(posedge clk);   // let the engine produce all tokens
        check_overflow(1'b1, "after flood: overflow set");

        // 3) write-to-clear via STATUS, then it must read back clear
        axi_write(ADDR_STATUS, 32'h0);  // any write to 0x08 clears the flag
        repeat (10) @(posedge clk);
        check_overflow(1'b0, "after STATUS write: overflow cleared");

        $display("============================================================");
        if (total_errors == 0) $display(" M2 TEST PASSED");
        else                   $display(" M2 TEST FAILED (%0d error(s))", total_errors);
        $display("============================================================");

        repeat (20) @(posedge clk);
        $finish;
    end

    // ------------------------------------------------------------------ watchdog
    initial begin
        #5_000_000;
        $display("ERROR: tb_m2_overflow TIMED OUT");
        $display(" M2 TEST FAILED (timeout)");
        $finish;
    end

endmodule
