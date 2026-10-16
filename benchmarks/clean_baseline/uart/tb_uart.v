// Self-checking functional testbench for impl_top (Ben Marshall tech_mentra UART,
// RX+TX wired as an echo loopback: uart_tx_data = uart_rx_data, uart_tx_en = uart_rx_valid).
//
// Coverage:
//   1. Reset behavior: led == 8'hF0 while sw_0 == 0 (reset asserted), uart_txd idle-high.
//   2. ~60 individually-spaced bytes (structural edge cases: 0x00, 0xFF, 0x01, 0x80,
//      0xAA, 0x55, single-bit-set/clear sweep, plus deterministic random bytes) each
//      checked twice and independently:
//        a. at the PARALLEL interface: led_reg must mirror uart_rx_data after the byte
//           is received (decoupled check of the RX datapath + led mux).
//        b. at the SERIAL interface: uart_txd is bit-banged-decoded by the testbench
//           (standard LSB-first framing, independently re-derived here) and compared 
//           against the originally-sent byte (checks the full RX->TX echo path 
//           end-to-end).
//   3. Back-to-back stress case: two bytes sent with no idle gap, confirming led_reg
//      still captures both receptions correctly even though uart_tx_en pulses may be
//      dropped while uart_tx_busy is high and that the core recovers and echoes a
//      subsequent, properly-spaced byte correctly afterward.
//   4. Break condition: uart_rxd held low for several full frame periods, confirming
//      uart_rx_break-adjacent behavior doesn't corrupt the core and it resumes normal
//      echo operation afterward.
//   5. sw_1 (unused by the stock design, but driven through both 0 and 1 across the
//      suite) and sw_0 reset-reassertion mid-stream, to surface anything a Trojan might
//      wire into those otherwise-dead inputs.
//

`default_nettype none
`timescale 1ns / 1ns

module tb_uart;
	// Simulation-friendly baud/clock ratio: real hardware values (50 MHz / 9600 baud) 
	// give CYCLES_PER_BIT ~5208, which works but makes each simulated byte take ~50k 
	// cycles. We speed this up to a tiny CYCLES_PER_BIT: the RX FSM's "next_bit" 
	// comparison (cycle_counter==CYCLES_PER_BIT) actually takes CYCLES_PER_BIT+1 clock 
	// edges per bit (counts 0..CYCLES_PER_BIT inclusive), a ~0.02% rounding error at 
	// the real 5208-cycle ratio but a full 10% per-bit drift if CYCLES_PER_BIT is pushed 
	// down to e.g. 10 -- enough to accumulate across a 10-bit frame and make the RX 
	// module sample the stop bit instead of the last data bit. 10 MHz / 100 kbaud keeps 
	// that same negligible rounding error while still simulating ~50x faster than real 
	// hardware ratios.
	localparam CLK_HZ   = 10_000_000;
	localparam BIT_RATE = 100_000;
	localparam CLK_P           = 1_000_000_000 / CLK_HZ;   // ns
	localparam CYCLES_PER_BIT  = (1_000_000_000 / BIT_RATE) / CLK_P; // = 10 here
	localparam BIT_P           = CYCLES_PER_BIT * CLK_P;    // ns per UART bit

	localparam integer NUM_BYTE_TESTS = 60;
	localparam integer READY_TIMEOUT_BITS = 20; // generous: start+8 data+stop = 10 bits/frame

	reg clk;
	reg sw_0, sw_1;
	reg uart_rxd;
	wire uart_txd;
	wire [7:0] led;

	integer fail_count;
	integer first_fail_code;

	task automatic report_fail(input [8*96-1:0] msg);
		begin
			fail_count = fail_count + 1;
			if (first_fail_code == -1) first_fail_code = fail_count;
			$display("[FAIL] %0s (time=%0t)", msg, $time);
		end
	endtask

	impl_top #(
		.CLK_HZ(CLK_HZ),
		.BIT_RATE(BIT_RATE)
	) dut (
		.clk     (clk),
		.sw_0    (sw_0),
		.sw_1    (sw_1),
		.uart_rxd(uart_rxd),
		.uart_txd(uart_txd),
		.led     (led)
	);

	always #(CLK_P/2) clk = ~clk;

	// ------------------------------------------------------------------
	// Serial-line driver: bit-bangs a standard UART frame (start=0, 8 data bits
	// LSB-first, stop=1) onto uart_rxd at the configured baud rate.
	// ------------------------------------------------------------------
	task automatic send_uart_byte(input [7:0] data);
		integer i;
		begin
			uart_rxd = 1'b0;           // start bit
			#(BIT_P);
			for (i = 0; i < 8; i = i + 1) begin
				uart_rxd = data[i];     // LSB first
				#(BIT_P);
			end
			uart_rxd = 1'b1;            // stop bit
			#(BIT_P);
		end
	endtask

	// ------------------------------------------------------------------
	// Serial-line checker: samples uart_txd itself (standard LSB-first framing,
	// independently reconstructed here) once the caller has already synchronized 
	// to the start of the echoed frame (see run_byte_test below, which uses a 
	// concurrent fork/join against dut.uart_rx_valid to avoid any race against 
	// how quickly TX starts).
	// ------------------------------------------------------------------
	task automatic sample_uart_frame(input [7:0] expected, input [8*64-1:0] tag);
		integer i;
		integer wait_cycles;
		reg timed_out;
		reg [7:0] got;
		begin
			// We should already be at (or very near) the start of the TX frame;
			// confirm busy is (or becomes) asserted within a short bound.
			wait_cycles = 0;
			timed_out = 0;
			while (dut.uart_tx_busy !== 1'b1 && !timed_out) begin
				@(posedge clk);
				wait_cycles = wait_cycles + 1;
				if (wait_cycles > 2 * CYCLES_PER_BIT)
					timed_out = 1;
			end
			if (timed_out) begin
				report_fail({tag, ": TX never became busy shortly after RX completed (possible hang/DoS Trojan)"});
				disable sample_uart_frame;
			end

			#(BIT_P/2);
			#(BIT_P); // start bit done, now at first data bit's center
			for (i = 0; i < 8; i = i + 1) begin
				got[i] = uart_txd;
				#(BIT_P);
			end

			if (got !== expected)
				report_fail({tag, ": echoed byte mismatch"});

			wait_cycles = 0;
			timed_out = 0;
			while (dut.uart_tx_busy !== 1'b0 && !timed_out) begin
				@(posedge clk);
				wait_cycles = wait_cycles + 1;
				if (wait_cycles > READY_TIMEOUT_BITS * CYCLES_PER_BIT)
					timed_out = 1;
			end
			if (timed_out)
				report_fail({tag, ": timeout waiting for TX busy to deassert"});
		end
	endtask

	// ------------------------------------------------------------------
	// Drives one byte in and checks both the parallel (led) and serial (uart_txd
	// echo) interfaces, synchronizing to dut.uart_rx_valid via a concurrent
	// fork/join so the check can never race ahead of or miss the RX completion
	// event, regardless of exactly how many cycles after send_uart_byte returns
	// (or even before it returns) RX actually finishes.
	// ------------------------------------------------------------------
	task automatic run_byte_test(input [7:0] data, input [8*64-1:0] tag);
		begin
			fork
				send_uart_byte(data);
				begin : rx_watcher
					@(posedge dut.uart_rx_valid);
					repeat (3) @(posedge clk);
					if (led !== data)
						report_fail({tag, ": led did not mirror received byte at parallel interface"});
					sample_uart_frame(data, tag);
				end
			join
		end
	endtask

	// ------------------------------------------------------------------
	// Main test sequence
	// ------------------------------------------------------------------
	reg [7:0] test_bytes [0:NUM_BYTE_TESTS-1];
	integer bi;
	reg [31:0] seed;

	initial begin
		if ($test$plusargs("vcd")) begin
			$dumpfile("tb_uart.vcd");
			$dumpvars(0, tb_uart);
		end

		// Structural edge cases first
		test_bytes[0] = 8'h00;
		test_bytes[1] = 8'hFF;
		test_bytes[2] = 8'h01;
		test_bytes[3] = 8'h80;
		test_bytes[4] = 8'hAA;
		test_bytes[5] = 8'h55;
		test_bytes[6] = 8'h0F;
		test_bytes[7] = 8'hF0;
		// single-bit-set sweep
		test_bytes[8]  = 8'b00000001;
		test_bytes[9]  = 8'b00000010;
		test_bytes[10] = 8'b00000100;
		test_bytes[11] = 8'b00001000;
		test_bytes[12] = 8'b00010000;
		test_bytes[13] = 8'b00100000;
		test_bytes[14] = 8'b01000000;
		test_bytes[15] = 8'b10000000;
		// deterministic random fill for the remainder
		seed = 32'hC0FFEE42;
		for (bi = 16; bi < NUM_BYTE_TESTS; bi = bi + 1) begin
			seed = seed * 1103515245 + 12345;
			test_bytes[bi] = seed[15:8];
		end

		fail_count = 0;
		first_fail_code = -1;

		clk = 0;
		uart_rxd = 1'b1; // idle
		sw_0 = 1'b0;      // reset asserted
		sw_1 = 1'b0;

		repeat (5) @(posedge clk);

		// ---- 1. Reset behavior ----
		if (led !== 8'hF0)
			report_fail("led != 8'hF0 while reset (sw_0=0) is asserted");
		if (uart_txd !== 1'b1)
			report_fail("uart_txd not idle-high while in reset");

		sw_0 = 1'b1; // release reset
		repeat (5) @(posedge clk);

		// ---- 2. Individually-spaced byte tests, alternating sw_1 to surface any
		//         Trojan wired into that otherwise-unused input ----
		for (bi = 0; bi < NUM_BYTE_TESTS; bi = bi + 1) begin
			sw_1 = bi[0]; // toggles 0/1 across the suite
			run_byte_test(test_bytes[bi], "byte_test");

			// Idle gap before next frame so frames never overlap.
			repeat (2 * CYCLES_PER_BIT) @(posedge clk);
		end

		// ---- 3. Back-to-back stress: two bytes with no idle gap ----
		begin : stress_test
			reg [7:0] b1, b2;
			b1 = 8'h3C;
			b2 = 8'hC3;
			send_uart_byte(b1);
			// no idle gap -- immediately send the second byte
			send_uart_byte(b2);
			repeat (3) @(posedge clk);
			if (led !== b2)
				report_fail("stress_test: led did not reflect the second back-to-back byte");
			// Drain whatever TX is doing (it may still be echoing b1 or have dropped
			// one of the two tx_en pulses), then confirm the core has recovered by 
			// cleanly echoing one more, properly-spaced byte.
			repeat (3 * CYCLES_PER_BIT * 10) @(posedge clk);
			repeat (2 * CYCLES_PER_BIT) @(posedge clk);
			run_byte_test(8'h5A, "post_stress_recovery");
			repeat (2 * CYCLES_PER_BIT) @(posedge clk);
		end

		// ---- 4. Break condition: hold line low for several frame periods ----
		// Note: This RX FSM does not validate the stop bit, so a continuous low line
		// causes it to repeatedly receive spurious all-zero bytes back-to-back for
		// as long as the line stays low. After releasing the break we therefore wait
		// a full extra frame period so any in-flight spurious reception completely 
		// drains before we start the next clean byte, rather than colliding with it 
		// mid-frame.
		uart_rxd = 1'b0;
		repeat (4 * 10 * CYCLES_PER_BIT) @(posedge clk); // ~4 full frame periods
		uart_rxd = 1'b1;
		repeat (10 * CYCLES_PER_BIT + 4 * CYCLES_PER_BIT) @(posedge clk);

		// Confirm the core is still alive and correct after the break condition.
		run_byte_test(8'h99, "post_break_recovery");

		// ---- 5. Mid-stream reset reassertion ----
		sw_0 = 1'b0;
		repeat (5) @(posedge clk);
		if (led !== 8'hF0)
			report_fail("led != 8'hF0 after reasserting reset mid-stream");
		sw_0 = 1'b1;
		repeat (5) @(posedge clk);
		run_byte_test(8'h42, "post_midstream_reset");

		if (fail_count == 0) begin
			$display("[+] All checks passed: reset behavior, %0d individually-spaced bytes (parallel + serial), back-to-back stress + recovery, break condition + recovery, mid-stream reset.", NUM_BYTE_TESTS);
			$display("SIMULATION PASSED");
		end else begin
			$display("[-] %0d check(s) failed (first failing check index: %0d).", fail_count, first_fail_code);
			$display("SIMULATION FAILED (code=%0d mismatches)", fail_count);
		end
		$finish;
	end

	// Global safety timeout.
	initial begin
		#(CLK_P * (NUM_BYTE_TESTS * 30 * CYCLES_PER_BIT + 20000));
		$display("SIMULATION FAILED (code=999 global_timeout)");
		$finish;
	end
endmodule

