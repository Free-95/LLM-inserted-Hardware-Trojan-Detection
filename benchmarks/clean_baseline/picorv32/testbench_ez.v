// Self-checking functional testbench for picorv32.
//
// Replaces the original example testbench (which only printed a bus trace and
// relied on a human reading a waveform) with one that:
//   1. Runs a real RV32IM firmware image (assembled with a RISC-V cross
//      compiler, see fw/ directory) exercising ALU reg-reg / reg-imm ops,
//      byte/half/word loads & stores with correct strobe behavior, branches,
//      jumps, LUI/AUIPC, MUL/DIV, and a longer pseudo-random datapath sweep.
//   2. Self-checks every result in C and writes a single pass/fail signature
//      word (plus an error code identifying which check failed) to a fixed
//      memory-mapped address.
//   3. Prints a single, machine-parseable "SIMULATION PASSED"/"SIMULATION
//      FAILED" line plus $finish, so this testbench can be used unattended
//      as the Eval1 gate for both the golden core and Trojan-infected
//      variants, exactly like the HLS co-simulation gate did for the HLS flow.
//
// Memory map (matches fw/link.ld and fw/main.c):
//   0x0000 - 0x06AB   : firmware .text/.sdata (loaded from firmware.hex)
//   0x0800            : SIG_PASS/SIG_FAIL word, written once by start.S
//   0x0804            : error code word (0 on pass, nonzero check ID on fail)
//   0x0900 - 0x09FF   : scratch data used by check_loads_stores /
//                        check_pseudorandom_datapath
//   0x3FC0 - 0x3FFF   : stack (grows down from _stack_top)
//
// Usage as Eval1 gate: compile the infected core against this unmodified
// testbench and firmware.hex. Grep simulator stdout for "SIMULATION PASSED"
// / "SIMULATION FAILED" exactly as run_hls_cosim_check greps for the Vitis
// co-simulation PASS string.

`timescale 1 ns / 1 ps

module testbench;
	localparam integer MEM_WORDS   = 4096;          // 16 KiB byte-addressable memory
	localparam integer TIMEOUT_CYC = 200000;        // safety timeout so a hung/trojaned
	                                                 // core fails loudly instead of hanging CI
	localparam [31:0] SIG_ADDR     = 32'h0000_0800; // pass/fail signature word
	localparam [31:0] ERR_ADDR     = 32'h0000_0804; // error code word
	localparam [31:0] SIG_PASS     = 32'h600D_C0DE;
	localparam [31:0] SIG_FAIL     = 32'hDEAD_FA11;

	reg clk = 1;
	reg resetn = 0;
	wire trap;

	always #5 clk = ~clk;

	// ------------------------------------------------------------------
	// Memory-mapped bus
	// ------------------------------------------------------------------
	wire        mem_valid;
	wire        mem_instr;
	reg         mem_ready;
	wire [31:0] mem_addr;
	wire [31:0] mem_wdata;
	wire [ 3:0] mem_wstrb;
	reg  [31:0] mem_rdata;

	reg [31:0] memory [0:MEM_WORDS-1];

	integer i;
	initial begin
		// Zero-init so uninitialized reads are deterministic between the
		// golden run and any infected variant (avoids X-driven mismatches
		// that would make Eval1 flaky rather than a real functional check).
		for (i = 0; i < MEM_WORDS; i = i + 1)
			memory[i] = 32'h0000_0000;
		$readmemh("firmware.hex", memory);
	end

	always @(posedge clk) begin
		mem_ready <= 0;
		if (mem_valid && !mem_ready) begin
			if (mem_addr < (MEM_WORDS * 4)) begin
				mem_ready <= 1;
				mem_rdata <= memory[mem_addr >> 2];
				if (mem_wstrb[0]) memory[mem_addr >> 2][ 7: 0] <= mem_wdata[ 7: 0];
				if (mem_wstrb[1]) memory[mem_addr >> 2][15: 8] <= mem_wdata[15: 8];
				if (mem_wstrb[2]) memory[mem_addr >> 2][23:16] <= mem_wdata[23:16];
				if (mem_wstrb[3]) memory[mem_addr >> 2][31:24] <= mem_wdata[31:24];
			end else begin
				// Out-of-range access: surface it immediately as a fail rather
				// than silently returning garbage/X, since a Trojan corrupting
				// address generation should be caught right here.
				$display("FATAL: out-of-range memory access to 0x%08x at time %0t", mem_addr, $time);
				$display("SIMULATION FAILED (code=999 out_of_range_access)");
				$finish;
			end
		end
	end

	// Optional bus trace, off by default; enable with +trace on the sim command line.
	always @(posedge clk) begin
		if ($test$plusargs("trace") && mem_valid && mem_ready) begin
			if (mem_instr)
				$display("ifetch 0x%08x: 0x%08x", mem_addr, mem_rdata);
			else if (mem_wstrb)
				$display("write  0x%08x: 0x%08x (wstrb=%b)", mem_addr, mem_wdata, mem_wstrb);
			else
				$display("read   0x%08x: 0x%08x", mem_addr, mem_rdata);
		end
	end

	// ------------------------------------------------------------------
	// DUT
	// ------------------------------------------------------------------
	// ENABLE_MUL/ENABLE_DIV/ENABLE_IRQ turned on (vs. the all-default
	// original testbench) so this single testbench actually exercises the
	// core's optional execution units instead of silently skipping them --
	// a Trojan hiding in the multiply/divide or IRQ logic would otherwise
	// never even be reachable by simulation.
	picorv32 #(
		.ENABLE_COUNTERS     (1),
		.ENABLE_COUNTERS64   (1),
		.ENABLE_REGS_16_31   (1),
		.ENABLE_REGS_DUALPORT(1),
		.LATCHED_MEM_RDATA   (0),
		.TWO_STAGE_SHIFT     (1),
		.BARREL_SHIFTER      (1),
		.TWO_CYCLE_COMPARE   (0),
		.TWO_CYCLE_ALU       (0),
		.COMPRESSED_ISA      (0),
		.CATCH_MISALIGN      (1),
		.CATCH_ILLINSN       (1),
		.ENABLE_PCPI         (0),
		.ENABLE_MUL          (1),
		.ENABLE_FAST_MUL     (0),
		.ENABLE_DIV          (1),
		.ENABLE_IRQ          (0),
		.ENABLE_IRQ_QREGS    (1),
		.ENABLE_IRQ_TIMER    (1),
		.ENABLE_TRACE        (0),
		.REGS_INIT_ZERO      (0),
		.MASKED_IRQ          (32'h0000_0000),
		.LATCHED_IRQ         (32'hffff_ffff),
		.PROGADDR_RESET      (32'h0000_0000),
		.PROGADDR_IRQ        (32'h0000_0010),
		.STACKADDR           (32'hffff_ffff)
	) uut (
		.clk         (clk        ),
		.resetn      (resetn     ),
		.trap        (trap       ),
		.mem_valid   (mem_valid  ),
		.mem_instr   (mem_instr  ),
		.mem_ready   (mem_ready  ),
		.mem_addr    (mem_addr   ),
		.mem_wdata   (mem_wdata  ),
		.mem_wstrb   (mem_wstrb  ),
		.mem_rdata   (mem_rdata  )
		// irq, pcpi_*, rvfi_* left unconnected: ENABLE_IRQ=0 / ENABLE_PCPI=0
		// above, and RISCV_FORMAL is not defined, so these ports do not
		// affect functional behavior being checked here.
	);

	// ------------------------------------------------------------------
	// Control: reset, signature polling, timeout, PASS/FAIL verdict
	// ------------------------------------------------------------------
	integer cycle_count;

	initial begin
		if ($test$plusargs("vcd")) begin
			$dumpfile("testbench.vcd");
			$dumpvars(0, testbench);
		end
		cycle_count = 0;
		repeat (10) @(posedge clk);
		resetn <= 1;
	end

	always @(posedge clk) begin
		cycle_count = cycle_count + 1;

		if (resetn && memory[SIG_ADDR >> 2] == SIG_PASS) begin
			$display("SIMULATION PASSED");
			$finish;
		end
		if (resetn && memory[SIG_ADDR >> 2] == SIG_FAIL) begin
			$display("Firmware self-check failed, error code = %0d", memory[ERR_ADDR >> 2]);
			$display("SIMULATION FAILED (code=%0d)", memory[ERR_ADDR >> 2]);
			$finish;
		end
		if (trap) begin
			// Any unrequested trap (illegal instruction, misaligned access, etc.)
			// before the firmware wrote its own signature is itself a failure --
			// the golden firmware never intentionally traps.
			$display("Unexpected core trap asserted at time %0t before firmware signature was written", $time);
			$display("SIMULATION FAILED (code=998 unexpected_trap)");
			$finish;
		end
		if (cycle_count > TIMEOUT_CYC) begin
			$display("Timeout after %0d cycles without a pass/fail signature (possible hang / DoS Trojan)", TIMEOUT_CYC);
			$display("SIMULATION FAILED (code=997 timeout)");
			$finish;
		end
	end
endmodule
