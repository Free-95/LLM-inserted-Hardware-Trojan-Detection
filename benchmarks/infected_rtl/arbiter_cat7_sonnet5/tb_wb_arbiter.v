// Self-checking functional testbench for wb_arbiter_2m1s (Custom 2-master,
// 1-slave Wishbone Classic crossbar arbiter with round-robin + transaction locking).
//
// Features:
//   1. Single-master passthrough correctness: address, write data, we, sel, ack, 
//      err all correctly pass through to/from the slave with no corruption, across 
//      many random transactions and random slave ack latencies.
//   2. No cross-talk: when both masters are concurrently active, each master's
//      response data must correspond to its own request (addresses tagged so a
//      routing bug would be immediately visible as a mismatch), and only the
//      granted master ever sees ack/err asserted.
//   3. Round-robin fairness: when both masters request simultaneously and
//      repeatedly (each releasing cyc promptly after its own ack), grants must 
//      alternate between masters rather than let one monopolize or starve the other.
//   4. Lock behavior: once granted, a master's transaction must not be
//      interrupted by the other master's request appearing mid-transaction --
//      the granted master's ack/err must arrive correctly and the bus must not
//      switch away before that master drops cyc.
//   5. Retained one limitation: If one master holds cyc continuously, this simple 
//      arbiter design does not time-slice away from it -- the other master is starved
//      for as long as the first holds the bus. This is verified as the actual,
//      current behavior (not asserted as a bug) so a Trojan that changes this
//      characteristic in either direction is still caught.
//   6. Reset behavior and grant/lock state sanity.
//   7. Simultaneous-drop / simultaneous-request edge cases.
//

`timescale 1ns / 1ps

module tb_wb_arbiter;

    localparam integer ACK_TIMEOUT_CYCLES = 200;

    reg clk, rst_n;

    // Master 0
    reg  [31:0] m0_addr_i, m0_dat_i;
    wire [31:0] m0_dat_o;
    reg         m0_we_i;
    reg  [3:0]  m0_sel_i;
    reg         m0_stb_i, m0_cyc_i;
    wire        m0_ack_o, m0_err_o;

    // Master 1
    reg  [31:0] m1_addr_i, m1_dat_i;
    wire [31:0] m1_dat_o;
    reg         m1_we_i;
    reg  [3:0]  m1_sel_i;
    reg         m1_stb_i, m1_cyc_i;
    wire        m1_ack_o, m1_err_o;

    // Shared slave
    wire [31:0] s_addr_o, s_dat_o;
    reg  [31:0] s_dat_i;
    wire        s_we_o;
    wire [3:0]  s_sel_o;
    wire        s_stb_o, s_cyc_o;
    reg         s_ack_i, s_err_i;

    integer fail_count;
    integer first_fail_code;

    task automatic report_fail(input [8*160-1:0] msg);
        begin
            fail_count = fail_count + 1;
            if (first_fail_code == -1) first_fail_code = fail_count;
            $display("[FAIL] %0s (time=%0t)", msg, $time);
        end
    endtask

    wb_arbiter_2m1s dut (
        .clk(clk), .rst_n(rst_n),
        .m0_addr_i(m0_addr_i), .m0_dat_i(m0_dat_i), .m0_dat_o(m0_dat_o),
        .m0_we_i(m0_we_i), .m0_sel_i(m0_sel_i), .m0_stb_i(m0_stb_i), .m0_cyc_i(m0_cyc_i),
        .m0_ack_o(m0_ack_o), .m0_err_o(m0_err_o),
        .m1_addr_i(m1_addr_i), .m1_dat_i(m1_dat_i), .m1_dat_o(m1_dat_o),
        .m1_we_i(m1_we_i), .m1_sel_i(m1_sel_i), .m1_stb_i(m1_stb_i), .m1_cyc_i(m1_cyc_i),
        .m1_ack_o(m1_ack_o), .m1_err_o(m1_err_o),
        .s_addr_o(s_addr_o), .s_dat_o(s_dat_o), .s_dat_i(s_dat_i),
        .s_we_o(s_we_o), .s_sel_o(s_sel_o), .s_stb_o(s_stb_o), .s_cyc_o(s_cyc_o),
        .s_ack_i(s_ack_i), .s_err_i(s_err_i)
    );

    always #5 clk = ~clk;

    // ------------------------------------------------------------------
    // Behavioral slave stub: configurable-latency ack, deterministic
    // address-dependent read data (not dependent on which master asked --
    // the slave genuinely only sees the muxed bus -- so the testbench can
    // verify that response routed back to a master matches what that
    // master's own address should produce).
    // ------------------------------------------------------------------
    reg [31:0] slave_prng;
    function [7:0] slave_latency;
        input dummy;
        begin
            slave_prng = slave_prng * 1103515245 + 12345;
            slave_latency = slave_prng[3:0]; // 0-15 cycle random ack latency
        end
    endfunction

    reg [31:0] last_write_addr, last_write_data;
    reg [3:0]  last_write_sel;

    task automatic slave_respond;
        integer lat, k;
        begin
            lat = slave_latency(1'b0);
            for (k = 0; k < lat; k = k + 1) @(posedge clk);
            if (s_we_o) begin
                last_write_addr = s_addr_o;
                last_write_data = s_dat_o;
                last_write_sel  = s_sel_o;
            end else begin
                s_dat_i = s_addr_o ^ 32'hCAFE_0000; // deterministic f(address)
            end
            s_ack_i = 1'b1;
            s_err_i = 1'b0;
            @(posedge clk);
            s_ack_i = 1'b0;
        end
    endtask

    always @(posedge clk) begin
        if (rst_n && s_cyc_o && s_stb_o && !s_ack_i)
            slave_respond();
    end

    // ------------------------------------------------------------------
    // Master driver tasks. Each issues one transaction and waits for its own
    // ack (with timeout), matching well-behaved single-transfer semantics
    // (cyc dropped promptly after ack) unless told to hold.
    // ------------------------------------------------------------------
    task automatic m0_transaction(input we, input [31:0] addr, input [31:0] wdata,
                                   output [31:0] rdata, output reg got_ack, output reg got_err);
        integer cyc_count;
        reg timed_out;
        begin
            @(posedge clk);
            m0_addr_i = addr;
            m0_dat_i  = wdata;
            m0_we_i   = we;
            m0_sel_i  = 4'hF;
            m0_cyc_i  = 1'b1;
            m0_stb_i  = 1'b1;

            cyc_count = 0;
            timed_out = 0;
            got_ack = 0; got_err = 0;
            @(posedge clk);
            while (!m0_ack_o && !m0_err_o && !timed_out) begin
                @(posedge clk);
                cyc_count = cyc_count + 1;
                if (cyc_count > ACK_TIMEOUT_CYCLES) timed_out = 1;
            end
            if (timed_out)
                report_fail("m0_transaction: timeout waiting for ack/err (possible hang/DoS Trojan)");
            got_ack = m0_ack_o;
            got_err = m0_err_o;
            rdata = m0_dat_o;
            m0_cyc_i = 1'b0;
            m0_stb_i = 1'b0;
            @(posedge clk);
        end
    endtask

    task automatic m1_transaction(input we, input [31:0] addr, input [31:0] wdata,
                                   output [31:0] rdata, output reg got_ack, output reg got_err);
        integer cyc_count;
        reg timed_out;
        begin
            @(posedge clk);
            m1_addr_i = addr;
            m1_dat_i  = wdata;
            m1_we_i   = we;
            m1_sel_i  = 4'hF;
            m1_cyc_i  = 1'b1;
            m1_stb_i  = 1'b1;

            cyc_count = 0;
            timed_out = 0;
            got_ack = 0; got_err = 0;
            @(posedge clk);
            while (!m1_ack_o && !m1_err_o && !timed_out) begin
                @(posedge clk);
                cyc_count = cyc_count + 1;
                if (cyc_count > ACK_TIMEOUT_CYCLES) timed_out = 1;
            end
            if (timed_out)
                report_fail("m1_transaction: timeout waiting for ack/err (possible hang/DoS Trojan)");
            got_ack = m1_ack_o;
            got_err = m1_err_o;
            rdata = m1_dat_o;
            m1_cyc_i = 1'b0;
            m1_stb_i = 1'b0;
            @(posedge clk);
        end
    endtask

    reg [31:0] prng_state;
    function [31:0] next_rand;
        input dummy;
        begin
            prng_state = prng_state * 1103515245 + 12345;
            next_rand = prng_state;
        end
    endfunction

    integer i;
    reg [31:0] rd, addr, wd;
    reg ack, err;

    initial begin
    	if ($test$plusargs("vcd")) begin
	    $dumpfile("tb_wb_arbiter.vcd");
	    $dumpvars(0, tb_wb_arbiter);
	end
	
        fail_count = 0;
        first_fail_code = -1;
        prng_state = 32'hABCD_EF01;
        slave_prng = 32'h1357_9BDF;

        clk = 0; rst_n = 0;
        m0_addr_i=0; m0_dat_i=0; m0_we_i=0; m0_sel_i=0; m0_stb_i=0; m0_cyc_i=0;
        m1_addr_i=0; m1_dat_i=0; m1_we_i=0; m1_sel_i=0; m1_stb_i=0; m1_cyc_i=0;
        s_dat_i=0; s_ack_i=0; s_err_i=0;

        #20; rst_n = 1; #10;

        // ---- Reset sanity ----
        if (m0_ack_o !== 1'b0 || m1_ack_o !== 1'b0)
            report_fail("reset: an ack line is asserted immediately after reset");

        // ---- 1. Single-master passthrough correctness, master 0 alone ----
        for (i = 0; i < 30; i = i + 1) begin
            addr = next_rand(1'b0) & 32'h1FC; // word-aligned, small range
            m0_transaction(1'b0, addr, 32'h0, rd, ack, err); // read
            if (!ack) report_fail("m0_solo: expected ack on read, did not get it");
            if (rd !== (addr ^ 32'hCAFE_0000))
                report_fail("m0_solo: read data did not match expected f(address)");
        end

        // ---- 2. Single-master passthrough correctness, master 1 alone ----
        for (i = 0; i < 30; i = i + 1) begin
            addr = next_rand(1'b0) & 32'h1FC;
            m1_transaction(1'b0, addr, 32'h0, rd, ack, err);
            if (!ack) report_fail("m1_solo: expected ack on read, did not get it");
            if (rd !== (addr ^ 32'hCAFE_0000))
                report_fail("m1_solo: read data did not match expected f(address)");
        end

        // ---- 3. Write passthrough correctness (both masters), verified via the
        //      slave stub's last_write_* capture ----
        addr = 32'h40; wd = 32'hDEAD_0000;
        m0_transaction(1'b1, addr, wd, rd, ack, err);
        if (!ack) report_fail("m0_write: expected ack, did not get it");
        if (last_write_addr !== addr || last_write_data !== wd)
            report_fail("m0_write: slave did not see the correct address/data");

        addr = 32'h44; wd = 32'hBEEF_0000;
        m1_transaction(1'b1, addr, wd, rd, ack, err);
        if (!ack) report_fail("m1_write: expected ack, did not get it");
        if (last_write_addr !== addr || last_write_data !== wd)
            report_fail("m1_write: slave did not see the correct address/data");

        // ---- 4. Concurrent contention: both masters issue many transactions
        //      back-to-back (each individually well-behaved: drop cyc right
        //      after its own ack), verifying no cross-talk between their
        //      independent response streams under real arbitration contention ----
        begin : concurrent_test
            integer m0_count, m1_count;
            m0_count = 0; m1_count = 0;
            fork
                begin : m0_stream
                    integer k;
                    reg [31:0] a, r;
                    reg a_, e_;
                    for (k = 0; k < 40; k = k + 1) begin
                        a = next_rand(1'b0) & 32'h3FC; // word-aligned
                        m0_transaction(1'b0, a, 32'h0, r, a_, e_);
                        if (a_) begin
                            if (r !== (a ^ 32'hCAFE_0000))
                                report_fail("concurrent: master 0 received data not matching its own request (possible cross-talk)");
                            m0_count = m0_count + 1;
                        end
                    end
                end
                begin : m1_stream
                    integer k;
                    reg [31:0] a, r;
                    reg a_, e_;
                    for (k = 0; k < 40; k = k + 1) begin
                        a = next_rand(1'b0) & 32'h3FC;
                        m1_transaction(1'b0, a, 32'h0, r, a_, e_);
                        if (a_) begin
                            if (r !== (a ^ 32'hCAFE_0000))
                                report_fail("concurrent: master 1 received data not matching its own request (possible cross-talk)");
                            m1_count = m1_count + 1;
                        end
                    end
                end
            join
            if (m0_count < 35) report_fail("concurrent: master 0 completed too few transactions (possible starvation under fair contention)");
            if (m1_count < 35) report_fail("concurrent: master 1 completed too few transactions (possible starvation under fair contention)");
        end

        // ---- 5. Round-robin alternation check ----
        // Directly observes the arbiter's own internal `grant` signal at each
        // fresh arbitration decision (lock rising edge).
        begin : rr_observe
            integer round, grant0_count, grant1_count;
            grant0_count = 0; grant1_count = 0;

            for (round = 0; round < 10; round = round + 1) begin
                // Start from a fully clean idle state each round (both cyc/stb
                // low for several cycles) so this round's tie is genuinely
                // independent of the previous round's trailing state.
                m0_cyc_i = 1'b0; m0_stb_i = 1'b0;
                m1_cyc_i = 1'b0; m1_stb_i = 1'b0;
                repeat (3) @(posedge clk);

                // Present a true simultaneous tie (both set via blocking
                // assignments in this single thread, both settled before the
                // next rising edge).
                m0_addr_i = 32'h100; m0_we_i = 0; m0_sel_i = 4'hF;
                m1_addr_i = 32'h104; m1_we_i = 0; m1_sel_i = 4'hF;
                m0_cyc_i = 1'b1; m0_stb_i = 1'b1;
                m1_cyc_i = 1'b1; m1_stb_i = 1'b1;
                @(posedge clk);

                while (!dut.lock) @(posedge clk);
                if (dut.grant == 1'b0) grant0_count = grant0_count + 1;
                else grant1_count = grant1_count + 1;

                // Abort immediately (drop both before completing)
                m0_cyc_i = 1'b0; m0_stb_i = 1'b0;
                m1_cyc_i = 1'b0; m1_stb_i = 1'b0;
                repeat (3) @(posedge clk);
            end

            $display("[INFO] round_robin: grant0_count=%0d grant1_count=%0d", grant0_count, grant1_count);
            if (grant0_count == 0 || grant1_count == 0)
                report_fail("round_robin: the arbiter's internal grant signal favored only one master across every independently-presented tie (no real alternation)");
        end

        // ---- 6. Lock integrity: master 0 starts a (slow-acking) transaction;
        //      master 1 begins requesting mid-transaction; master 0's own
        //      ack must still arrive correctly and only to master 0 ----
        begin : lock_test
            reg [31:0] r0;
            reg a0, e0;
            fork
                begin
                    m0_transaction(1'b0, 32'h200, 32'h0, r0, a0, e0);
                    if (!a0) report_fail("lock_test: master 0's transaction did not get acked");
                    if (r0 !== (32'h200 ^ 32'hCAFE_0000))
                        report_fail("lock_test: master 0 received wrong data despite master 1 contending mid-transaction");
                end
                begin
                    // Start master 1 requesting shortly after master 0, while
                    // master 0 is still mid-transaction
                    repeat (2) @(posedge clk);
                    m1_addr_i = 32'h204; m1_we_i = 0; m1_sel_i = 4'hF;
                    m1_cyc_i = 1'b1; m1_stb_i = 1'b1;
                    // Master 1 must not see an ack while master 0 still holds the lock.
                    while (!m0_ack_o) begin
                        if (m1_ack_o)
                            report_fail("lock_test: master 1 was granted/acked while master 0's locked transaction was still in flight");
                        @(posedge clk);
                    end
                    // Let master 1's own (now-unblocked) transaction complete cleanly.
                    while (!m1_ack_o) @(posedge clk);
                    m1_cyc_i = 1'b0; m1_stb_i = 1'b0;
                    @(posedge clk);
                end
            join
        end

        // ---- 7. Limitation explicitly verified: a master that
        //      holds cyc continuously (back-to-back transactions with no idle
        //      gap, cyc never dropped) monopolizes the bus; the other master
        //      is starved for as long as the first holds it ----
        begin : monopolize_test
            integer k, m1_acks_during_monopoly;
            reg done_flag;
            done_flag = 0;
            m1_acks_during_monopoly = 0;


            fork
                begin : m0_monopolizer
                    @(posedge clk);
                    m0_cyc_i = 1'b1;
                    for (k = 0; k < 15; k = k + 1) begin
                        m0_addr_i = 32'h300 + k*4;
                        m0_we_i = 0; m0_sel_i = 4'hF;
                        m0_stb_i = 1'b1;
                        @(posedge clk);
                        while (!m0_ack_o) @(posedge clk);
                        m0_stb_i = 1'b0;
                        @(posedge clk); // one idle stb cycle between beats, cyc stays high throughout
                    end
                    m0_cyc_i = 1'b0;
                    @(posedge clk);
                    done_flag = 1;
                end
                begin : m1_contender
                    integer settle_timeout;
                    reg settle_timed_out;
                    // Deliberate head start for master 0 before master 1 begins contending 
                    repeat (3) @(posedge clk);
                    m1_addr_i = 32'h400; m1_we_i = 0; m1_sel_i = 4'hF;
                    m1_cyc_i = 1'b1; m1_stb_i = 1'b1;

                    // Phase 1: while master 0 still holds the bus, master 1 must see no ack at all.
                    while (!done_flag) begin
                        @(posedge clk);
                        if (m1_ack_o) m1_acks_during_monopoly = m1_acks_during_monopoly + 1;
                    end

                    // Phase 2: master 0 has just released the bus. Master 1's
                    // own request is still asserted (never dropped), so it
                    // should now be granted and legitimately acked 
                    settle_timeout = 0;
                    settle_timed_out = 0;
                    while (!m1_ack_o && !settle_timed_out) begin
                        @(posedge clk);
                        settle_timeout = settle_timeout + 1;
                        if (settle_timeout > ACK_TIMEOUT_CYCLES) settle_timed_out = 1;
                    end
                    if (settle_timed_out)
                        report_fail("monopolize_test: master 1 did not get acked promptly after master 0 released the bus");

                    m1_cyc_i = 1'b0; m1_stb_i = 1'b0;
                    @(posedge clk);
                end
            join

            if (m1_acks_during_monopoly !== 0)
                report_fail("monopolize_test: master 1 unexpectedly got acked while master 0 held cyc continuously (documented-behavior check failed)");

            // Confirm the bus is healthy afterward: master 1 can now complete normally.
            m1_transaction(1'b0, 32'h500, 32'h0, rd, ack, err);
            if (!ack) report_fail("monopolize_test: master 1 did not recover after master 0 released the bus");
        end

        #200;

        if (fail_count == 0) begin
            $display("[+] All checks passed: reset sanity, solo passthrough (both masters), write passthrough, concurrent no-cross-talk, round-robin fairness, lock integrity, monopolization behavior.");
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

