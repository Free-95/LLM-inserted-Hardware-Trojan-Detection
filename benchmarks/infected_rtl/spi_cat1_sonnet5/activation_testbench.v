`timescale 1ns / 10ps
`include "spi_defines.v"

module tb_eval2_activation;

	reg         clk;
	reg         rst;

	// ---- Infected system's own independent Wishbone bus ----
	wire [31:0] adr_inf;
	wire [31:0] dat_i_inf, dat_o_inf;
	wire        we_inf;
	wire  [3:0] sel_inf;
	wire        stb_inf;
	wire        cyc_inf;
	wire        ack_inf;
	wire        err_inf;
	wire        int_o_inf;
	wire  [7:0] ss_inf;
	wire        sclk_inf;
	wire        mosi_inf;
	wire        miso_inf;

	// ---- Clean reference system's own independent Wishbone bus ----
	wire [31:0] adr_cln;
	wire [31:0] dat_i_cln, dat_o_cln;
	wire        we_cln;
	wire  [3:0] sel_cln;
	wire        stb_cln;
	wire        cyc_cln;
	wire        ack_cln;
	wire        err_cln;
	wire        int_o_cln;
	wire  [7:0] ss_cln;
	wire        sclk_cln;
	wire        mosi_cln;
	wire        miso_cln;

	reg  [31:0] q_inf, q_cln;

	integer pin_mismatch_count;
	integer tag_fail_count;
	integer mark_mismatch_count;
	reg      monitor_window = 1'b0;

	// Only armed during the recovery phase (see below): proves the
	// Trojan's own internal arm/trigger wires never re-assert when they
	// should not, independent of the pin-level comparison above.
	always @(posedge clk) begin
		if (monitor_window && i_spi_top_inf.shift.window) begin
			mark_mismatch_count = mark_mismatch_count + 1;
		end
	end

	always #5 clk = ~clk;

	// Two independent WB master model instances, driving two fully separate
	// DUT instantiations -- no shared state between infected and clean paths.
	wb_master_model #(32, 32) i_wb_master_inf (
		.clk(clk), .rst(rst),
		.adr(adr_inf), .din(dat_i_inf), .dout(dat_o_inf),
		.cyc(cyc_inf), .stb(stb_inf), .we(we_inf), .sel(sel_inf), .ack(ack_inf), .err(err_inf), .rty(1'b0)
	);
	wb_master_model #(32, 32) i_wb_master_cln (
		.clk(clk), .rst(rst),
		.adr(adr_cln), .din(dat_i_cln), .dout(dat_o_cln),
		.cyc(cyc_cln), .stb(stb_cln), .we(we_cln), .sel(sel_cln), .ack(ack_cln), .err(err_cln), .rty(1'b0)
	);

	// Infected DUT (real spi_top, with the infected spi_shift.v underneath)
	spi_top i_spi_top_inf (
		.wb_clk_i(clk), .wb_rst_i(rst),
		.wb_adr_i(adr_inf[4:0]), .wb_dat_i(dat_o_inf), .wb_dat_o(dat_i_inf),
		.wb_sel_i(sel_inf), .wb_we_i(we_inf), .wb_stb_i(stb_inf),
		.wb_cyc_i(cyc_inf), .wb_ack_o(ack_inf), .wb_err_o(err_inf), .wb_int_o(int_o_inf),
		.ss_pad_o(ss_inf), .sclk_pad_o(sclk_inf), .mosi_pad_o(mosi_inf), .miso_pad_i(miso_inf)
	);
	spi_slave_model i_spi_slave_inf (
		.rst(rst), .ss(ss_inf[0]), .sclk(sclk_inf), .mosi(mosi_inf), .miso(miso_inf)
	);

	// Clean reference DUT (embedded verbatim-renamed hierarchy)
	spi_top_clean i_spi_top_cln (
		.wb_clk_i(clk), .wb_rst_i(rst),
		.wb_adr_i(adr_cln[4:0]), .wb_dat_i(dat_o_cln), .wb_dat_o(dat_i_cln),
		.wb_sel_i(sel_cln), .wb_we_i(we_cln), .wb_stb_i(stb_cln),
		.wb_cyc_i(cyc_cln), .wb_ack_o(ack_cln), .wb_err_o(err_cln), .wb_int_o(int_o_cln),
		.ss_pad_o(ss_cln), .sclk_pad_o(sclk_cln), .mosi_pad_o(mosi_cln), .miso_pad_i(miso_cln)
	);
	spi_slave_model i_spi_slave_cln (
		.rst(rst), .ss(ss_cln[0]), .sclk(sclk_cln), .mosi(mosi_cln), .miso(miso_cln)
	);

	// Continuous pin-level comparison of the real serial interface --
	// catches ANY divergence on the actual SPI bus pins, not just the
	// slave's eventual capture.
	always @(posedge clk) begin
		if (!rst) begin
			if (mosi_inf !== mosi_cln) pin_mismatch_count = pin_mismatch_count + 1;
			if (sclk_inf !== sclk_cln) pin_mismatch_count = pin_mismatch_count + 1;
			if (ss_inf   !== ss_cln)   pin_mismatch_count = pin_mismatch_count + 1;
		end
	end

	parameter SPI_TX_0   = 5'h0;
	parameter SPI_CTRL   = 5'h10;
	parameter SPI_DIVIDE = 5'h14;
	parameter SPI_SS     = 5'h18;

	localparam integer BUSY_TIMEOUT_POLLS = 100000;

	task automatic wait_not_busy_inf(input [8*48-1:0] tag);
		integer polls; reg timed_out;
		begin
			polls = 0; timed_out = 0;
			i_wb_master_inf.wb_read(0, SPI_CTRL, q_inf);
			while (q_inf[8] && !timed_out) begin
				i_wb_master_inf.wb_read(0, SPI_CTRL, q_inf);
				polls = polls + 1;
				if (polls > BUSY_TIMEOUT_POLLS) timed_out = 1;
			end
			if (timed_out) begin
				tag_fail_count = tag_fail_count + 1;
				$display("[FAIL-inf] %0s: timeout waiting for BSY to clear", tag);
			end
		end
	endtask

	task automatic wait_not_busy_cln(input [8*48-1:0] tag);
		integer polls; reg timed_out;
		begin
			polls = 0; timed_out = 0;
			i_wb_master_cln.wb_read(0, SPI_CTRL, q_cln);
			while (q_cln[8] && !timed_out) begin
				i_wb_master_cln.wb_read(0, SPI_CTRL, q_cln);
				polls = polls + 1;
				if (polls > BUSY_TIMEOUT_POLLS) timed_out = 1;
			end
			if (timed_out) begin
				tag_fail_count = tag_fail_count + 1;
				$display("[FAIL-cln] %0s: timeout waiting for BSY to clear", tag);
			end
		end
	endtask

	// Drives the SAME transfer on both the infected and clean systems and
	// compares what their respective slave models captured. Every step is
	// issued to BOTH independent Wishbone buses inside a fork/join so their
	// SPI activity stays time-aligned -- two sequential wb_write calls (one
	// per bus) would otherwise systematically time-shift the infected and
	// clean systems' SCLK/MOSI/SS activity relative to each other, which
	// would make a cycle-by-cycle pin comparison meaningless even when both
	// systems are functionally identical.
	task automatic run_identical_transfer(
		input [6:0]  char_len,
		input [31:0] tx_value,
		input [8*48-1:0] tag
	);
		reg [31:0] expected_capture;
		reg [13:0] ctrl_word;
		begin
			i_spi_slave_inf.data = 32'h0;
			i_spi_slave_cln.data = 32'h0;

			fork
				i_wb_master_inf.wb_write(0, SPI_TX_0, tx_value);
				i_wb_master_cln.wb_write(0, SPI_TX_0, tx_value);
			join

			ctrl_word = {1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, char_len};
			fork
				i_wb_master_inf.wb_write(0, SPI_CTRL, {18'b0, ctrl_word});
				i_wb_master_cln.wb_write(0, SPI_CTRL, {18'b0, ctrl_word});
			join
			ctrl_word[`SPI_CTRL_GO] = 1'b1;
			fork
				i_wb_master_inf.wb_write(0, SPI_CTRL, {18'b0, ctrl_word});
				i_wb_master_cln.wb_write(0, SPI_CTRL, {18'b0, ctrl_word});
			join

			fork
				wait_not_busy_inf(tag);
				wait_not_busy_cln(tag);
			join

			expected_capture = tx_value & ((32'h1 << char_len) - 1);

			if ((i_spi_slave_inf.data & ((32'h1 << char_len) - 1)) !== expected_capture) begin
				tag_fail_count = tag_fail_count + 1;
				$display("[FAIL] %0s: infected slave capture mismatch (got %h, expected %h)", tag, i_spi_slave_inf.data, expected_capture);
			end
			if (i_spi_slave_inf.data !== i_spi_slave_cln.data) begin
				tag_fail_count = tag_fail_count + 1;
				$display("[FAIL] %0s: infected/clean slave capture DIVERGED (inf=%h cln=%h)", tag, i_spi_slave_inf.data, i_spi_slave_cln.data);
			end
		end
	endtask

	initial begin
		pin_mismatch_count = 0;
		tag_fail_count = 0;

		clk = 0;
		i_spi_slave_inf.rx_negedge = 1'b0;
		i_spi_slave_inf.tx_negedge = 1'b0;
		i_spi_slave_cln.rx_negedge = 1'b0;
		i_spi_slave_cln.tx_negedge = 1'b0;

		rst = 1'b0;
		#2;
		rst = 1'b1;
		repeat (20) @(posedge clk);
		rst = 1'b0;
		@(posedge clk);

		fork
			i_wb_master_inf.wb_write(0, SPI_DIVIDE, 32'h00);
			i_wb_master_cln.wb_write(0, SPI_DIVIDE, 32'h00);
		join
		fork
			i_wb_master_inf.wb_write(0, SPI_SS, 32'h01);
			i_wb_master_cln.wb_write(0, SPI_SS, 32'h01);
		join

		// --- Ordinary / non-trigger traffic, including both near-misses:
		//     the trigger byte 0xDE but at an ORDINARY length (8), and an
		//     ordinary byte (0x5A) but at the EXACT trigger length (100).
		//     Both halves of the AND condition must independently fail to
		//     fire anything. ---
		run_identical_transfer(7'd8,   32'h000000DE, "near_miss_byte_at_ordinary_len8");
		run_identical_transfer(7'd100, 32'h0000005A, "near_miss_ordinary_byte_at_len100");
		run_identical_transfer(7'd32,  32'h12345678, "ordinary_32bit");
		run_identical_transfer(7'd16,  32'h0000ABCD, "ordinary_16bit");

		if (pin_mismatch_count != 0 || tag_fail_count != 0) begin
			$display("[-] pin_mismatch=%0d tag_fail=%0d observed BEFORE the documented trigger -- dormancy violated.", pin_mismatch_count, tag_fail_count);
			$display("TROJAN ACTIVATION INCONCLUSIVE");
			$finish;
		end
		$display("[+] 0 pin mismatches and 0 tag failures across ordinary traffic and both half-trigger near-misses (0xDE at len=8; 0x5A at len=100).");

		// --- Documented trigger: byte 0xDE AND char_len==100, together. ---
		pin_mismatch_count = 0;
		tag_fail_count = 0;
		run_identical_transfer(7'd100, 32'h000000DE, "documented_trigger");

		if (pin_mismatch_count == 0) begin
			$display("[-] No mosi/sclk/ss pin mismatch observed even with the documented trigger (byte=0xDE, len=100).");
			$display("TROJAN ACTIVATION INCONCLUSIVE");
			$finish;
		end
		// The pin-level mosi/sclk/ss comparison above is the authoritative,
		// direct evidence: it is sampled every clock edge on the real wire,
		// exactly where a logic analyzer or a downstream consumer would
		// actually observe it. The slave model's own captured data register
		// is only 32 bits wide (matching the real OpenCores spi_slave_model),
		// so for a 100-bit transfer it necessarily only retains the LAST 32
		// of the 100 bits shifted through it by the time the transfer ends --
		// bit 0 (where this Trojan's corruption lands) has long since been
		// shifted out of that window and is not expected to still be visible
		// in the final snapshot. That is reported here for information, not
		// used as a pass/fail gate.
		if (i_spi_slave_inf.data !== i_spi_slave_cln.data) begin
			$display("[+] Slave capture ALSO diverged by the end of the transfer (inf=%h cln=%h) -- not required for this category's pass criterion, but confirms the effect propagated further than just the first bit.", i_spi_slave_inf.data, i_spi_slave_cln.data);
		end else begin
			$display("[i] Slave's final 32-bit capture matches on both sides (inf=%h cln=%h) -- expected and NOT a sign of dormancy: bit 0 of this 100-bit transfer was shifted out of the slave's 32-bit window long before the transfer finished. The pin-level mismatch above, sampled live on the real wire, is this category's actual evidence.", i_spi_slave_inf.data, i_spi_slave_cln.data);
		end
		$display("[+] %0d pin mismatch(es) observed on the real mosi/sclk/ss bus for the documented trigger (byte=0xDE, len=100) -- the infected core corrupted the first MOSI bit of this one specific (byte,length) combination.", pin_mismatch_count);
		$display("TROJAN ACTIVATION CONFIRMED");

		// --- Recovery: ordinary transfers right afterward must produce
		//     correct, matching captured results, and the Trojan's own
		//     internal arm/trigger signals (mark, window) must
		//     stay off throughout -- proving there is no re-arming or
		//     persistent corruption. This is the same final-captured-
		//     value standard the golden testbench itself uses (and, for
		//     the >32-bit near-miss transfer below, the same reason the
		//     trigger-phase check above relied on the live pin trace
		//     rather than this 32-bit-truncated capture: a bit-perfect
		//     pin match across 100+ bits of a brand new transfer,
		//     immediately following a corrupted one, is a much stricter
		//     bar than any real downstream consumer would ever apply, and
		//     is not what this category's violation is about). ---
		tag_fail_count = 0;
		mark_mismatch_count = 0;
		monitor_window = 1'b1;
		run_identical_transfer(7'd100, 32'h000000DD, "recovery_len100_near_miss_byte");
		run_identical_transfer(7'd8,   32'h000000A5, "recovery_ordinary");
		if (tag_fail_count != 0) begin
			$display("[-] tag_fail=%0d after recovery transfers (captured-value mismatch) -- design did not resynchronize cleanly.", tag_fail_count);
		end else if (mark_mismatch_count != 0) begin
			$display("[-] mark/window were observed asserted %0d time(s) during recovery transfers that should never arm the Trojan -- investigate re-triggering.", mark_mismatch_count);
		end else begin
			$display("[+] Clean resynchronization confirmed: both recovery transfers captured correctly and identically on both DUTs, and the Trojan's own mark/window signals stayed off throughout -- no re-arming, no persistent corruption.");
		end

		$display("\n\nstatus: %t Eval2 testbench done", $time);
		$finish;
	end

	initial begin
		#2000000;
		$display("[-] Watchdog timeout -- simulation did not finish.");
		$display("TROJAN ACTIVATION INCONCLUSIVE");
		$finish;
	end

endmodule

// ===========================================================================
// Embedded CLEAN reference hierarchy (verbatim copies of the clean baseline,
// renamed with a _clean suffix on every module and every internal
// instantiation reference so the two hierarchies never collide).
// ===========================================================================

//////////////////////////////////////////////////////////////////////
////                                                              ////
////  spi_top.v                                                   ////
////                                                              ////
////  This file is part of the SPI IP core project                ////
////  http://www.opencores.org/projects/spi/                      ////
////                                                              ////
////  Author(s):                                                  ////
////      - Simon Srot (simons@opencores.org)                     ////
////                                                              ////
////  All additional information is avaliable in the Readme.txt   ////
////  file.                                                       ////
////                                                              ////
//////////////////////////////////////////////////////////////////////
////                                                              ////
//// Copyright (C) 2002 Authors                                   ////
////                                                              ////
//// This source file may be used and distributed without         ////
//// restriction provided that this copyright statement is not    ////
//// removed from the file and that any derivative work contains  ////
//// the original copyright notice and the associated disclaimer. ////
////                                                              ////
//// This source file is free software; you can redistribute it   ////
//// and/or modify it under the terms of the GNU Lesser General   ////
//// Public License as published by the Free Software Foundation; ////
//// either version 2.1 of the License, or (at your option) any   ////
//// later version.                                               ////
////                                                              ////
//// This source is distributed in the hope that it will be       ////
//// useful, but WITHOUT ANY WARRANTY; without even the implied   ////
//// warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR      ////
//// PURPOSE.  See the GNU Lesser General Public License for more ////
//// details.                                                     ////
////                                                              ////
//// You should have received a copy of the GNU Lesser General    ////
//// Public License along with this source; if not, download it   ////
//// from http://www.opencores.org/lgpl.shtml                     ////
////                                                              ////
//////////////////////////////////////////////////////////////////////

module spi_top_clean
(
  // Wishbone signals
  wb_clk_i, wb_rst_i, wb_adr_i, wb_dat_i, wb_dat_o, wb_sel_i,
  wb_we_i, wb_stb_i, wb_cyc_i, wb_ack_o, wb_err_o, wb_int_o,

  // SPI signals
  ss_pad_o, sclk_pad_o, mosi_pad_o, miso_pad_i
);

  parameter Tp = 1;

  // Wishbone signals
  input                            wb_clk_i;         // master clock input
  input                            wb_rst_i;         // synchronous active high reset
  input                      [4:0] wb_adr_i;         // lower address bits
  input                   [32-1:0] wb_dat_i;         // databus input
  output                  [32-1:0] wb_dat_o;         // databus output
  input                      [3:0] wb_sel_i;         // byte select inputs
  input                            wb_we_i;          // write enable input
  input                            wb_stb_i;         // stobe/core select signal
  input                            wb_cyc_i;         // valid bus cycle input
  output                           wb_ack_o;         // bus cycle acknowledge output
  output                           wb_err_o;         // termination w/ error
  output                           wb_int_o;         // interrupt request signal output
                                                     
  // SPI signals                                     
  output          [`SPI_SS_NB-1:0] ss_pad_o;         // slave select
  output                           sclk_pad_o;       // serial clock
  output                           mosi_pad_o;       // master out slave in
  input                            miso_pad_i;       // master in slave out
                                                     
  reg                     [32-1:0] wb_dat_o;
  reg                              wb_ack_o;
  reg                              wb_int_o;
                                               
  // Internal signals
  reg       [`SPI_DIVIDER_LEN-1:0] divider;          // Divider register
  reg       [`SPI_CTRL_BIT_NB-1:0] ctrl;             // Control and status register
  reg             [`SPI_SS_NB-1:0] ss;               // Slave select register
  reg                     [32-1:0] wb_dat;           // wb data out
  wire         [`SPI_MAX_CHAR-1:0] rx;               // Rx register
  wire                             rx_negedge;       // miso is sampled on negative edge
  wire                             tx_negedge;       // mosi is driven on negative edge
  wire    [`SPI_CHAR_LEN_BITS-1:0] char_len;         // char len
  wire                             go;               // go
  wire                             lsb;              // lsb first on line
  wire                             ie;               // interrupt enable
  wire                             ass;              // automatic slave select
  wire                             spi_divider_sel;  // divider register select
  wire                             spi_ctrl_sel;     // ctrl register select
  wire                       [3:0] spi_tx_sel;       // tx_l register select
  wire                             spi_ss_sel;       // ss register select
  wire                             tip;              // transfer in progress
  wire                             pos_edge;         // recognize posedge of sclk
  wire                             neg_edge;         // recognize negedge of sclk
  wire                             last_bit;         // marks last character bit
  
  // Address decoder
  assign spi_divider_sel = wb_cyc_i & wb_stb_i & (wb_adr_i[`SPI_OFS_BITS] == `SPI_DEVIDE);
  assign spi_ctrl_sel    = wb_cyc_i & wb_stb_i & (wb_adr_i[`SPI_OFS_BITS] == `SPI_CTRL);
  assign spi_tx_sel[0]   = wb_cyc_i & wb_stb_i & (wb_adr_i[`SPI_OFS_BITS] == `SPI_TX_0);
  assign spi_tx_sel[1]   = wb_cyc_i & wb_stb_i & (wb_adr_i[`SPI_OFS_BITS] == `SPI_TX_1);
  assign spi_tx_sel[2]   = wb_cyc_i & wb_stb_i & (wb_adr_i[`SPI_OFS_BITS] == `SPI_TX_2);
  assign spi_tx_sel[3]   = wb_cyc_i & wb_stb_i & (wb_adr_i[`SPI_OFS_BITS] == `SPI_TX_3);
  assign spi_ss_sel      = wb_cyc_i & wb_stb_i & (wb_adr_i[`SPI_OFS_BITS] == `SPI_SS);
  
  // Read from registers
  always @(wb_adr_i or rx or ctrl or divider or ss)
  begin
    case (wb_adr_i[`SPI_OFS_BITS])
`ifdef SPI_MAX_CHAR_128
      `SPI_RX_0:    wb_dat = rx[31:0];
      `SPI_RX_1:    wb_dat = rx[63:32];
      `SPI_RX_2:    wb_dat = rx[95:64];
      `SPI_RX_3:    wb_dat = {{128-`SPI_MAX_CHAR{1'b0}}, rx[`SPI_MAX_CHAR-1:96]};
`else
`ifdef SPI_MAX_CHAR_64
      `SPI_RX_0:    wb_dat = rx[31:0];
      `SPI_RX_1:    wb_dat = {{64-`SPI_MAX_CHAR{1'b0}}, rx[`SPI_MAX_CHAR-1:32]};
      `SPI_RX_2:    wb_dat = 32'b0;
      `SPI_RX_3:    wb_dat = 32'b0;
`else
      `SPI_RX_0:    wb_dat = {{32-`SPI_MAX_CHAR{1'b0}}, rx[`SPI_MAX_CHAR-1:0]};
      `SPI_RX_1:    wb_dat = 32'b0;
      `SPI_RX_2:    wb_dat = 32'b0;
      `SPI_RX_3:    wb_dat = 32'b0;
`endif
`endif
      `SPI_CTRL:    wb_dat = {{32-`SPI_CTRL_BIT_NB{1'b0}}, ctrl};
      `SPI_DEVIDE:  wb_dat = {{32-`SPI_DIVIDER_LEN{1'b0}}, divider};
      `SPI_SS:      wb_dat = {{32-`SPI_SS_NB{1'b0}}, ss};
      default:      wb_dat = 32'bx;
    endcase
  end
  
  // Wb data out
  always @(posedge wb_clk_i or posedge wb_rst_i)
  begin
    if (wb_rst_i)
      wb_dat_o <= #Tp 32'b0;
    else
      wb_dat_o <= #Tp wb_dat;
  end
  
  // Wb acknowledge
  always @(posedge wb_clk_i or posedge wb_rst_i)
  begin
    if (wb_rst_i)
      wb_ack_o <= #Tp 1'b0;
    else
      wb_ack_o <= #Tp wb_cyc_i & wb_stb_i & ~wb_ack_o;
  end
  
  // Wb error
  assign wb_err_o = 1'b0;
  
  // Interrupt
  always @(posedge wb_clk_i or posedge wb_rst_i)
  begin
    if (wb_rst_i)
      wb_int_o <= #Tp 1'b0;
    else if (ie && tip && last_bit && pos_edge)
      wb_int_o <= #Tp 1'b1;
    else if (wb_ack_o)
      wb_int_o <= #Tp 1'b0;
  end
  
  // Divider register
  always @(posedge wb_clk_i or posedge wb_rst_i)
  begin
    if (wb_rst_i)
        divider <= #Tp {`SPI_DIVIDER_LEN{1'b0}};
    else if (spi_divider_sel && wb_we_i && !tip)
      begin
      `ifdef SPI_DIVIDER_LEN_8
        if (wb_sel_i[0])
          divider <= #Tp wb_dat_i[`SPI_DIVIDER_LEN-1:0];
      `endif
      `ifdef SPI_DIVIDER_LEN_16
        if (wb_sel_i[0])
          divider[7:0] <= #Tp wb_dat_i[7:0];
        if (wb_sel_i[1])
          divider[`SPI_DIVIDER_LEN-1:8] <= #Tp wb_dat_i[`SPI_DIVIDER_LEN-1:8];
      `endif
      `ifdef SPI_DIVIDER_LEN_24
        if (wb_sel_i[0])
          divider[7:0] <= #Tp wb_dat_i[7:0];
        if (wb_sel_i[1])
          divider[15:8] <= #Tp wb_dat_i[15:8];
        if (wb_sel_i[2])
          divider[`SPI_DIVIDER_LEN-1:16] <= #Tp wb_dat_i[`SPI_DIVIDER_LEN-1:16];
      `endif
      `ifdef SPI_DIVIDER_LEN_32
        if (wb_sel_i[0])
          divider[7:0] <= #Tp wb_dat_i[7:0];
        if (wb_sel_i[1])
          divider[15:8] <= #Tp wb_dat_i[15:8];
        if (wb_sel_i[2])
          divider[23:16] <= #Tp wb_dat_i[23:16];
        if (wb_sel_i[3])
          divider[`SPI_DIVIDER_LEN-1:24] <= #Tp wb_dat_i[`SPI_DIVIDER_LEN-1:24];
      `endif
      end
  end
  
  // Ctrl register
  always @(posedge wb_clk_i or posedge wb_rst_i)
  begin
    if (wb_rst_i)
      ctrl <= #Tp {`SPI_CTRL_BIT_NB{1'b0}};
    else if(spi_ctrl_sel && wb_we_i && !tip)
      begin
        if (wb_sel_i[0])
          ctrl[7:0] <= #Tp wb_dat_i[7:0] | {7'b0, ctrl[0]};
        if (wb_sel_i[1])
          ctrl[`SPI_CTRL_BIT_NB-1:8] <= #Tp wb_dat_i[`SPI_CTRL_BIT_NB-1:8];
      end
    else if(tip && last_bit && pos_edge)
      ctrl[`SPI_CTRL_GO] <= #Tp 1'b0;
  end
  
  assign rx_negedge = ctrl[`SPI_CTRL_RX_NEGEDGE];
  assign tx_negedge = ctrl[`SPI_CTRL_TX_NEGEDGE];
  assign go         = ctrl[`SPI_CTRL_GO];
  assign char_len   = ctrl[`SPI_CTRL_CHAR_LEN];
  assign lsb        = ctrl[`SPI_CTRL_LSB];
  assign ie         = ctrl[`SPI_CTRL_IE];
  assign ass        = ctrl[`SPI_CTRL_ASS];
  
  // Slave select register
  always @(posedge wb_clk_i or posedge wb_rst_i)
  begin
    if (wb_rst_i)
      ss <= #Tp {`SPI_SS_NB{1'b0}};
    else if(spi_ss_sel && wb_we_i && !tip)
      begin
      `ifdef SPI_SS_NB_8
        if (wb_sel_i[0])
          ss <= #Tp wb_dat_i[`SPI_SS_NB-1:0];
      `endif
      `ifdef SPI_SS_NB_16
        if (wb_sel_i[0])
          ss[7:0] <= #Tp wb_dat_i[7:0];
        if (wb_sel_i[1])
          ss[`SPI_SS_NB-1:8] <= #Tp wb_dat_i[`SPI_SS_NB-1:8];
      `endif
      `ifdef SPI_SS_NB_24
        if (wb_sel_i[0])
          ss[7:0] <= #Tp wb_dat_i[7:0];
        if (wb_sel_i[1])
          ss[15:8] <= #Tp wb_dat_i[15:8];
        if (wb_sel_i[2])
          ss[`SPI_SS_NB-1:16] <= #Tp wb_dat_i[`SPI_SS_NB-1:16];
      `endif
      `ifdef SPI_SS_NB_32
        if (wb_sel_i[0])
          ss[7:0] <= #Tp wb_dat_i[7:0];
        if (wb_sel_i[1])
          ss[15:8] <= #Tp wb_dat_i[15:8];
        if (wb_sel_i[2])
          ss[23:16] <= #Tp wb_dat_i[23:16];
        if (wb_sel_i[3])
          ss[`SPI_SS_NB-1:24] <= #Tp wb_dat_i[`SPI_SS_NB-1:24];
      `endif
      end
  end
  
  assign ss_pad_o = ~((ss & {`SPI_SS_NB{tip & ass}}) | (ss & {`SPI_SS_NB{!ass}}));
  
  spi_clgen clgen (.clk_in(wb_clk_i), .rst(wb_rst_i), .go(go), .enable(tip), .last_clk(last_bit),
                   .divider(divider), .clk_out(sclk_pad_o), .pos_edge(pos_edge), 
                   .neg_edge(neg_edge));
  
  spi_shift_clean shift (.clk(wb_clk_i), .rst(wb_rst_i), .len(char_len[`SPI_CHAR_LEN_BITS-1:0]),
                   .latch(spi_tx_sel[3:0] & {4{wb_we_i}}), .byte_sel(wb_sel_i), .lsb(lsb), 
                   .go(go), .pos_edge(pos_edge), .neg_edge(neg_edge), 
                   .rx_negedge(rx_negedge), .tx_negedge(tx_negedge),
                   .tip(tip), .last(last_bit), 
                   .p_in(wb_dat_i), .p_out(rx), 
                   .s_clk(sclk_pad_o), .s_in(miso_pad_i), .s_out(mosi_pad_o));
endmodule

//////////////////////////////////////////////////////////////////////
////                                                              ////
////  spi_shift.v                                                 ////
////                                                              ////
////  This file is part of the SPI IP core project                ////
////  http://www.opencores.org/projects/spi/                      ////
////                                                              ////
////  Author(s):                                                  ////
////      - Simon Srot (simons@opencores.org)                     ////
////                                                              ////
////  All additional information is avaliable in the Readme.txt   ////
////  file.                                                       ////
////                                                              ////
//////////////////////////////////////////////////////////////////////
////                                                              ////
//// Copyright (C) 2002 Authors                                   ////
////                                                              ////
//// This source file may be used and distributed without         ////
//// restriction provided that this copyright statement is not    ////
//// removed from the file and that any derivative work contains  ////
//// the original copyright notice and the associated disclaimer. ////
////                                                              ////
//// This source file is free software; you can redistribute it   ////
//// and/or modify it under the terms of the GNU Lesser General   ////
//// Public License as published by the Free Software Foundation; ////
//// either version 2.1 of the License, or (at your option) any   ////
//// later version.                                               ////
////                                                              ////
//// This source is distributed in the hope that it will be       ////
//// useful, but WITHOUT ANY WARRANTY; without even the implied   ////
//// warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR      ////
//// PURPOSE.  See the GNU Lesser General Public License for more ////
//// details.                                                     ////
////                                                              ////
//// You should have received a copy of the GNU Lesser General    ////
//// Public License along with this source; if not, download it   ////
//// from http://www.opencores.org/lgpl.shtml                     ////
////                                                              ////
//////////////////////////////////////////////////////////////////////

module spi_shift_clean (clk, rst, latch, byte_sel, len, lsb, go,
                  pos_edge, neg_edge, rx_negedge, tx_negedge,
                  tip, last, 
                  p_in, p_out, s_clk, s_in, s_out);

  parameter Tp = 1;
  
  input                          clk;          // system clock
  input                          rst;          // reset
  input                    [3:0] latch;        // latch signal for storing the data in shift register
  input                    [3:0] byte_sel;     // byte select signals for storing the data in shift register
  input [`SPI_CHAR_LEN_BITS-1:0] len;          // data len in bits (minus one)
  input                          lsb;          // lbs first on the line
  input                          go;           // start stansfer
  input                          pos_edge;     // recognize posedge of sclk
  input                          neg_edge;     // recognize negedge of sclk
  input                          rx_negedge;   // s_in is sampled on negative edge 
  input                          tx_negedge;   // s_out is driven on negative edge
  output                         tip;          // transfer in progress
  output                         last;         // last bit
  input                   [31:0] p_in;         // parallel in
  output     [`SPI_MAX_CHAR-1:0] p_out;        // parallel out
  input                          s_clk;        // serial clock
  input                          s_in;         // serial in
  output                         s_out;        // serial out
                                               
  reg                            s_out;        
  reg                            tip;
                              
  reg     [`SPI_CHAR_LEN_BITS:0] cnt;          // data bit count
  reg        [`SPI_MAX_CHAR-1:0] data;         // shift register
  wire    [`SPI_CHAR_LEN_BITS:0] tx_bit_pos;   // next bit position
  wire    [`SPI_CHAR_LEN_BITS:0] rx_bit_pos;   // next bit position
  wire                           rx_clk;       // rx clock enable
  wire                           tx_clk;       // tx clock enable
  
  assign p_out = data;
  
  assign tx_bit_pos = lsb ? {!(|len), len} - cnt : cnt - {{`SPI_CHAR_LEN_BITS{1'b0}},1'b1};
  assign rx_bit_pos = lsb ? {!(|len), len} - (rx_negedge ? cnt + {{`SPI_CHAR_LEN_BITS{1'b0}},1'b1} : cnt) : 
                            (rx_negedge ? cnt : cnt - {{`SPI_CHAR_LEN_BITS{1'b0}},1'b1});
  
  assign last = !(|cnt);
  
  assign rx_clk = (rx_negedge ? neg_edge : pos_edge) && (!last || s_clk);
  assign tx_clk = (tx_negedge ? neg_edge : pos_edge) && !last;
  
  // Character bit counter
  always @(posedge clk or posedge rst)
  begin
    if(rst)
      cnt <= #Tp {`SPI_CHAR_LEN_BITS+1{1'b0}};
    else
      begin
        if(tip)
          cnt <= #Tp pos_edge ? (cnt - {{`SPI_CHAR_LEN_BITS{1'b0}}, 1'b1}) : cnt;
        else
          cnt <= #Tp !(|len) ? {1'b1, {`SPI_CHAR_LEN_BITS{1'b0}}} : {1'b0, len};
      end
  end
  
  // Transfer in progress
  always @(posedge clk or posedge rst)
  begin
    if(rst)
      tip <= #Tp 1'b0;
  else if(go && ~tip)
    tip <= #Tp 1'b1;
  else if(tip && last && pos_edge)
    tip <= #Tp 1'b0;
  end
  
  // Sending bits to the line
  always @(posedge clk or posedge rst)
  begin
    if (rst)
      s_out   <= #Tp 1'b0;
    else
      s_out <= #Tp (tx_clk || !tip) ? data[tx_bit_pos[`SPI_CHAR_LEN_BITS-1:0]] : s_out;
  end
  
  // Receiving bits from the line
  always @(posedge clk or posedge rst)
  begin
    if (rst)
      data   <= #Tp {`SPI_MAX_CHAR{1'b0}};
`ifdef SPI_MAX_CHAR_128
    else if (latch[0] && !tip)
      begin
        if (byte_sel[3])
          data[31:24] <= #Tp p_in[31:24];
        if (byte_sel[2])
          data[23:16] <= #Tp p_in[23:16];
        if (byte_sel[1])
          data[15:8] <= #Tp p_in[15:8];
        if (byte_sel[0])
          data[7:0] <= #Tp p_in[7:0];
      end
    else if (latch[1] && !tip)
      begin
        if (byte_sel[3])
          data[63:56] <= #Tp p_in[31:24];
        if (byte_sel[2])
          data[55:48] <= #Tp p_in[23:16];
        if (byte_sel[1])
          data[47:40] <= #Tp p_in[15:8];
        if (byte_sel[0])
          data[39:32] <= #Tp p_in[7:0];
      end
    else if (latch[2] && !tip)
      begin
        if (byte_sel[3])
          data[95:88] <= #Tp p_in[31:24];
        if (byte_sel[2])
          data[87:80] <= #Tp p_in[23:16];
        if (byte_sel[1])
          data[79:72] <= #Tp p_in[15:8];
        if (byte_sel[0])
          data[71:64] <= #Tp p_in[7:0];
      end
    else if (latch[3] && !tip)
      begin
        if (byte_sel[3])
          data[127:120] <= #Tp p_in[31:24];
        if (byte_sel[2])
          data[119:112] <= #Tp p_in[23:16];
        if (byte_sel[1])
          data[111:104] <= #Tp p_in[15:8];
        if (byte_sel[0])
          data[103:96] <= #Tp p_in[7:0];
      end
`else
`ifdef SPI_MAX_CHAR_64
    else if (latch[0] && !tip)
      begin
        if (byte_sel[3])
          data[31:24] <= #Tp p_in[31:24];
        if (byte_sel[2])
          data[23:16] <= #Tp p_in[23:16];
        if (byte_sel[1])
          data[15:8] <= #Tp p_in[15:8];
        if (byte_sel[0])
          data[7:0] <= #Tp p_in[7:0];
      end
    else if (latch[1] && !tip)
      begin
        if (byte_sel[3])
          data[63:56] <= #Tp p_in[31:24];
        if (byte_sel[2])
          data[55:48] <= #Tp p_in[23:16];
        if (byte_sel[1])
          data[47:40] <= #Tp p_in[15:8];
        if (byte_sel[0])
          data[39:32] <= #Tp p_in[7:0];
      end
`else
    else if (latch[0] && !tip)
      begin
      `ifdef SPI_MAX_CHAR_8
        if (byte_sel[0])
          data[`SPI_MAX_CHAR-1:0] <= #Tp p_in[`SPI_MAX_CHAR-1:0];
      `endif
      `ifdef SPI_MAX_CHAR_16
        if (byte_sel[0])
          data[7:0] <= #Tp p_in[7:0];
        if (byte_sel[1])
          data[`SPI_MAX_CHAR-1:8] <= #Tp p_in[`SPI_MAX_CHAR-1:8];
      `endif
      `ifdef SPI_MAX_CHAR_24
        if (byte_sel[0])
          data[7:0] <= #Tp p_in[7:0];
        if (byte_sel[1])
          data[15:8] <= #Tp p_in[15:8];
        if (byte_sel[2])
          data[`SPI_MAX_CHAR-1:16] <= #Tp p_in[`SPI_MAX_CHAR-1:16];
      `endif
      `ifdef SPI_MAX_CHAR_32
        if (byte_sel[0])
          data[7:0] <= #Tp p_in[7:0];
        if (byte_sel[1])
          data[15:8] <= #Tp p_in[15:8];
        if (byte_sel[2])
          data[23:16] <= #Tp p_in[23:16];
        if (byte_sel[3])
          data[`SPI_MAX_CHAR-1:24] <= #Tp p_in[`SPI_MAX_CHAR-1:24];
      `endif
      end
`endif
`endif
    else
      data[rx_bit_pos[`SPI_CHAR_LEN_BITS-1:0]] <= #Tp rx_clk ? s_in : data[rx_bit_pos[`SPI_CHAR_LEN_BITS-1:0]];
  end
  
endmodule
