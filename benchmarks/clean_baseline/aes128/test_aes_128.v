// Self-checking functional testbench for aes_128 (Homer Hsing AES-128 core).
//
//   - Streams 182 (state, key, expected_ciphertext) vectors from vectors.hex, one new
//     vector per clock (the core is fully pipelined / accepts new input every cycle).
//   - Vectors were generated independently in Python using the `cryptography` library's
//     AES-128-ECB implementation (not derived from this RTL), so this is a true golden
//     reference, not circular verification. Includes the original FIPS-197 / NIST KAT
//     vectors, structural edge cases (all-zero, all-one, alternating-bit keys/states),
//     12 single-bit-flip vectors each for plaintext and key (avalanche/trigger coverage),
//     and 150 deterministically-seeded random vectors.
//   - Tracks expected outputs in a FIFO queue keyed off a measured pipeline latency
//     (confirmed against the first vector at simulation start, not hardcoded blindly),
//     so the testbench self-adapts to a one-or-two-stage pipeline depth change instead of
//     silently mis-comparing against the wrong cycle.
//   - Reports every individual mismatch with its vector index, plus a final
//     "SIMULATION PASSED" / "SIMULATION FAILED (N/M vectors failed)" line for automated
//     grep-based Eval1 gating, matching the convention used for the picorv32 testbench.

`timescale 1ns / 1ps

module test_aes_128;
	localparam integer NUM_VECTORS   = 182;
	localparam integer MAX_LATENCY   = 64;   // generous upper bound while auto-detecting latency
	localparam integer CLK_PERIOD    = 10;

	reg clk;
	reg [127:0] state, key;
	wire [127:0] out;

	aes_128 uut (
		.clk  (clk),
		.state(state),
		.key  (key),
		.out  (out)
	);

	always #(CLK_PERIOD/2) clk = ~clk;

	// ------------------------------------------------------------------
	// Golden vectors, loaded as a flat array: vec[3*i]=state, vec[3*i+1]=key,
	// vec[3*i+2]=expected_ciphertext, for i in [0, NUM_VECTORS).
	// ------------------------------------------------------------------
	reg [127:0] vec [0:3*NUM_VECTORS-1];
	initial $readmemh("vectors.hex", vec);

	// ------------------------------------------------------------------
	// Pipeline-latency auto-detection: apply vector 0, then watch for `out`
	// to equal its known expected ciphertext. This avoids hardcoding a
	// cycle count that a (possibly Trojan-infected) variant with an extra
	// or missing pipeline register would silently break.
	// ------------------------------------------------------------------
	integer latency;
	integer detect_cycles;
	reg detected;

	task automatic detect_latency;
		begin
			state = vec[0];
			key   = vec[1];
			detected = 0;
			detect_cycles = 0;
			@(negedge clk); // let state/key settle before the first sampling edge
			while (!detected && detect_cycles < MAX_LATENCY) begin
				@(posedge clk);
				#1; // allow out to settle after the clock edge
				detect_cycles = detect_cycles + 1;
				if (out === vec[2]) begin
					detected = 1;
					latency = detect_cycles;
				end
			end
			if (!detected) begin
				$display("FATAL: could not detect pipeline latency within %0d cycles.", MAX_LATENCY);
				$display("       out=0x%032x never matched expected=0x%032x for vector 0.", out, vec[2]);
				$display("SIMULATION FAILED (code=1 latency_detect_failed)");
				$finish;
			end
			$display("[*] Detected pipeline latency: %0d cycles", latency);
		end
	endtask

	// ------------------------------------------------------------------
	// Expected-output FIFO: index of the vector whose result is expected
	// `latency` cycles after it was applied.
	// ------------------------------------------------------------------
	integer apply_idx;   // next vector index to drive on state/key
	integer check_idx;   // next vector index whose output we expect to see
	integer fail_count;
	integer first_fail_idx;

	initial begin
		if ($test$plusargs("vcd")) begin
			$dumpfile("test_aes_128.vcd");
			$dumpvars(0, test_aes_128);
		end

		clk = 0;
		state = 0;
		key = 0;
		fail_count = 0;
		first_fail_idx = -1;

		#(CLK_PERIOD * 2);

		detect_latency();

		// Re-drive vector 0 cleanly (detect_latency already consumed some cycles mid-stream)
		// then stream every vector back-to-back, one per clock, matching the core's full
		// pipelined throughput.
		apply_idx = 0;
		check_idx = 0;

		@(negedge clk);
		fork
			// Driver: apply one vector per cycle.
			begin : driver
				for (apply_idx = 0; apply_idx < NUM_VECTORS; apply_idx = apply_idx + 1) begin
					state = vec[3*apply_idx];
					key   = vec[3*apply_idx + 1];
					@(negedge clk);
				end
			end
			// Checker: starting `latency` cycles after the driver begins, compare `out`
			// against the expected ciphertext for the corresponding vector every cycle.
			begin : checker
				repeat (latency) @(negedge clk);
				for (check_idx = 0; check_idx < NUM_VECTORS; check_idx = check_idx + 1) begin
					if (out !== vec[3*check_idx + 2]) begin
						fail_count = fail_count + 1;
						if (first_fail_idx == -1) first_fail_idx = check_idx;
						$display("[FAIL] vector %0d: state=0x%032x key=0x%032x expected=0x%032x got=0x%032x",
							check_idx, vec[3*check_idx], vec[3*check_idx+1], vec[3*check_idx+2], out);
					end
					@(negedge clk);
				end
			end
		join

		if (fail_count == 0) begin
			$display("[+] All %0d vectors matched the independent software AES-128 reference.", NUM_VECTORS);
			$display("SIMULATION PASSED");
		end else begin
			$display("[-] %0d of %0d vectors mismatched (first failure: vector %0d).", fail_count, NUM_VECTORS, first_fail_idx);
			$display("SIMULATION FAILED (code=%0d mismatches, first_fail_vector=%0d)", fail_count, first_fail_idx);
		end
		$finish;
	end

	// Safety timeout in case the checker/driver fork never completes (e.g. a Trojan that
	// stalls `out` indefinitely).
	initial begin
		#(CLK_PERIOD * (MAX_LATENCY + NUM_VECTORS + 50));
		$display("SIMULATION FAILED (code=2 timeout_before_completion)");
		$finish;
	end
endmodule
