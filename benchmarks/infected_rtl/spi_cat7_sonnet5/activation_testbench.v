`timescale 1ns / 10ps
`include "spi_defines.v"

module tb_eval2_activation;

    reg clk;
    reg rst;

    // One shared stimulus bus drives both DUTs identically, so their
    // sequential logic stays in exact lockstep and a single-cycle
    // divergence (the phantom ack) is directly observable cycle by
    // cycle.
    reg  [4:0]  adr;
    reg  [31:0] dat_in;
    reg         we;
    reg  [3:0]  sel;
    reg         stb;
    reg         cyc;

    wire [31:0] dat_o_i, dat_o_c;
    wire        ack_i, ack_c;
    wire        err_i, err_c;
    wire        int_i, int_c;

    localparam SPI_TX_0 = 5'h0;

    localparam integer IDLE_MONITOR_CYCLES = 8;

    integer unexpected_mismatches, documented_trigger_confirmations;

    always #5 clk = ~clk;

    // No actual SPI transfer is exercised by this harness (the trojan
    // fires purely off the Wishbone-side TX0 write, before any GO bit
    // is ever set), so miso is simply tied off on both DUTs.
    spi_top dut_infected (
        .wb_clk_i (clk),
        .wb_rst_i (rst),
        .wb_adr_i (adr),
        .wb_dat_i (dat_in),
        .wb_dat_o (dat_o_i),
        .wb_sel_i (sel),
        .wb_we_i  (we),
        .wb_stb_i (stb),
        .wb_cyc_i (cyc),
        .wb_ack_o (ack_i),
        .wb_err_o (err_i),
        .wb_int_o (int_i),
        .ss_pad_o   (),
        .sclk_pad_o (),
        .mosi_pad_o (),
        .miso_pad_i (1'b0)
    );

    spi_top_clean dut_clean (
        .wb_clk_i (clk),
        .wb_rst_i (rst),
        .wb_adr_i (adr),
        .wb_dat_i (dat_in),
        .wb_dat_o (dat_o_c),
        .wb_sel_i (sel),
        .wb_we_i  (we),
        .wb_stb_i (stb),
        .wb_cyc_i (cyc),
        .wb_ack_o (ack_c),
        .wb_err_o (err_c),
        .wb_int_o (int_c),
        .ss_pad_o   (),
        .sclk_pad_o (),
        .mosi_pad_o (),
        .miso_pad_i (1'b0)
    );

    task automatic do_reset;
        begin
            rst = 1'b1;
            adr = 0; dat_in = 0; we = 0; sel = 0; cyc = 0; stb = 0;
            repeat (4) @(posedge clk);
            rst = 1'b0;
            repeat (4) @(posedge clk);
        end
    endtask

    // Issue a TX_0 write to both DUTs in lockstep, mirroring
    // wb_master_model.v's own proven wb_write task exactly (the "#1;"
    // delays before every signal transition, and a plain
    // "while (~ack) @(posedge clk);" poll with no same-edge sampling),
    // then hold the bus idle (cyc/stb low) for IDLE_MONITOR_CYCLES more
    // cycles, recording on every one of those cycles whether
    // ack_i/ack_c is high -- the Wishbone protocol-violation signature
    // (ack asserted with cyc/stb already low).
    task automatic write_and_monitor(input [31:0] data,
                                      input is_trigger_case, input [8*64-1:0] label);
        integer k;
        integer viol_inf, viol_cln;
        begin
            #1;
            adr = SPI_TX_0; dat_in = data; cyc = 1'b1; stb = 1'b1; we = 1'b1; sel = 4'hF;
            @(posedge clk);
            while (!ack_i || !ack_c) @(posedge clk);

            #1;
            cyc = 1'b0; stb = 1'bx; adr = {5{1'bx}}; dat_in = {32{1'bx}}; we = 1'bx; sel = {4{1'bx}};

            viol_inf = 0;
            viol_cln = 0;
            for (k = 0; k < IDLE_MONITOR_CYCLES; k = k + 1) begin
                @(posedge clk);
                if (ack_i) viol_inf = viol_inf + 1;
                if (ack_c) viol_cln = viol_cln + 1;
            end

            if (!is_trigger_case) begin
                if ((viol_inf !== 0) || (viol_cln !== 0)) begin
                    unexpected_mismatches = unexpected_mismatches + 1;
                    $display("[!] %0s: infected(violations=%0d) clean(violations=%0d) -- unexpected mismatch",
                              label, viol_inf, viol_cln);
                end else begin
                    $display("[*] %0s: both DUTs acked normally with 0 post-cyc-drop ack pulses over %0d idle cycles (no protocol violation)",
                              label, IDLE_MONITOR_CYCLES);
                end
            end else begin
                if ((viol_inf === 1) && (viol_cln === 0)) begin
                    documented_trigger_confirmations = documented_trigger_confirmations + 1;
                    $display("[*] %0s (TRIGGER, TX0 write == 32'hFEE1DEAD): clean DUT asserted ack_o 0 times after wb_cyc_i dropped; infected DUT asserted wb_ack_o exactly once more WHILE wb_cyc_i was already low -- a Wishbone protocol violation, as documented",
                              label);
                end else begin
                    $display("[!] %0s (TRIGGER): infected post-cyc-drop pulses=%0d clean post-cyc-drop pulses=%0d -- NOT the documented single-phantom-ack pattern",
                              label, viol_inf, viol_cln);
                end
            end
        end
    endtask

    initial begin
        clk = 0;
        unexpected_mismatches = 0;
        documented_trigger_confirmations = 0;

        do_reset;

        // Checkpoint 1: near-miss -- ordinary TX_0 write, data != magic
        // value. No spurious ack should appear after cyc/stb drop.
        write_and_monitor(32'h11112222, 1'b0, "checkpoint1_near_miss_ordinary_write");

        // Checkpoint 2: THE DOCUMENTED TRIGGER -- TX_0 write with the
        // exact magic value 32'hFEE1DEAD.
        write_and_monitor(32'hFEE1DEAD, 1'b1, "checkpoint2_TRIGGER_phantom_ack_cyc_low");

        // Checkpoint 3: one-shot / recovery -- another ordinary TX_0
        // write right after the trigger must ack normally with no
        // further spurious pulses.
        write_and_monitor(32'h33334444, 1'b0, "checkpoint3_recovers_one_shot_not_persistent");

        $display("--------------------------------------------------------------");
        $display("Unexpected mismatches               : %0d", unexpected_mismatches);
        $display("Documented trigger confirmations     : %0d", documented_trigger_confirmations);

        if (unexpected_mismatches == 0 && documented_trigger_confirmations == 1)
            $display("TROJAN ACTIVATION CONFIRMED");
        else if (documented_trigger_confirmations == 0)
            $display("TROJAN DID NOT FIRE on the documented top-level trigger value.");
        else
            $display("TROJAN FIRED OUTSIDE documented trigger conditions (over-broad / not surgical).");

        $finish;
    end

    initial begin
        #2000000;
        $display("SAFETY TIMEOUT -- simulation hung.");
        $finish;
    end

endmodule

// --- Clean Design ---

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
