`timescale 1ns / 1ps

module shantanu_self_tb;

    // --------------------------------------------------------------------------
    // DUT Parameters (matching cdc_fifo_top.sv specification)
    // --------------------------------------------------------------------------
    localparam int DATA_WIDTH  = 4;
    localparam int FIFO_SIZE   = 4; // DEPTH = 2^FIFO_SIZE = 16 entries
    localparam int SYNC_STAGES = 2;
    localparam int DEPTH       = 1 << FIFO_SIZE;

    // --------------------------------------------------------------------------
    // Port Signals directly matching cdc_fifo_top.sv ports
    // --------------------------------------------------------------------------
    // Write Domain Ports
    logic                  data_in_clk_i;
    logic                  data_in_arst_ni;
    logic [DATA_WIDTH-1:0] data_in_i;
    logic                  data_in_valid_i;
    wire                   data_in_ready_o;
    wire  [FIFO_SIZE:0]    data_in_count_o;

    // Read Domain Ports
    logic                  data_out_clk_i;
    logic                  data_out_arst_ni;
    wire  [DATA_WIDTH-1:0] data_out_o;
    wire                   data_out_valid_o;
    logic                  data_out_ready_i;
    wire  [FIFO_SIZE:0]    data_out_count_o;

    // Clock Periods (dynamically adjustable for frequency sweeps)
    realtime WR_CLK_PERIOD = 10.0ns; // 100 MHz default
    realtime RD_CLK_PERIOD = 25.0ns; //  40 MHz default

    // Clock Generators
    initial begin
        data_in_clk_i = 1'b0;
        forever #(WR_CLK_PERIOD / 2.0) data_in_clk_i = ~data_in_clk_i;
    end

    initial begin
        data_out_clk_i = 1'b0;
        forever #(RD_CLK_PERIOD / 2.0) data_out_clk_i = ~data_out_clk_i;
    end

    // Waveform Dump
    initial begin
        $dumpfile("dump.vcd");
        $dumpvars(0, shantanu_self_tb);
    end

    // --------------------------------------------------------------------------
    // DUT Instantiation: directly connected to top-level port signals
    // --------------------------------------------------------------------------
    cdc_fifo_top #(
        .DATA_WIDTH  (DATA_WIDTH),
        .FIFO_SIZE   (FIFO_SIZE),
        .SYNC_STAGES (SYNC_STAGES)
    ) u_dut (
        // Write Domain Interface
        .data_in_clk_i    (data_in_clk_i),
        .data_in_arst_ni  (data_in_arst_ni),
        .data_in_i        (data_in_i),
        .data_in_valid_i  (data_in_valid_i),
        .data_in_ready_o  (data_in_ready_o),
        .data_in_count_o  (data_in_count_o),

        // Read Domain Interface
        .data_out_clk_i   (data_out_clk_i),
        .data_out_arst_ni (data_out_arst_ni),
        .data_out_o       (data_out_o),
        .data_out_valid_o (data_out_valid_o),
        .data_out_ready_i (data_out_ready_i),
        .data_out_count_o (data_out_count_o)
    );

    // --------------------------------------------------------------------------
    // Interface Instantiation (cdc_fifo_if tied to port signals)
    // --------------------------------------------------------------------------
    cdc_fifo_if #(
        .DATA_WIDTH (DATA_WIDTH),
        .FIFO_SIZE  (FIFO_SIZE)
    ) fifo_if (
        .data_in_clk_i  (data_in_clk_i),
        .data_out_clk_i (data_out_clk_i)
    );
    assign fifo_if.data_in_arst_ni  = data_in_arst_ni;
    assign fifo_if.data_in_i        = data_in_i;
    assign fifo_if.data_in_valid_i  = data_in_valid_i;
    assign fifo_if.data_in_ready_o  = data_in_ready_o;
    assign fifo_if.data_in_count_o  = data_in_count_o;

    assign fifo_if.data_out_arst_ni = data_out_arst_ni;
    assign fifo_if.data_out_o       = data_out_o;
    assign fifo_if.data_out_valid_o = data_out_valid_o;
    assign fifo_if.data_out_ready_i = data_out_ready_i;
    assign fifo_if.data_out_count_o = data_out_count_o;

    // --------------------------------------------------------------------------
    // Test Tracking Variables
    // --------------------------------------------------------------------------
    int    error_count = 0;
    int    step_errors = 0;
    string failed_msgs[$];

    // --------------------------------------------------------------------------
    // Helper Tasks conforming to Ready/Valid Protocol
    // --------------------------------------------------------------------------
    task automatic check(input bit ok, input string msg);
        if (!ok) begin
            error_count++;
            failed_msgs.push_back(msg);
            $error("[FAIL] %s at %0t", msg, $time);
        end
    endtask

    task automatic step_done(input string step_msg);
        if (error_count == step_errors)
            $display("%s PASS", step_msg);
        else
            $display("%s FAIL", step_msg);

        step_errors = error_count;
    endtask

    // Write handshake: asserts valid_i, holds until ready_o asserts at posedge
    task automatic write_word(input logic [DATA_WIDTH-1:0] data);
        @(negedge data_in_clk_i);
        data_in_i       <= data;
        data_in_valid_i <= 1'b1;
        do begin
            @(posedge data_in_clk_i);
        end while (~data_in_ready_o);
        @(negedge data_in_clk_i);
        data_in_valid_i <= 1'b0;
        data_in_i       <= '0;
    endtask

    // Read handshake: FWFT mode, asserts ready_i, captures data_out_o on valid_o
    task automatic read_word(output logic [DATA_WIDTH-1:0] data);
        @(negedge data_out_clk_i);
        data_out_ready_i <= 1'b1;
        do begin
            @(posedge data_out_clk_i);
            if (data_out_valid_o)
                data = data_out_o;
        end while (~data_out_valid_o);
        @(negedge data_out_clk_i);
        data_out_ready_i <= 1'b0;
    endtask

    task automatic read_and_check(input logic [DATA_WIDTH-1:0] expected, input string msg);
        logic [DATA_WIDTH-1:0] rdata;
        read_word(rdata);
        check(rdata === expected,
              $sformatf("%s (Expected: 0x%0h, Got: 0x%0h)", msg, expected, rdata));
    endtask

    task automatic wait_sync();
        repeat (SYNC_STAGES + 2) @(posedge data_out_clk_i);
    endtask

    // --------------------------------------------------------------------------
    // Main Verification Sequence (Steps 1 to 10)
    // --------------------------------------------------------------------------
    initial begin
        logic [DATA_WIDTH-1:0] rand_word;
        logic [DATA_WIDTH-1:0] rand_word1, rand_word2;
        logic [DATA_WIDTH-1:0] fifo_payload [0:DEPTH-1];

        // Initialize driven input ports
        data_in_arst_ni  = 1'b0;
        data_in_valid_i  = 1'b0;
        data_in_i        = '0;
        data_out_arst_ni = 1'b0;
        data_out_ready_i = 1'b0;

        $display("\n==================================================");
        $display(" Running Shantanu CDC FIFO Verification (Steps 1-10)");
        $display(" Target DUT: cdc_fifo_top (DATA_WIDTH=%0d, DEPTH=%0d)", DATA_WIDTH, DEPTH);
        $display("==================================================");

        // ======================================================================
        // STEP 1: Dual Asynchronous Reset & Output Suppression
        // ======================================================================
        #1ns;
        check(
            data_in_ready_o  === 1'b0 &&
            data_out_valid_o === 1'b0,
            "STEP 1: Outputs not held low in active reset (expected ready_o=0, valid_o=0)"
        );

        repeat (5) @(posedge data_in_clk_i);
        repeat (5) @(posedge data_out_clk_i);

        // Deassert both resets asynchronously
        data_in_arst_ni  = 1'b1;
        data_out_arst_ni = 1'b1;

        repeat (2) @(posedge data_in_clk_i);
        repeat (2) @(posedge data_out_clk_i);
        #1ps;

        check(
            data_in_ready_o   === 1'b1 &&
            data_out_valid_o  === 1'b0 &&
            data_in_count_o   === '0 &&
            data_out_count_o  === '0,
            "STEP 1: Reset flags incorrect after reset release (expected ready_o=1, valid_o=0, counts=0)"
        );

        step_done("[STEP 1] Reset initialization ...........................");

        // ======================================================================
        // STEP 2: Single Word Write/Read Data Integrity
        // ======================================================================
        rand_word = $urandom;
        write_word(rand_word);
        wait_sync();
        read_and_check(rand_word, "STEP 2: Single write/read data integrity");

        step_done("[STEP 2] Single write/read data integrity ...............");

        // ======================================================================
        // STEP 3: FIFO Full Detection & Ready Deassertion
        // ======================================================================
        for (int i = 0; i < DEPTH; i++) begin
            fifo_payload[i] = $urandom;
            write_word(fifo_payload[i]);
        end

        #1ps;
        check(
            data_in_ready_o === 1'b0 &&
            data_in_count_o === DEPTH,
            "STEP 3: FIFO full flags incorrect (expected ready_o=0, data_in_count_o=DEPTH)"
        );

        step_done("[STEP 3] FIFO full detection ............................");

        // ======================================================================
        // STEP 4: Overflow Backpressure Protection
        // ======================================================================
        // When full, data_in_ready_o is held low; backpressure prevents additional writes
        check(
            data_in_ready_o === 1'b0 && data_in_count_o === DEPTH,
            "STEP 4: Backpressure active - data_in_ready_o is 0 while FIFO is full"
        );
        repeat (3) @(posedge data_in_clk_i);
        check(
            data_in_ready_o === 1'b0 && data_in_count_o === DEPTH,
            "STEP 4: Backpressure stably held; count remains locked at DEPTH"
        );

        step_done("[STEP 4] Overflow backpressure protection ...............");

        // ======================================================================
        // STEP 5: FIFO Empty Detection and Strict FIFO Ordering
        // ======================================================================
        wait_sync();

        for (int i = 0; i < DEPTH; i++) begin
            read_and_check(
                fifo_payload[i],
                $sformatf("STEP 5: Ordering check Word %0d", i)
            );
        end

        repeat (SYNC_STAGES + 2) @(posedge data_out_clk_i);
        #1ps;

        check(
            data_out_valid_o === 1'b0 && data_out_count_o === '0,
            "STEP 5: FIFO empty flags incorrect (expected valid_o=0, data_out_count_o=0)"
        );

        step_done("[STEP 5] FIFO empty detection and ordering ..............");

        // ======================================================================
        // STEP 6: Underflow Protection (Empty Read Attempt)
        // ======================================================================
        @(negedge data_out_clk_i);
        data_out_ready_i <= 1'b1;
        @(posedge data_out_clk_i);
        #1ps;
        check(
            data_out_valid_o === 1'b0 && data_out_count_o === '0,
            "STEP 6: Underflow protection - valid_o=0 and count=0 during empty read attempt"
        );
        @(negedge data_out_clk_i);
        data_out_ready_i <= 1'b0;

        step_done("[STEP 6] Underflow protection ...........................");

        // ======================================================================
        // STEP 7: Clock Ratio Sweep (Fast-Write 5:1)
        // ======================================================================
        WR_CLK_PERIOD = 10.0ns; // 100 MHz
        RD_CLK_PERIOD = 50.0ns; //  20 MHz

        rand_word1 = $urandom;
        rand_word2 = $urandom;

        write_word(rand_word1);
        write_word(rand_word2);

        wait_sync();

        read_and_check(rand_word1, "STEP 7: Fast-write/slow-read Word 0");
        read_and_check(rand_word2, "STEP 7: Fast-write/slow-read Word 1");

        step_done("[STEP 7] Clock ratio sweep (5:1 fast-write) .............");

        // ======================================================================
        // STEP 8: Clock Ratio Sweep (Slow-Write 1:5)
        // ======================================================================
        WR_CLK_PERIOD = 50.0ns; //  20 MHz
        RD_CLK_PERIOD = 10.0ns; // 100 MHz

        rand_word = $urandom;

        write_word(rand_word);
        wait_sync();

        read_and_check(rand_word, "STEP 8: Slow-write/fast-read Word 0");

        // Restore default balanced clock periods
        WR_CLK_PERIOD = 10.0ns;
        RD_CLK_PERIOD = 25.0ns;

        step_done("[STEP 8] Clock ratio sweep (1:5 slow-write) .............");

        // ======================================================================
        // STEP 9: Concurrent Read and Write Operation
        // ======================================================================
        rand_word1 = $urandom;
        rand_word2 = $urandom;

        fork
            begin
                write_word(rand_word1);
                write_word(rand_word2);
            end
            begin
                wait_sync();
                read_and_check(rand_word1, "STEP 9: Concurrent read Word 0");
                read_and_check(rand_word2, "STEP 9: Concurrent read Word 1");
            end
        join

        step_done("[STEP 9] Concurrent read/write operation ................");

        // ======================================================================
        // STEP 10: DMA Burst Transfer via Occupancy Counter (data_in_count_o)
        // ======================================================================
        begin
            automatic int initial_fill    = (DEPTH * 5) / 8; // e.g. 10 words out of 16
            automatic int remaining_slots;
            logic [DATA_WIDTH-1:0] dma_payload [0:DEPTH-1];
            logic [DATA_WIDTH-1:0] read_back_word;

            // Pre-fill FIFO partially
            for (int i = 0; i < initial_fill; i++) begin
                dma_payload[i] = $urandom;
                write_word(dma_payload[i]);
            end

            // Verify write domain occupancy counter matches actual filled entries
            check(
                data_in_count_o === initial_fill,
                $sformatf("STEP 10: Occupancy counter mismatch (Expected: %0d, Got: %0d)",
                          initial_fill, data_in_count_o)
            );

            // Compute available space safely using occupancy counter
            remaining_slots = DEPTH - data_in_count_o;

            check(
                data_in_ready_o === 1'b1,
                "STEP 10: data_in_ready_o must be 1 prior to filling remaining slots"
            );

            // Burst transfer exactly the available capacity
            for (int b = 0; b < remaining_slots; b++) begin
                dma_payload[initial_fill + b] = $urandom;
                write_word(dma_payload[initial_fill + b]);
            end

            #1ps;
            // Verify FIFO is full and occupancy reaches DEPTH
            check(
                data_in_ready_o === 1'b0 && data_in_count_o === DEPTH,
                "STEP 10: FIFO correctly reached full capacity without dropped words"
            );

            wait_sync();

            // Read back all words and verify complete data integrity
            for (int i = 0; i < DEPTH; i++) begin
                read_and_check(
                    dma_payload[i],
                    $sformatf("STEP 10: DMA integrity check Word %0d", i)
                );
            end

            repeat (SYNC_STAGES + 2) @(posedge data_out_clk_i);
            #1ps;
            check(
                data_out_valid_o === 1'b0 && data_out_count_o === '0,
                "STEP 10: FIFO successfully drained to empty after DMA burst"
            );

            step_done("[STEP 10] DMA burst transfer verified with occupancy ......");
        end

        #100ns;

        // ======================================================================
        // Verification Summary Report
        // ======================================================================
        $display("\n==================================================");
        $display(" CDC FIFO Verification Summary");

        if (error_count == 0) begin
            $display(" Final Status : ALL TESTS PASSED (10/10 Steps)");
        end
        else begin
            $display(" Total Errors : %0d", error_count);
            $display(" Failed Checks:");

            foreach (failed_msgs[i])
                $display("   [%0d] %s", i + 1, failed_msgs[i]);

            $display(" Final Status : VERIFICATION FAILED");
        end

        $display("==================================================");

        $finish;
    end

endmodule
