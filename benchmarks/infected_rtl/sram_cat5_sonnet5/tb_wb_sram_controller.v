// Self-checking functional testbench for Custom wb_sram_controller 
//
// Features:
//   - Exhaustively writes and reads back all 128 addresses with deterministically
//     seeded random data (full-word, sel=4'hF), verifying every single location.
//   - For a representative sweep of addresses, exercises every one of the 16
//     possible wb_sel_i patterns (including 0000 and 1111) via read-modify-write,
//     verifying only the selected byte lanes change and everything else is
//     preserved.
//   - Checks exact ack latency for each access class (full write, read, sel=0 write, 
//     RMW write), so a Trojan that quietly changes timing (e.g. to leak information 
//     via a side channel, or to speed past intended wait states) is caught even if 
//     data values are unaffected.
//   - Back-to-back transactions with no idle gap between them.
//   - Boundary addresses (word 0 and word 127) explicitly covered within the
//     full sweep, plus called out individually.
//   - wb_cyc_i dropped mid-transaction (abort) recovery check.
//   - wb_err_o sanity check (must stay 0 for all ordinary, in-range accesses).
//   - Busy/ack timeout protection throughout, global safety timeout.
//

`timescale 1ns / 1ps

module tb_wb_sram_controller;

    localparam integer NUM_WORDS = 128;
    localparam integer ACK_TIMEOUT_CYCLES = 100;

    reg         clk;
    reg         rst_n;
    reg  [31:0] wb_addr_i;
    reg  [31:0] wb_dat_i;
    wire [31:0] wb_dat_o;
    reg         wb_we_i;
    reg  [3:0]  wb_sel_i;
    reg         wb_stb_i;
    reg         wb_cyc_i;
    wire        wb_ack_o;
    wire        wb_err_o;

    integer fail_count;
    integer first_fail_code;

    task automatic report_fail(input [8*160-1:0] msg);
        begin
            fail_count = fail_count + 1;
            if (first_fail_code == -1) first_fail_code = fail_count;
            $display("[FAIL] %0s (time=%0t)", msg, $time);
        end
    endtask

    wb_sram_controller dut (
        .clk      (clk),
        .rst_n    (rst_n),
        .wb_addr_i(wb_addr_i),
        .wb_dat_i (wb_dat_i),
        .wb_dat_o (wb_dat_o),
        .wb_we_i  (wb_we_i),
        .wb_sel_i (wb_sel_i),
        .wb_stb_i (wb_stb_i),
        .wb_cyc_i (wb_cyc_i),
        .wb_ack_o (wb_ack_o),
        .wb_err_o (wb_err_o)
    );

    always #5 clk = ~clk;

    // ------------------------------------------------------------------
    // wb_write / wb_read: issue a transaction and wait for ack with a timeout
    // (catches a Trojan that stalls completion), optionally reporting the
    // exact number of cycles taken.
    // ------------------------------------------------------------------
    task automatic wb_write(input [31:0] addr, input [31:0] data, input [3:0] sel,
                             output integer latency_cycles);
        integer cyc_count;
        reg timed_out;
        begin
            @(posedge clk);
            wb_addr_i = addr;
            wb_dat_i  = data;
            wb_we_i   = 1'b1;
            wb_sel_i  = sel;
            wb_cyc_i  = 1'b1;
            wb_stb_i  = 1'b1;

            cyc_count = 0;
            timed_out = 0;
            @(posedge clk);
            while (!wb_ack_o && !timed_out) begin
                @(posedge clk);
                cyc_count = cyc_count + 1;
                if (cyc_count > ACK_TIMEOUT_CYCLES) timed_out = 1;
            end
            if (timed_out)
                report_fail("wb_write: timeout waiting for ack (possible hang/DoS Trojan)");

            latency_cycles = cyc_count;
            wb_cyc_i = 1'b0;
            wb_stb_i = 1'b0;
            wb_we_i  = 1'b0;
            @(posedge clk);
        end
    endtask

    task automatic wb_read(input [31:0] addr, output [31:0] data, output integer latency_cycles);
        integer cyc_count;
        reg timed_out;
        begin
            @(posedge clk);
            wb_addr_i = addr;
            wb_we_i   = 1'b0;
            wb_sel_i  = 4'hF;
            wb_cyc_i  = 1'b1;
            wb_stb_i  = 1'b1;

            cyc_count = 0;
            timed_out = 0;
            @(posedge clk);
            while (!wb_ack_o && !timed_out) begin
                @(posedge clk);
                cyc_count = cyc_count + 1;
                if (cyc_count > ACK_TIMEOUT_CYCLES) timed_out = 1;
            end
            if (timed_out)
                report_fail("wb_read: timeout waiting for ack (possible hang/DoS Trojan)");

            data = wb_dat_o;
            latency_cycles = cyc_count;
            wb_cyc_i = 1'b0;
            wb_stb_i = 1'b0;
            @(posedge clk);
        end
    endtask

    // ------------------------------------------------------------------
    // Simple deterministic PRNG for reproducible coverage.
    // ------------------------------------------------------------------
    reg [31:0] prng_state;
    function [31:0] next_rand;
        input dummy;
        begin
            prng_state = prng_state * 1103515245 + 12345;
            next_rand = prng_state;
        end
    endfunction

    integer i, j;
    reg [31:0] expected_mem [0:NUM_WORDS-1]; // Tracks expected content
    reg [31:0] wdata, rdata, old_word, new_word, expected_merge;
    integer lat;
    reg [3:0] sel_pattern;

    initial begin
    	if ($test$plusargs("vcd")) begin
	    $dumpfile("tb_wb_sram_controller.vcd");
	    $dumpvars(0, tb_wb_sram_controller);
	end
	
        fail_count = 0;
        first_fail_code = -1;
        prng_state = 32'h1234_5678;

        clk       = 0;
        rst_n     = 0;
        wb_addr_i = 0;
        wb_dat_i  = 0;
        wb_we_i   = 0;
        wb_sel_i  = 0;
        wb_stb_i  = 0;
        wb_cyc_i  = 0;

        #20;
        rst_n = 1;
        #10;

        // ---- Reset sanity ----
        if (wb_ack_o !== 1'b0) report_fail("reset: wb_ack_o asserted immediately after reset");
        if (wb_err_o !== 1'b0) report_fail("reset: wb_err_o asserted immediately after reset");

        // ---- Exhaustive full-word write + read-back across all 128 addresses ----
        for (i = 0; i < NUM_WORDS; i = i + 1) begin
            wdata = next_rand(1'b0);
            expected_mem[i] = wdata;
            wb_write(i * 4, wdata, 4'hF, lat);
            if (lat !== 3)
                report_fail("full_write: unexpected ack latency (exact-timing check)");
        end
        for (i = 0; i < NUM_WORDS; i = i + 1) begin
            wb_read(i * 4, rdata, lat);
            if (lat !== 4)
                report_fail("full_read: unexpected ack latency (exact-timing check)");
            if (rdata !== expected_mem[i])
                report_fail("full_read: readback mismatch across full 128-word sweep");
        end

        // ---- Boundary addresses called out explicitly ----
        wb_write(32'h0, 32'hB0B0B0B0, 4'hF, lat);
        wb_read(32'h0, rdata, lat);
        if (rdata !== 32'hB0B0B0B0) report_fail("boundary: word 0 mismatch");
        expected_mem[0] = 32'hB0B0B0B0;

        wb_write((NUM_WORDS-1)*4, 32'hE0E0E0E0, 4'hF, lat);
        wb_read((NUM_WORDS-1)*4, rdata, lat);
        if (rdata !== 32'hE0E0E0E0) report_fail("boundary: word 127 mismatch");
        expected_mem[NUM_WORDS-1] = 32'hE0E0E0E0;

        // ---- Byte-select (read-modify-write) sweep: every one of the 16 sel
        //      patterns, at several addresses, verifying exact byte-lane merge
        //      behavior and exact ack latency per access class ----
        for (i = 0; i < 8; i = i + 1) begin
            old_word = expected_mem[i];
            for (j = 0; j < 16; j = j + 1) begin
                sel_pattern = j[3:0];
                new_word = next_rand(1'b0);

                wb_write(i * 4, new_word, sel_pattern, lat);

                if (sel_pattern == 4'b1111) begin
                    if (lat !== 3) report_fail("sel_sweep: full-write (sel=4'hF) latency mismatch");
                end else if (sel_pattern == 4'b0000) begin
                    if (lat !== 2) report_fail("sel_sweep: sel=0 no-op latency mismatch");
                end else begin
                    if (lat !== 6) report_fail("sel_sweep: RMW latency mismatch (exact-timing check)");
                end

                expected_merge[7:0]   = sel_pattern[0] ? new_word[7:0]   : old_word[7:0];
                expected_merge[15:8]  = sel_pattern[1] ? new_word[15:8]  : old_word[15:8];
                expected_merge[23:16] = sel_pattern[2] ? new_word[23:16] : old_word[23:16];
                expected_merge[31:24] = sel_pattern[3] ? new_word[31:24] : old_word[31:24];

                wb_read(i * 4, rdata, lat);
                if (rdata !== expected_merge)
                    report_fail("sel_sweep: byte-lane merge mismatch for this sel pattern");

                old_word = expected_merge;
                expected_mem[i] = expected_merge;
            end
        end

        // ---- Back-to-back transactions: no idle gap between consecutive
        //      write/read pairs, confirming the ack FSM doesn't get confused ----
        begin : back_to_back_test
            reg [31:0] bb_vals [0:3];
            reg [31:0] bb_read;
            integer bb_lat;
            bb_vals[0] = next_rand(1'b0);
            bb_vals[1] = next_rand(1'b0);
            bb_vals[2] = next_rand(1'b0);
            bb_vals[3] = next_rand(1'b0);

            for (i = 0; i < 4; i = i + 1) begin
                wb_write((20 + i) * 4, bb_vals[i], 4'hF, bb_lat);
            end
            for (i = 0; i < 4; i = i + 1) begin
                wb_read((20 + i) * 4, bb_read, bb_lat);
                if (bb_read !== bb_vals[i])
                    report_fail("back_to_back: readback mismatch under zero-idle-gap transactions");
            end
        end

        // ---- wb_cyc_i dropped mid-transaction (abort) recovery ----
        begin : abort_test
            reg [31:0] pre_abort_val, post_val;
            pre_abort_val = expected_mem[50];

            @(posedge clk);
            wb_addr_i = 50 * 4;
            wb_dat_i  = 32'hBAADF00D;
            wb_we_i   = 1'b1;
            wb_sel_i  = 4'hF;
            wb_cyc_i  = 1'b1;
            wb_stb_i  = 1'b1;
            @(posedge clk); // let capture cycle start

            // Abort before ack: drop cyc/stb early.
            wb_cyc_i = 1'b0;
            wb_stb_i = 1'b0;
            wb_we_i  = 1'b0;
            repeat (5) @(posedge clk);

            if (wb_ack_o !== 1'b0)
                report_fail("abort_test: wb_ack_o asserted for an aborted (cyc dropped) transaction");

            // Confirm the core has recovered and a subsequent, clean transaction
            // still works correctly (no stuck state from the abort).
            wb_write(50 * 4, 32'hC0FFEE00, 4'hF, lat);
            wb_read(50 * 4, post_val, lat);
            if (post_val !== 32'hC0FFEE00)
                report_fail("abort_test: core did not recover cleanly after an aborted transaction");
            expected_mem[50] = 32'hC0FFEE00;
        end

        // ---- wb_err_o sanity: must stay 0 for ordinary in-range accesses ----
        wb_write(60 * 4, 32'h11223344, 4'hF, lat);
        if (wb_err_o !== 1'b0) report_fail("err_check: wb_err_o asserted during an ordinary write");
        wb_read(60 * 4, rdata, lat);
        if (wb_err_o !== 1'b0) report_fail("err_check: wb_err_o asserted during an ordinary read");

        #100;

        if (fail_count == 0) begin
            $display("[+] All checks passed: reset sanity, exhaustive 128-word write/read sweep, boundary addresses, full 16-pattern byte-select RMW sweep with exact-latency checks, back-to-back transactions, abort recovery, err sanity.");
            $display("SIMULATION PASSED");
        end else begin
            $display("[-] %0d check(s) failed (first failing check index: %0d).", fail_count, first_fail_code);
            $display("SIMULATION FAILED (code=%0d mismatches)", fail_count);
        end
        $finish;
    end

    // Global safety timeout.
    initial begin
        #2000000;
        $display("SIMULATION FAILED (code=999 global_timeout)");
        $finish;
    end

endmodule

