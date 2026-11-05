`timescale 1ns / 10ps
`include "spi_defines.v"

module tb_eval2_activation;

	reg         clk;
	reg         rst;

	wire [31:0] adr_inf, dat_i_inf, dat_o_inf;
	wire        we_inf; wire [3:0] sel_inf; wire stb_inf, cyc_inf, ack_inf, err_inf, int_o_inf;
	wire  [7:0] ss_inf; wire sclk_inf, mosi_inf, miso_inf;

	wire [31:0] adr_cln, dat_i_cln, dat_o_cln;
	wire        we_cln; wire [3:0] sel_cln; wire stb_cln, cyc_cln, ack_cln, err_cln, int_o_cln;
	wire  [7:0] ss_cln; wire sclk_cln, mosi_cln, miso_cln;

	reg  [31:0] q_inf, q_cln;
	reg  [31:0] rx0_inf, rx0_cln;

	integer pin_mismatch_count;
	integer tag_fail_count;
	integer n;

	always #5 clk = ~clk;

	wb_master_model #(32, 32) i_wb_master_inf (
		.clk(clk), .rst(rst), .adr(adr_inf), .din(dat_i_inf), .dout(dat_o_inf),
		.cyc(cyc_inf), .stb(stb_inf), .we(we_inf), .sel(sel_inf), .ack(ack_inf), .err(err_inf), .rty(1'b0)
	);
	wb_master_model #(32, 32) i_wb_master_cln (
		.clk(clk), .rst(rst), .adr(adr_cln), .din(dat_i_cln), .dout(dat_o_cln),
		.cyc(cyc_cln), .stb(stb_cln), .we(we_cln), .sel(sel_cln), .ack(ack_cln), .err(err_cln), .rty(1'b0)
	);

	spi_top i_spi_top_inf (
		.wb_clk_i(clk), .wb_rst_i(rst),
		.wb_adr_i(adr_inf[4:0]), .wb_dat_i(dat_o_inf), .wb_dat_o(dat_i_inf),
		.wb_sel_i(sel_inf), .wb_we_i(we_inf), .wb_stb_i(stb_inf),
		.wb_cyc_i(cyc_inf), .wb_ack_o(ack_inf), .wb_err_o(err_inf), .wb_int_o(int_o_inf),
		.ss_pad_o(ss_inf), .sclk_pad_o(sclk_inf), .mosi_pad_o(mosi_inf), .miso_pad_i(miso_inf)
	);
	spi_slave_model i_spi_slave_inf ( .rst(rst), .ss(ss_inf[0]), .sclk(sclk_inf), .mosi(mosi_inf), .miso(miso_inf) );

	spi_top_clean i_spi_top_cln (
		.wb_clk_i(clk), .wb_rst_i(rst),
		.wb_adr_i(adr_cln[4:0]), .wb_dat_i(dat_o_cln), .wb_dat_o(dat_i_cln),
		.wb_sel_i(sel_cln), .wb_we_i(we_cln), .wb_stb_i(stb_cln),
		.wb_cyc_i(cyc_cln), .wb_ack_o(ack_cln), .wb_err_o(err_cln), .wb_int_o(int_o_cln),
		.ss_pad_o(ss_cln), .sclk_pad_o(sclk_cln), .mosi_pad_o(mosi_cln), .miso_pad_i(miso_cln)
	);
	spi_slave_model i_spi_slave_cln ( .rst(rst), .ss(ss_cln[0]), .sclk(sclk_cln), .mosi(mosi_cln), .miso(miso_cln) );

	always @(posedge clk) begin
		if (!rst) begin
			if (mosi_inf !== mosi_cln) pin_mismatch_count = pin_mismatch_count + 1;
			if (sclk_inf !== sclk_cln) pin_mismatch_count = pin_mismatch_count + 1;
			if (ss_inf   !== ss_cln)   pin_mismatch_count = pin_mismatch_count + 1;
		end
	end

	parameter SPI_TX_0   = 5'h0;
	parameter SPI_RX_0   = 5'h0;
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

	// Drives an identical, ordinary 8-bit transfer on both systems (every
	// step fork/joined so the two independent Wishbone buses stay time-
	// aligned -- see the cat1 sample's development notes for why this
	// matters), then reads SPI_RX_0 back on both and compares. Used for the
	// bulk "run N ordinary transfers" phase of this test.
	task automatic run_ordinary_transfer(input [31:0] tx_value);
		reg [13:0] ctrl_word;
		begin
			fork
				i_wb_master_inf.wb_write(0, SPI_TX_0, tx_value);
				i_wb_master_cln.wb_write(0, SPI_TX_0, tx_value);
			join
			ctrl_word = {1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 7'd8};
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
				wait_not_busy_inf("ordinary");
				wait_not_busy_cln("ordinary");
			join
			fork
				i_wb_master_inf.wb_read(0, SPI_RX_0, rx0_inf);
				i_wb_master_cln.wb_read(0, SPI_RX_0, rx0_cln);
			join
		end
	endtask

	initial begin
		pin_mismatch_count = 0;
		tag_fail_count = 0;

		clk = 0;
		i_spi_slave_inf.rx_negedge = 1'b0; i_spi_slave_inf.tx_negedge = 1'b0;
		i_spi_slave_cln.rx_negedge = 1'b0; i_spi_slave_cln.tx_negedge = 1'b0;

		rst = 1'b0; #2; rst = 1'b1;
		repeat (20) @(posedge clk);
		rst = 1'b0; @(posedge clk);

		fork
			i_wb_master_inf.wb_write(0, SPI_DIVIDE, 32'h00);
			i_wb_master_cln.wb_write(0, SPI_DIVIDE, 32'h00);
		join
		fork
			i_wb_master_inf.wb_write(0, SPI_SS, 32'h01);
			i_wb_master_cln.wb_write(0, SPI_SS, 32'h01);
		join

		// --- 99 ordinary 8-bit transfers: the counter should reach 99
		//     after these and still be fully dormant on every one of them
		//     (comfortably past the golden testbench's own directly-
		//     measured total of 40 completed transfers). ---
		for (n = 1; n <= 99; n = n + 1) begin
			run_ordinary_transfer(32'h00000000 | (n & 32'hFF));
			if (rx0_inf !== rx0_cln) begin
				tag_fail_count = tag_fail_count + 1;
				$display("[FAIL] transfer %0d: RX readback diverged BEFORE the documented trigger count (inf=%h cln=%h).", n, rx0_inf, rx0_cln);
			end
		end

		if (pin_mismatch_count != 0 || tag_fail_count != 0) begin
			$display("[-] pin_mismatch=%0d tag_fail=%0d observed across 99 ordinary transfers -- dormancy violated.", pin_mismatch_count, tag_fail_count);
			$display("TROJAN ACTIVATION INCONCLUSIVE");
			$finish;
		end
		$display("[+] 0 pin mismatches and 0 RX-readback mismatches across 99 ordinary transfers (xfer_cnt 0 through 99).");

		// --- The 100th transfer: documented trigger count (xfer_cnt==100) ---
		run_ordinary_transfer(32'h000000AA);
		pin_mismatch_count = 0;

		if (rx0_inf === rx0_cln) begin
			$display("[-] RX readback still matched on transfer 100 (inf=%h cln=%h) -- no corruption observed.", rx0_inf, rx0_cln);
			$display("TROJAN ACTIVATION INCONCLUSIVE");
			$finish;
		end
		if (rx0_inf !== (rx0_cln ^ 32'hFFFFFFFF)) begin
			$display("[-] RX readback diverged (inf=%h cln=%h) but not by the documented bit-complement payload -- investigate.", rx0_inf, rx0_cln);
			$display("TROJAN ACTIVATION INCONCLUSIVE");
			$finish;
		end
		$display("[+] On transfer 100 (xfer_cnt reaching the documented threshold), SPI_RX_0 readback on the infected DUT (%h) is the bit-complement of the clean reference's correct readback (%h) -- the infected core corrupted the RX data the host software would read back, without touching the actual serial bus content (mosi/sclk/ss matched throughout this transfer, confirmed by pin_mismatch_count=%0d for this single transfer).", rx0_inf, rx0_cln, pin_mismatch_count);
		$display("TROJAN ACTIVATION CONFIRMED");

		// --- Recovery: the next transfer must read back correctly again. ---
		run_ordinary_transfer(32'h00000055);
		if (rx0_inf !== rx0_cln) begin
			$display("[-] RX readback diverged on the transfer immediately after the trigger (inf=%h cln=%h) -- design did not resynchronize cleanly.", rx0_inf, rx0_cln);
		end else begin
			$display("[+] Clean, immediate resynchronization confirmed: RX readback matches again on the very next transfer.");
		end

		$display("\n\nstatus: %t Eval2 testbench done", $time);
		$finish;
	end

	initial begin
		#20000000;
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
  
  spi_shift shift (.clk(wb_clk_i), .rst(wb_rst_i), .len(char_len[`SPI_CHAR_LEN_BITS-1:0]),
                   .latch(spi_tx_sel[3:0] & {4{wb_we_i}}), .byte_sel(wb_sel_i), .lsb(lsb), 
                   .go(go), .pos_edge(pos_edge), .neg_edge(neg_edge), 
                   .rx_negedge(rx_negedge), .tx_negedge(tx_negedge),
                   .tip(tip), .last(last_bit), 
                   .p_in(wb_dat_i), .p_out(rx), 
                   .s_clk(sclk_pad_o), .s_in(miso_pad_i), .s_out(mosi_pad_o));
endmodule
