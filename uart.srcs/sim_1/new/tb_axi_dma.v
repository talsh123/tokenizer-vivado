`timescale 1ns / 1ps
// tb_axi_dma.v
// Testbench for the AXI4-Stream (DMA, optimization R2) datapath added to tokenizer_axi_lite.v.
// It drives the input byte stream (s_axis) the way an AXI DMA MM2S channel would, and collects the
// output token stream (m_axis) the way an S2MM channel would. For each input word it checks:
//   - the token IDs match the HuggingFace bert-base-uncased reference, and
//   - m_axis_tlast is asserted on EXACTLY the final token of the response (the DMA end-of-packet), and
//   - the AXI-Lite TOKEN_COUNT register (0x0C) reports the right token count (the way firmware reads it).
// The same 9 .mem files used by the other testbenches must be visible to xsim.

module tb_axi_dma;

    localparam TOKEN_W    = 16;
    localparam CLK_PERIOD = 10; // 100 MHz

    reg clk = 1'b0;
    reg aresetn = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // AXI-Stream slave (input bytes) -- driven by this testbench (MM2S model)
    reg  [7:0]         s_axis_tdata;
    reg                s_axis_tvalid;
    wire               s_axis_tready;
    reg                s_axis_tlast;
    // AXI-Stream master (output tokens) -- consumed by this testbench (S2MM model)
    wire [TOKEN_W-1:0] m_axis_tdata;
    wire               m_axis_tvalid;
    reg                m_axis_tready;
    wire               m_axis_tlast;

    // AXI-Lite control -- used here only to clear/read the 0x0C TOKEN_COUNT register
    reg  [3:0]  s_axi_awaddr;  reg  s_axi_awvalid; wire s_axi_awready;
    reg  [31:0] s_axi_wdata;   reg  [3:0] s_axi_wstrb; reg s_axi_wvalid; wire s_axi_wready;
    wire [1:0]  s_axi_bresp;   wire s_axi_bvalid;  reg  s_axi_bready;
    reg  [3:0]  s_axi_araddr;  reg  s_axi_arvalid; wire s_axi_arready;
    wire [31:0] s_axi_rdata;   wire [1:0] s_axi_rresp; wire s_axi_rvalid; reg s_axi_rready;

    integer total_errors = 0;
    reg [TOKEN_W-1:0] expected [0:15];

    // ------------------------------------------------------------------ DUT
    tokenizer_axi_lite #(
        .TOKEN_W (TOKEN_W)
    ) uut (
        .s_axi_aclk    (clk),
        .s_axi_aresetn (aresetn),
        // AXI-Lite -- used to clear/read the 0x0C TOKEN_COUNT register
        .s_axi_awaddr  (s_axi_awaddr), .s_axi_awvalid (s_axi_awvalid), .s_axi_awready (s_axi_awready),
        .s_axi_wdata   (s_axi_wdata),  .s_axi_wstrb   (s_axi_wstrb),   .s_axi_wvalid  (s_axi_wvalid), .s_axi_wready (s_axi_wready),
        .s_axi_bresp   (s_axi_bresp),  .s_axi_bvalid  (s_axi_bvalid),  .s_axi_bready  (s_axi_bready),
        .s_axi_araddr  (s_axi_araddr), .s_axi_arvalid (s_axi_arvalid), .s_axi_arready (s_axi_arready),
        .s_axi_rdata   (s_axi_rdata),  .s_axi_rresp   (s_axi_rresp),   .s_axi_rvalid  (s_axi_rvalid), .s_axi_rready (s_axi_rready),
        // AXI-Stream -- under test
        .s_axis_tdata  (s_axis_tdata),
        .s_axis_tvalid (s_axis_tvalid),
        .s_axis_tready (s_axis_tready),
        .s_axis_tlast  (s_axis_tlast),
        .m_axis_tdata  (m_axis_tdata),
        .m_axis_tvalid (m_axis_tvalid),
        .m_axis_tready (m_axis_tready),
        .m_axis_tlast  (m_axis_tlast)
    );

    // ------------------------------------------------------------------ S2MM collector
    // captures every token accepted on the master stream; records which token carried tlast.
    reg [TOKEN_W-1:0] captured [0:63];
    integer ntok;
    reg     last_seen;     // m_axis_tlast observed for the current response
    integer tlast_index;   // index of the token that carried tlast (-1 = none)
    reg     clr;           // 1-cycle pulse to reset the collector between cases

    always @(posedge clk) begin
        if (!aresetn || clr) begin
            ntok        <= 0;
            last_seen   <= 1'b0;
            tlast_index <= -1;
        end else if (m_axis_tvalid && m_axis_tready) begin
            captured[ntok] <= m_axis_tdata;
            if (m_axis_tlast) begin
                last_seen   <= 1'b1;
                tlast_index <= ntok;
            end
            ntok <= ntok + 1;
        end
    end

    // ------------------------------------------------------------------ AXI-Lite tasks (for 0x0C)
    task axi_write;
        input [3:0]  addr;
        input [31:0] data;
        begin
            @(posedge clk);
            s_axi_awaddr <= addr; s_axi_awvalid <= 1'b1;
            s_axi_wdata  <= data; s_axi_wstrb <= 4'hF; s_axi_wvalid <= 1'b1;
            s_axi_bready <= 1'b1;
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
        input  [3:0]  addr;
        output [31:0] data;
        begin
            @(posedge clk);
            s_axi_araddr <= addr; s_axi_arvalid <= 1'b1; s_axi_rready <= 1'b1;
            @(posedge clk);
            while (!s_axi_rvalid) @(posedge clk);
            data = s_axi_rdata;
            s_axi_arvalid <= 1'b0;
            @(posedge clk);
            s_axi_rready <= 1'b0;
        end
    endtask

    // ------------------------------------------------------------------ MM2S driver
    // streams len bytes of str into s_axis, asserting tlast on the final byte (the DMA end marker).
    task axis_send;
        input [8*64-1:0] str;
        input integer    len;
        integer k;
        begin
            for (k = 0; k < len; k = k + 1) begin
                @(negedge clk);                       // drive between edges so values are stable at the posedge
                s_axis_tdata  = str[8*(len-1-k) +: 8];
                s_axis_tvalid = 1'b1;
                s_axis_tlast  = (k == len-1);
                @(posedge clk);                       // DUT samples the byte cleanly here
                while (!s_axis_tready) begin           // not accepted -> hold the byte another cycle
                    @(negedge clk); @(posedge clk);
                end
            end
            @(negedge clk);
            s_axis_tvalid = 1'b0;
            s_axis_tlast  = 1'b0;
        end
    endtask

    // ------------------------------------------------------------------ one streamed case
    task run_case;
        input [8*40-1:0] name;
        input [8*64-1:0] str;
        input integer    len;  // bytes to stream (word + its trailing boundary)
        input integer    n;    // expected token count
        integer j;
        reg     pass;
        reg [31:0] rdval;
        begin
            // reset the collector for this case (pipeline is idle between cases)
            clr = 1'b1; @(posedge clk); clr = 1'b0;
            axi_write(4'hC, 32'd0); // clear the hardware TOKEN_COUNT (0x0C) before this transfer

            axis_send(str, len);

            // wait until the response completes (tlast) or time out
            j = 0;
            while (!last_seen && j < 5000) begin @(posedge clk); j = j + 1; end

            pass = 1'b1;
            if (!last_seen) begin
                $display("  [%0s] FAIL: never saw m_axis_tlast (timeout)", name);
                pass = 1'b0;
            end else begin
                if (ntok !== n) begin
                    $display("  [%0s] FAIL: expected %0d tokens, got %0d", name, n, ntok);
                    pass = 1'b0;
                end
                for (j = 0; j < n; j = j + 1)
                    if (captured[j] !== expected[j]) begin
                        $display("  [%0s] FAIL: token[%0d] expected %0d, got %0d",
                                 name, j, expected[j], captured[j]);
                        pass = 1'b0;
                    end
                // tlast must land on the LAST token, not earlier or later
                if (tlast_index !== (n-1)) begin
                    $display("  [%0s] FAIL: tlast on token %0d, expected on the last token (%0d)",
                             name, tlast_index, n-1);
                    pass = 1'b0;
                end
                // TOKEN_COUNT (0x0C) must equal the number of tokens produced (what firmware reads)
                axi_read(4'hC, rdval);
                if (rdval[15:0] !== n) begin
                    $display("  [%0s] FAIL: TOKEN_COUNT(0x0C)=%0d, expected %0d", name, rdval[15:0], n);
                    pass = 1'b0;
                end
            end

            if (pass) begin
                $write("  [%0s] PASS (%0d tokens, tlast on last) ->", name, ntok);
                for (j = 0; j < ntok; j = j + 1) $write(" %0d", captured[j]);
                $display("");
            end else
                total_errors = total_errors + 1;

            repeat (10) @(posedge clk); // let the pipeline settle before the next case
        end
    endtask

    // ------------------------------------------------------------------ stimulus
    initial begin
        s_axis_tdata = 8'd0; s_axis_tvalid = 1'b0; s_axis_tlast = 1'b0;
        m_axis_tready = 1'b1; // model a DMA that is always ready to accept tokens
        s_axi_awaddr=0; s_axi_awvalid=0; s_axi_wdata=0; s_axi_wstrb=0; s_axi_wvalid=0; s_axi_bready=0;
        s_axi_araddr=0; s_axi_arvalid=0; s_axi_rready=0;
        clr = 1'b0;
        aresetn = 1'b0;
        repeat (10) @(posedge clk);
        aresetn = 1'b1;
        repeat (5) @(posedge clk);

        $display("============================================================");
        $display(" tb_axi_dma : AXI4-Stream (DMA) datapath + TLAST (R2)");
        $display("============================================================");

        // single-token word: tlast on the one and only token
        expected[0] = 16'd7592;
        run_case("hello", "hello ", 6, 1);

        // two-piece word that finalizes at a boundary (the embed case): tlast on the 2nd token
        expected[0] = 16'd7861; expected[1] = 16'd8270;
        run_case("embed", "embed ", 6, 2);

        // three-piece word (root + two continuation pieces): tlast on the 3rd token
        expected[0] = 16'd7861; expected[1] = 16'd8270; expected[2] = 16'd4667;
        run_case("embedding", "embedding ", 10, 3);

        $display("============================================================");
        if (total_errors == 0) $display(" AXI DMA STREAM TESTS PASSED");
        else                   $display(" AXI DMA STREAM TESTS FAILED (%0d error(s))", total_errors);
        $display("============================================================");

        repeat (20) @(posedge clk);
        $finish;
    end

    // ------------------------------------------------------------------ watchdog
    initial begin
        #5_000_000; // 5 ms
        $display("ERROR: tb_axi_dma TIMED OUT");
        $display(" AXI DMA STREAM TESTS FAILED (timeout)");
        $finish;
    end

endmodule
