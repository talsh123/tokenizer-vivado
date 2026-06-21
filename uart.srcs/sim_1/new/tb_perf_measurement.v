`timescale 1ns / 1ps

// ============================================================================
// tb_perf_measurement.v
//
// Performance Measurement Testbench for FPGA WordPiece Tokenizer
// Measures pure hardware latency (no AXI overhead)
//
// Uses the SAME tokenizer_axi_lite wrapper as real hardware, but drives
// the AXI interface directly (no MicroBlaze polling overhead).
// This gives the true end-to-end hardware latency.
// ============================================================================

module tb_perf_measurement;

    parameter C_S_AXI_DATA_WIDTH = 32;
    parameter C_S_AXI_ADDR_WIDTH = 4;
    parameter CLK_PERIOD = 10; // 100 MHz

    localparam ADDR_TX_DATA = 4'h0;
    localparam ADDR_RX_DATA = 4'h4;
    localparam ADDR_STATUS  = 4'h8;

    reg clk;
    reg aresetn;

    reg  [C_S_AXI_ADDR_WIDTH-1:0] s_axi_awaddr;
    reg                            s_axi_awvalid;
    wire                           s_axi_awready;
    reg  [C_S_AXI_DATA_WIDTH-1:0] s_axi_wdata;
    reg  [3:0]                     s_axi_wstrb;
    reg                            s_axi_wvalid;
    wire                           s_axi_wready;
    wire [1:0]                     s_axi_bresp;
    wire                           s_axi_bvalid;
    reg                            s_axi_bready;
    reg  [C_S_AXI_ADDR_WIDTH-1:0] s_axi_araddr;
    reg                            s_axi_arvalid;
    wire                           s_axi_arready;
    wire [C_S_AXI_DATA_WIDTH-1:0] s_axi_rdata;
    wire [1:0]                     s_axi_rresp;
    wire                           s_axi_rvalid;
    reg                            s_axi_rready;

    integer cycle_count;
    integer t_first_char;
    integer t_last_token;
    integer total_tests;
    integer total_failures;

    reg [15:0] received_tokens [0:127];
    integer recv_idx;

    reg [7:0] text_buf [0:511];
    integer text_len;

    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    always @(posedge clk) begin
        if (!aresetn)
            cycle_count <= 0;
        else
            cycle_count <= cycle_count + 1;
    end

    // DUT: full tokenizer_axi_lite wrapper (same as real hardware)
    tokenizer_axi_lite u_dut (
        .s_axi_aclk    (clk),
        .s_axi_aresetn (aresetn),
        .s_axi_awaddr  (s_axi_awaddr),
        .s_axi_awvalid (s_axi_awvalid),
        .s_axi_awready (s_axi_awready),
        .s_axi_wdata   (s_axi_wdata),
        .s_axi_wstrb   (s_axi_wstrb),
        .s_axi_wvalid  (s_axi_wvalid),
        .s_axi_wready  (s_axi_wready),
        .s_axi_bresp   (s_axi_bresp),
        .s_axi_bvalid  (s_axi_bvalid),
        .s_axi_bready  (s_axi_bready),
        .s_axi_araddr  (s_axi_araddr),
        .s_axi_arvalid (s_axi_arvalid),
        .s_axi_arready (s_axi_arready),
        .s_axi_rdata   (s_axi_rdata),
        .s_axi_rresp   (s_axi_rresp),
        .s_axi_rvalid  (s_axi_rvalid),
        .s_axi_rready  (s_axi_rready),
        // AXI-Stream ports unused in this AXI-Lite testbench (DMA datapath) -- tie inputs off
        .s_axis_tdata  (8'd0),
        .s_axis_tvalid (1'b0),
        .s_axis_tlast  (1'b0),
        .m_axis_tready (1'b0)
    );

    // ========================================================================
    // AXI-Lite tasks (from tb_tokenizer_axi_lite)
    // ========================================================================
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

            wait (s_axi_awready || s_axi_wready) @(posedge clk);
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

    task tok_send_byte;
        input [7:0] byte_val;
        reg [31:0] status;
        begin
            status = 0;
            while (!(status & 32'h1)) begin
                axi_read(ADDR_STATUS, status);
            end
            axi_write(ADDR_TX_DATA, {24'd0, byte_val});
        end
    endtask

    task tok_read_token;
        output [15:0] token_id;
        reg [31:0] rdata;
        reg [31:0] status;
        begin
            status = 0;
            while (!(status & 32'h2)) begin
                axi_read(ADDR_STATUS, status);
            end
            axi_read(ADDR_RX_DATA, rdata);
            token_id = rdata[15:0];
        end
    endtask

    task tok_check_has_token;
        output has_token;
        reg [31:0] status;
        begin
            axi_read(ADDR_STATUS, status);
            has_token = (status & 32'h2) ? 1'b1 : 1'b0;
        end
    endtask

    // ========================================================================
    // Task: Send text_buf then trailing space, measure time
    // ========================================================================
    task send_text_and_measure;
        integer i;
        begin
            @(posedge clk);
            t_first_char = cycle_count;

            for (i = 0; i < text_len; i = i + 1) begin
                tok_send_byte(text_buf[i]);
            end
            tok_send_byte(8'h20); // trailing space
        end
    endtask

    // ========================================================================
    // Task: Read all tokens with timeout
    // ========================================================================
    task read_all_tokens;
        reg has;
        reg [15:0] tid;
        integer wait_cycles;
        begin
            recv_idx = 0;

            // Wait a bit for pipeline to start producing tokens
            repeat (500) @(posedge clk);

            // Read tokens until no more available
            has = 1;
            while (has) begin
                tok_check_has_token(has);
                if (has) begin
                    tok_read_token(tid);
                    received_tokens[recv_idx] = tid;
                    t_last_token = cycle_count;
                    recv_idx = recv_idx + 1;
                    if (recv_idx > 120) has = 0; // safety
                end
            end

            // Check one more time after a longer wait (for backtracking tokens)
            repeat (2000) @(posedge clk);
            has = 1;
            while (has) begin
                tok_check_has_token(has);
                if (has) begin
                    tok_read_token(tid);
                    received_tokens[recv_idx] = tid;
                    t_last_token = cycle_count;
                    recv_idx = recv_idx + 1;
                    if (recv_idx > 120) has = 0;
                end
            end
        end
    endtask

    // ========================================================================
    // Task: Report results
    // ========================================================================
    task report_results;
        input integer expected_count;
        input integer cpu_latency_ns;
        integer hw_cycles, hw_latency_ns, i, token_count;
        begin
            token_count = recv_idx;
            hw_cycles = t_last_token - t_first_char;
            hw_latency_ns = hw_cycles * CLK_PERIOD;

            $display("  Text length: %0d characters", text_len);
            $display("  Tokens received: %0d (expected %0d)", token_count, expected_count);
            $display("  Hardware cycles: %0d", hw_cycles);
            $display("  Hardware latency: %0d ns (%0d.%0d us)",
                     hw_latency_ns,
                     hw_latency_ns / 1000,
                     (hw_latency_ns % 1000) / 100);
            $display("  CPU baseline: %0d ns (%0d.%0d us)",
                     cpu_latency_ns,
                     cpu_latency_ns / 1000,
                     (cpu_latency_ns % 1000) / 100);
            if (hw_latency_ns > 0 && cpu_latency_ns > 0) begin
                if (hw_latency_ns < cpu_latency_ns)
                    $display("  >>> FPGA is %0dx faster than CPU <<<", cpu_latency_ns / hw_latency_ns);
                else
                    $display("  CPU is %0dx faster than FPGA", hw_latency_ns / cpu_latency_ns);
            end

            $display("  Token IDs:");
            for (i = 0; i < token_count && i < 50; i = i + 1)
                $display("    [%0d] = %0d", i, received_tokens[i]);
            if (token_count > 50)
                $display("    ... (%0d more tokens)", token_count - 50);

            if (token_count !== expected_count) begin
                $display("  *** FAIL: Expected %0d tokens, got %0d ***", expected_count, token_count);
                total_failures = total_failures + 1;
            end else begin
                $display("  PASS");
            end

            total_tests = total_tests + 1;
            repeat (200) @(posedge clk);
        end
    endtask

    // ========================================================================
    // Main Test Sequence
    // ========================================================================
    initial begin
        clk = 0;
        aresetn = 0;
        s_axi_awaddr  = 0;
        s_axi_awvalid = 0;
        s_axi_wdata   = 0;
        s_axi_wstrb   = 0;
        s_axi_wvalid  = 0;
        s_axi_bready  = 0;
        s_axi_araddr  = 0;
        s_axi_arvalid = 0;
        s_axi_rready  = 0;
        total_tests = 0;
        total_failures = 0;

        $display("");
        $display("============================================================");
        $display(" FPGA WordPiece Tokenizer - Performance Measurement");
        $display(" Clock: 100 MHz (%0d ns period)", CLK_PERIOD);
        $display(" Full AXI-Lite path (no MicroBlaze polling overhead)");
        $display("============================================================");

        repeat (20) @(posedge clk);
        aresetn = 1;
        repeat (10) @(posedge clk);

        // ================================================================
        // TEST 1: "the quick brown fox jumps over the lazy dog"
        // CPU baseline: 9 tokens, 26.7 us = 26700 ns
        // ================================================================
        $display("");
        $display("===== TEST 1: the quick brown fox jumps over the lazy dog =====");
        text_buf[0]="t"; text_buf[1]="h"; text_buf[2]="e"; text_buf[3]=" ";
        text_buf[4]="q"; text_buf[5]="u"; text_buf[6]="i"; text_buf[7]="c"; text_buf[8]="k"; text_buf[9]=" ";
        text_buf[10]="b"; text_buf[11]="r"; text_buf[12]="o"; text_buf[13]="w"; text_buf[14]="n"; text_buf[15]=" ";
        text_buf[16]="f"; text_buf[17]="o"; text_buf[18]="x"; text_buf[19]=" ";
        text_buf[20]="j"; text_buf[21]="u"; text_buf[22]="m"; text_buf[23]="p"; text_buf[24]="s"; text_buf[25]=" ";
        text_buf[26]="o"; text_buf[27]="v"; text_buf[28]="e"; text_buf[29]="r"; text_buf[30]=" ";
        text_buf[31]="t"; text_buf[32]="h"; text_buf[33]="e"; text_buf[34]=" ";
        text_buf[35]="l"; text_buf[36]="a"; text_buf[37]="z"; text_buf[38]="y"; text_buf[39]=" ";
        text_buf[40]="d"; text_buf[41]="o"; text_buf[42]="g";
        text_len = 43;

        send_text_and_measure;
        read_all_tokens;
        report_results(9, 26700);

        // ================================================================
        // TEST 2: "unquestionably the embedding layer transforms input tokens into vectors"
        // CPU baseline: 15 tokens, 99.5 us = 99500 ns
        // ================================================================
        $display("");
        $display("===== TEST 2: unquestionably the embedding...vectors =====");
        text_buf[0]="u"; text_buf[1]="n"; text_buf[2]="q"; text_buf[3]="u"; text_buf[4]="e";
        text_buf[5]="s"; text_buf[6]="t"; text_buf[7]="i"; text_buf[8]="o"; text_buf[9]="n";
        text_buf[10]="a"; text_buf[11]="b"; text_buf[12]="l"; text_buf[13]="y"; text_buf[14]=" ";
        text_buf[15]="t"; text_buf[16]="h"; text_buf[17]="e"; text_buf[18]=" ";
        text_buf[19]="e"; text_buf[20]="m"; text_buf[21]="b"; text_buf[22]="e"; text_buf[23]="d";
        text_buf[24]="d"; text_buf[25]="i"; text_buf[26]="n"; text_buf[27]="g"; text_buf[28]=" ";
        text_buf[29]="l"; text_buf[30]="a"; text_buf[31]="y"; text_buf[32]="e"; text_buf[33]="r"; text_buf[34]=" ";
        text_buf[35]="t"; text_buf[36]="r"; text_buf[37]="a"; text_buf[38]="n"; text_buf[39]="s";
        text_buf[40]="f"; text_buf[41]="o"; text_buf[42]="r"; text_buf[43]="m"; text_buf[44]="s"; text_buf[45]=" ";
        text_buf[46]="i"; text_buf[47]="n"; text_buf[48]="p"; text_buf[49]="u"; text_buf[50]="t"; text_buf[51]=" ";
        text_buf[52]="t"; text_buf[53]="o"; text_buf[54]="k"; text_buf[55]="e"; text_buf[56]="n"; text_buf[57]="s"; text_buf[58]=" ";
        text_buf[59]="i"; text_buf[60]="n"; text_buf[61]="t"; text_buf[62]="o"; text_buf[63]=" ";
        text_buf[64]="v"; text_buf[65]="e"; text_buf[66]="c"; text_buf[67]="t"; text_buf[68]="o";
        text_buf[69]="r"; text_buf[70]="s";
        text_len = 71;

        send_text_and_measure;
        read_all_tokens;
        report_results(15, 99500);

        // ================================================================
        // TEST 3: long machine learning text
        // CPU baseline: 44 tokens, 180.4 us = 180400 ns
        // ================================================================
        $display("");
        $display("===== TEST 3: machine learning...natural language processing =====");
        text_buf[0]="m"; text_buf[1]="a"; text_buf[2]="c"; text_buf[3]="h"; text_buf[4]="i"; text_buf[5]="n"; text_buf[6]="e"; text_buf[7]=" ";
        text_buf[8]="l"; text_buf[9]="e"; text_buf[10]="a"; text_buf[11]="r"; text_buf[12]="n"; text_buf[13]="i"; text_buf[14]="n"; text_buf[15]="g"; text_buf[16]=" ";
        text_buf[17]="i"; text_buf[18]="s"; text_buf[19]=" ";
        text_buf[20]="a"; text_buf[21]=" ";
        text_buf[22]="s"; text_buf[23]="u"; text_buf[24]="b"; text_buf[25]="s"; text_buf[26]="e"; text_buf[27]="t"; text_buf[28]=" ";
        text_buf[29]="o"; text_buf[30]="f"; text_buf[31]=" ";
        text_buf[32]="a"; text_buf[33]="r"; text_buf[34]="t"; text_buf[35]="i"; text_buf[36]="f"; text_buf[37]="i"; text_buf[38]="c"; text_buf[39]="i"; text_buf[40]="a"; text_buf[41]="l"; text_buf[42]=" ";
        text_buf[43]="i"; text_buf[44]="n"; text_buf[45]="t"; text_buf[46]="e"; text_buf[47]="l"; text_buf[48]="l"; text_buf[49]="i"; text_buf[50]="g"; text_buf[51]="e"; text_buf[52]="n"; text_buf[53]="c"; text_buf[54]="e"; text_buf[55]=" ";
        text_buf[56]="t"; text_buf[57]="h"; text_buf[58]="a"; text_buf[59]="t"; text_buf[60]=" ";
        text_buf[61]="f"; text_buf[62]="o"; text_buf[63]="c"; text_buf[64]="u"; text_buf[65]="s"; text_buf[66]="e"; text_buf[67]="s"; text_buf[68]=" ";
        text_buf[69]="o"; text_buf[70]="n"; text_buf[71]=" ";
        text_buf[72]="b"; text_buf[73]="u"; text_buf[74]="i"; text_buf[75]="l"; text_buf[76]="d"; text_buf[77]="i"; text_buf[78]="n"; text_buf[79]="g"; text_buf[80]=" ";
        text_buf[81]="s"; text_buf[82]="y"; text_buf[83]="s"; text_buf[84]="t"; text_buf[85]="e"; text_buf[86]="m"; text_buf[87]="s"; text_buf[88]=" ";
        text_buf[89]="t"; text_buf[90]="h"; text_buf[91]="a"; text_buf[92]="t"; text_buf[93]=" ";
        text_buf[94]="l"; text_buf[95]="e"; text_buf[96]="a"; text_buf[97]="r"; text_buf[98]="n"; text_buf[99]=" ";
        text_buf[100]="f"; text_buf[101]="r"; text_buf[102]="o"; text_buf[103]="m"; text_buf[104]=" ";
        text_buf[105]="d"; text_buf[106]="a"; text_buf[107]="t"; text_buf[108]="a"; text_buf[109]=" ";
        text_buf[110]="i"; text_buf[111]="n"; text_buf[112]="s"; text_buf[113]="t"; text_buf[114]="e"; text_buf[115]="a"; text_buf[116]="d"; text_buf[117]=" ";
        text_buf[118]="o"; text_buf[119]="f"; text_buf[120]=" ";
        text_buf[121]="b"; text_buf[122]="e"; text_buf[123]="i"; text_buf[124]="n"; text_buf[125]="g"; text_buf[126]=" ";
        text_buf[127]="e"; text_buf[128]="x"; text_buf[129]="p"; text_buf[130]="l"; text_buf[131]="i"; text_buf[132]="c"; text_buf[133]="i"; text_buf[134]="t"; text_buf[135]="l"; text_buf[136]="y"; text_buf[137]=" ";
        text_buf[138]="p"; text_buf[139]="r"; text_buf[140]="o"; text_buf[141]="g"; text_buf[142]="r"; text_buf[143]="a"; text_buf[144]="m"; text_buf[145]="m"; text_buf[146]="e"; text_buf[147]="d"; text_buf[148]=" ";
        text_buf[149]="i"; text_buf[150]="t"; text_buf[151]=" ";
        text_buf[152]="h"; text_buf[153]="a"; text_buf[154]="s"; text_buf[155]=" ";
        text_buf[156]="b"; text_buf[157]="e"; text_buf[158]="c"; text_buf[159]="o"; text_buf[160]="m"; text_buf[161]="e"; text_buf[162]=" ";
        text_buf[163]="a"; text_buf[164]=" ";
        text_buf[165]="c"; text_buf[166]="r"; text_buf[167]="i"; text_buf[168]="t"; text_buf[169]="i"; text_buf[170]="c"; text_buf[171]="a"; text_buf[172]="l"; text_buf[173]=" ";
        text_buf[174]="c"; text_buf[175]="o"; text_buf[176]="m"; text_buf[177]="p"; text_buf[178]="o"; text_buf[179]="n"; text_buf[180]="e"; text_buf[181]="n"; text_buf[182]="t"; text_buf[183]=" ";
        text_buf[184]="o"; text_buf[185]="f"; text_buf[186]=" ";
        text_buf[187]="m"; text_buf[188]="o"; text_buf[189]="d"; text_buf[190]="e"; text_buf[191]="r"; text_buf[192]="n"; text_buf[193]=" ";
        text_buf[194]="t"; text_buf[195]="e"; text_buf[196]="c"; text_buf[197]="h"; text_buf[198]="n"; text_buf[199]="o"; text_buf[200]="l"; text_buf[201]="o"; text_buf[202]="g"; text_buf[203]="y"; text_buf[204]=" ";
        text_buf[205]="p"; text_buf[206]="o"; text_buf[207]="w"; text_buf[208]="e"; text_buf[209]="r"; text_buf[210]="i"; text_buf[211]="n"; text_buf[212]="g"; text_buf[213]=" ";
        text_buf[214]="a"; text_buf[215]="p"; text_buf[216]="p"; text_buf[217]="l"; text_buf[218]="i"; text_buf[219]="c"; text_buf[220]="a"; text_buf[221]="t"; text_buf[222]="i"; text_buf[223]="o"; text_buf[224]="n"; text_buf[225]="s"; text_buf[226]=" ";
        text_buf[227]="f"; text_buf[228]="r"; text_buf[229]="o"; text_buf[230]="m"; text_buf[231]=" ";
        text_buf[232]="r"; text_buf[233]="e"; text_buf[234]="c"; text_buf[235]="o"; text_buf[236]="m"; text_buf[237]="m"; text_buf[238]="e"; text_buf[239]="n"; text_buf[240]="d"; text_buf[241]="a"; text_buf[242]="t"; text_buf[243]="i"; text_buf[244]="o"; text_buf[245]="n"; text_buf[246]=" ";
        text_buf[247]="s"; text_buf[248]="y"; text_buf[249]="s"; text_buf[250]="t"; text_buf[251]="e"; text_buf[252]="m"; text_buf[253]="s"; text_buf[254]=" ";
        text_buf[255]="t"; text_buf[256]="o"; text_buf[257]=" ";
        text_buf[258]="a"; text_buf[259]="u"; text_buf[260]="t"; text_buf[261]="o"; text_buf[262]="n"; text_buf[263]="o"; text_buf[264]="m"; text_buf[265]="o"; text_buf[266]="u"; text_buf[267]="s"; text_buf[268]=" ";
        text_buf[269]="v"; text_buf[270]="e"; text_buf[271]="h"; text_buf[272]="i"; text_buf[273]="c"; text_buf[274]="l"; text_buf[275]="e"; text_buf[276]="s"; text_buf[277]=" ";
        text_buf[278]="a"; text_buf[279]="n"; text_buf[280]="d"; text_buf[281]=" ";
        text_buf[282]="n"; text_buf[283]="a"; text_buf[284]="t"; text_buf[285]="u"; text_buf[286]="r"; text_buf[287]="a"; text_buf[288]="l"; text_buf[289]=" ";
        text_buf[290]="l"; text_buf[291]="a"; text_buf[292]="n"; text_buf[293]="g"; text_buf[294]="u"; text_buf[295]="a"; text_buf[296]="g"; text_buf[297]="e"; text_buf[298]=" ";
        text_buf[299]="p"; text_buf[300]="r"; text_buf[301]="o"; text_buf[302]="c"; text_buf[303]="e"; text_buf[304]="s"; text_buf[305]="s"; text_buf[306]="i"; text_buf[307]="n"; text_buf[308]="g";
        text_len = 309;

        send_text_and_measure;
        read_all_tokens;
        report_results(44, 180400);

        // Summary
        $display("");
        $display("============================================================");
        $display(" PERFORMANCE SUMMARY");
        $display("============================================================");
        $display(" Tests run: %0d, Failures: %0d", total_tests, total_failures);
        $display("============================================================");
        if (total_failures == 0)
            $display(" ALL TESTS PASSED");
        else
            $display(" %0d TEST(S) FAILED", total_failures);
        $display("============================================================");

        $finish;
    end

    // Timeout
    initial begin
        #200_000_000; // 200 ms
        $display("FATAL: Simulation timeout!");
        $finish;
    end

endmodule