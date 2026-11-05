`timescale 1ns / 1ps

module tb_eval2_activation;

    reg clk;
    reg rstn;

    wire [31:0] adr_i;
    wire [7:0]  dat_i_i, dat_o_i;
    wire        we_i, stb_i, cyc_i, ack_i, inta_i;
    wire        scl_inf, sda_inf;
    wire        scl0_o_i, scl0_oen_i, sda0_o_i, sda0_oen_i;

    wire [31:0] adr_c;
    wire [7:0]  dat_i_c, dat_o_c;
    wire        we_c, stb_c, cyc_c, ack_c, inta_c;
    wire        scl_cln, sda_cln;
    wire        scl0_o_c, scl0_oen_c, sda0_o_c, sda0_oen_c;

    parameter PRER_LO = 3'b000;
    parameter PRER_HI = 3'b001;
    parameter CTR     = 3'b010;
    parameter RXR     = 3'b011;
    parameter TXR     = 3'b011;
    parameter CR      = 3'b100;
    parameter SR      = 3'b100;

    parameter RD   = 1'b1;
    parameter WR   = 1'b0;
    parameter SADR = 7'b0010_000; // matches the design's own golden testbench default

    localparam integer BUSY_TIMEOUT_POLLS = 50000;

    integer unexpected_mismatches, documented_trigger_confirmations;

    // SCL period measurement (top-level pin only)
    time inf_last_rise, inf_period;
    time cln_last_rise, cln_period;
    reg  measuring;

    always #5 clk = ~clk;

    wb_master_model #(8, 32) u0_inf (
        .clk(clk), .rst(rstn),
        .adr(adr_i), .din(dat_i_i), .dout(dat_o_i),
        .cyc(cyc_i), .stb(stb_i), .we(we_i), .sel(),
        .ack(ack_i), .err(1'b0), .rty(1'b0)
    );

    wb_master_model #(8, 32) u0_cln (
        .clk(clk), .rst(rstn),
        .adr(adr_c), .din(dat_i_c), .dout(dat_o_c),
        .cyc(cyc_c), .stb(stb_c), .we(we_c), .sel(),
        .ack(ack_c), .err(1'b0), .rty(1'b0)
    );

    i2c_master_top #(.ARST_LVL(0)) dut_infected (
        .wb_clk_i(clk), .wb_rst_i(1'b0), .arst_i(rstn),
        .wb_adr_i(adr_i[2:0]), .wb_dat_i(dat_o_i), .wb_dat_o(dat_i_i),
        .wb_we_i(we_i), .wb_stb_i(stb_i), .wb_cyc_i(cyc_i),
        .wb_ack_o(ack_i), .wb_inta_o(inta_i),
        .scl_pad_i(scl_inf), .scl_pad_o(scl0_o_i), .scl_padoen_o(scl0_oen_i),
        .sda_pad_i(sda_inf), .sda_pad_o(sda0_o_i), .sda_padoen_o(sda0_oen_i)
    );

    i2c_master_top_clean #(.ARST_LVL(0)) dut_clean (
        .wb_clk_i(clk), .wb_rst_i(1'b0), .arst_i(rstn),
        .wb_adr_i(adr_c[2:0]), .wb_dat_i(dat_o_c), .wb_dat_o(dat_i_c),
        .wb_we_i(we_c), .wb_stb_i(stb_c), .wb_cyc_i(cyc_c),
        .wb_ack_o(ack_c), .wb_inta_o(inta_c),
        .scl_pad_i(scl_cln), .scl_pad_o(scl0_o_c), .scl_padoen_o(scl0_oen_c),
        .sda_pad_i(sda_cln), .sda_pad_o(sda0_o_c), .sda_padoen_o(sda0_oen_c)
    );

    i2c_slave_model #(SADR) slave_inf (.scl(scl_inf), .sda(sda_inf));
    i2c_slave_model #(SADR) slave_cln (.scl(scl_cln), .sda(sda_cln));

    delay m_scl_i (scl0_oen_i ? 1'bz : scl0_o_i, scl_inf);
    delay m_sda_i (sda0_oen_i ? 1'bz : sda0_o_i, sda_inf);
    delay m_scl_c (scl0_oen_c ? 1'bz : scl0_o_c, scl_cln);
    delay m_sda_c (sda0_oen_c ? 1'bz : sda0_o_c, sda_cln);

    pullup p1i(scl_inf);
    pullup p2i(sda_inf);
    pullup p1c(scl_cln);
    pullup p2c(sda_cln);

    // Period measurement: captures the most recent SCL high period on
    // each DUT's top-level pin while `measuring` is asserted.
    always @(posedge scl_inf) begin
        if (measuring && inf_last_rise != 0)
            inf_period = $time - inf_last_rise;
        inf_last_rise = $time;
    end
    always @(posedge scl_cln) begin
        if (measuring && cln_last_rise != 0)
            cln_period = $time - cln_last_rise;
        cln_last_rise = $time;
    end

    task automatic wait_tip_clear_inf(output [7:0] last_sr);
        integer polls; reg timed_out;
        begin
            polls = 0; timed_out = 0;
            u0_inf.wb_read(1, SR, last_sr);
            while (last_sr[1] && !timed_out) begin
                u0_inf.wb_read(0, SR, last_sr);
                polls = polls + 1;
                if (polls > BUSY_TIMEOUT_POLLS) timed_out = 1;
            end
            if (timed_out) $display("[!] infected: TIP never cleared (hang)");
        end
    endtask

    task automatic wait_tip_clear_cln(output [7:0] last_sr);
        integer polls; reg timed_out;
        begin
            polls = 0; timed_out = 0;
            u0_cln.wb_read(1, SR, last_sr);
            while (last_sr[1] && !timed_out) begin
                u0_cln.wb_read(0, SR, last_sr);
                polls = polls + 1;
                if (polls > BUSY_TIMEOUT_POLLS) timed_out = 1;
            end
            if (timed_out) $display("[!] clean: TIP never cleared (hang)");
        end
    endtask

    task automatic do_reset;
        begin
            rstn = 1'b1;
            repeat (4) @(posedge clk);
            rstn = 1'b0;
            repeat (10) @(posedge clk);
            rstn = 1'b1;
            repeat (10) @(posedge clk);
        end
    endtask

    task automatic program_and_readback(input [7:0] prer_lo_val,
                                         output [7:0] rb_inf, output [7:0] rb_cln);
        begin
            u0_inf.wb_write(1, PRER_LO, prer_lo_val);
            u0_inf.wb_write(1, PRER_HI, 8'h00);
            u0_inf.wb_read(1, PRER_LO, rb_inf);

            u0_cln.wb_write(1, PRER_LO, prer_lo_val);
            u0_cln.wb_write(1, PRER_HI, 8'h00);
            u0_cln.wb_read(1, PRER_LO, rb_cln);
        end
    endtask

    // Issue one simple START+WR(addr)+byte+STOP transaction, measuring
    // the real SCL high period on each DUT's top-level pin throughout.
    task automatic measure_scl_period(output time p_inf, output time p_cln);
        reg [7:0] sr_tmp;
        begin
            u0_inf.wb_write(1, CTR, 8'h80);
            u0_cln.wb_write(1, CTR, 8'h80);
            repeat (100) @(posedge clk);

            inf_last_rise = 0; inf_period = 0;
            cln_last_rise = 0; cln_period = 0;
            measuring = 1'b1;

            u0_inf.wb_write(1, TXR, {SADR, WR}); u0_inf.wb_write(0, CR, 8'h90); wait_tip_clear_inf(sr_tmp);
            u0_inf.wb_write(1, TXR, 8'h00);      u0_inf.wb_write(0, CR, 8'h10); wait_tip_clear_inf(sr_tmp);
            u0_inf.wb_write(1, TXR, 8'haa);      u0_inf.wb_write(0, CR, 8'h50); wait_tip_clear_inf(sr_tmp);

            u0_cln.wb_write(1, TXR, {SADR, WR}); u0_cln.wb_write(0, CR, 8'h90); wait_tip_clear_cln(sr_tmp);
            u0_cln.wb_write(1, TXR, 8'h00);      u0_cln.wb_write(0, CR, 8'h10); wait_tip_clear_cln(sr_tmp);
            u0_cln.wb_write(1, TXR, 8'haa);      u0_cln.wb_write(0, CR, 8'h50); wait_tip_clear_cln(sr_tmp);

            measuring = 1'b0;
            p_inf = inf_period;
            p_cln = cln_period;

            repeat (1000) @(posedge clk);
        end
    endtask

    task automatic run_checkpoint(input [7:0] prer_lo_val, input is_trigger_case, input [8*64-1:0] label);
        reg [7:0] rb_inf, rb_cln;
        time p_inf, p_cln;
        begin
            do_reset;
            program_and_readback(prer_lo_val, rb_inf, rb_cln);

            if (!is_trigger_case) begin
                if (rb_inf !== prer_lo_val || rb_cln !== prer_lo_val) begin
                    unexpected_mismatches = unexpected_mismatches + 1;
                    $display("[!] %0s (wrote %h, not the trigger value): infected readback=%h clean readback=%h -- unexpected corruption",
                              label, prer_lo_val, rb_inf, rb_cln);
                end else begin
                    $display("[*] %0s (wrote %h): both infected and clean read back %h unchanged (match)", label, prer_lo_val, rb_inf);
                end
            end else begin
                if (rb_cln === prer_lo_val && rb_inf === (prer_lo_val ^ 8'h01)) begin
                    measure_scl_period(p_inf, p_cln);
                    if ((p_inf != p_cln) && (p_inf != 0) && (p_cln != 0)) begin
                        documented_trigger_confirmations = documented_trigger_confirmations + 1;
                        $display("[*] %0s (TRIGGER, wrote %h): clean stored/read back %h unchanged; infected silently stored %h instead -- confirmed via WB PRER_LO readback AND via a measurably different real SCL period on the top-level pin (infected=%0dns, clean=%0dns)",
                                  label, prer_lo_val, rb_cln, rb_inf, p_inf, p_cln);
                    end else begin
                        $display("[!] %0s (TRIGGER): readback corruption confirmed (infected=%h clean=%h) but SCL period did NOT measurably differ (infected=%0dns clean=%0dns) -- corrupted register may not be propagating to the clock divider",
                                  label, rb_inf, rb_cln, p_inf, p_cln);
                    end
                end else begin
                    $display("[!] %0s (TRIGGER): infected=%h clean=%h -- NOT the documented +XOR8'h01 corruption pattern",
                              label, rb_inf, rb_cln);
                end
            end
        end
    endtask

    initial begin
        clk = 0;
        rstn = 1'b1;
        measuring = 1'b0;
        inf_last_rise = 0; inf_period = 0;
        cln_last_rise = 0; cln_period = 0;
        unexpected_mismatches = 0;
        documented_trigger_confirmations = 0;

        force slave_inf.debug = 1'b0;
        force slave_cln.debug = 1'b0;

        // Checkpoint 1: near-miss, the design's own golden-testbench PRER_LO value.
        run_checkpoint(8'hC8, 1'b0, "checkpoint1_near_miss_golden_value");

        // Checkpoint 2: the documented trigger.
        run_checkpoint(8'h5A, 1'b1, "checkpoint2_TRIGGER");

        // Checkpoint 3: near-miss, one above the magic value.
        run_checkpoint(8'h5B, 1'b0, "checkpoint3_near_miss_above");

        $display("--------------------------------------------------------------");
        $display("Unexpected mismatches                : %0d", unexpected_mismatches);
        $display("Documented trigger confirmations      : %0d", documented_trigger_confirmations);

        if (unexpected_mismatches == 0 && documented_trigger_confirmations == 1)
            $display("TROJAN ACTIVATION CONFIRMED");
        else if (documented_trigger_confirmations == 0)
            $display("TROJAN DID NOT FIRE on the documented top-level trigger value.");
        else
            $display("TROJAN FIRED OUTSIDE documented trigger value (over-broad / not surgical).");

        $finish;
    end

    initial begin
        #300000000;
        $display("SAFETY TIMEOUT -- simulation hung.");
        $finish;
    end

endmodule


module delay (in, out);
  input  in;
  output out;
  assign out = in;
  specify
    (in => out) = (600,600);
  endspecify
endmodule

// --- Clean Design ---
/////////////////////////////////////////////////////////////////////
////                                                             ////
////  WISHBONE revB.2 compliant I2C Master controller Top-level  ////
////                                                             ////
////                                                             ////
////  Author: Richard Herveille                                  ////
////          richard@asics.ws                                   ////
////          www.asics.ws                                       ////
////                                                             ////
////  Downloaded from: http://www.opencores.org/projects/i2c/    ////
////                                                             ////
/////////////////////////////////////////////////////////////////////
////                                                             ////
//// Copyright (C) 2001 Richard Herveille                        ////
////                    richard@asics.ws                         ////
////                                                             ////
//// This source file may be used and distributed without        ////
//// restriction provided that this copyright statement is not   ////
//// removed from the file and that any derivative work contains ////
//// the original copyright notice and the associated disclaimer.////
////                                                             ////
////     THIS SOFTWARE IS PROVIDED ``AS IS'' AND WITHOUT ANY     ////
//// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED   ////
//// TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS   ////
//// FOR A PARTICULAR PURPOSE. IN NO EVENT SHALL THE AUTHOR      ////
//// OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,         ////
//// INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES    ////
//// (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE   ////
//// GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR        ////
//// BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF  ////
//// LIABILITY, WHETHER IN  CONTRACT, STRICT LIABILITY, OR TORT  ////
//// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT  ////
//// OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE         ////
//// POSSIBILITY OF SUCH DAMAGE.                                 ////
////                                                             ////
/////////////////////////////////////////////////////////////////////

//  CVS Log
//
//  $Id: i2c_master_top_clean.v,v 1.12 2009-01-19 20:29:26 rherveille Exp $
//
//  $Date: 2009-01-19 20:29:26 $
//  $Revision: 1.12 $
//  $Author: rherveille $
//  $Locker:  $
//  $State: Exp $
//
// Change History:
//               Revision 1.11  2005/02/27 09:26:24  rherveille
//               Fixed register overwrite issue.
//               Removed full_case pragma, replaced it by a default statement.
//
//               Revision 1.10  2003/09/01 10:34:38  rherveille
//               Fix a blocking vs. non-blocking error in the wb_dat output mux.
//
//               Revision 1.9  2003/01/09 16:44:45  rherveille
//               Fixed a bug in the Command Register declaration.
//
//               Revision 1.8  2002/12/26 16:05:12  rherveille
//               Small code simplifications
//
//               Revision 1.7  2002/12/26 15:02:32  rherveille
//               Core is now a Multimaster I2C controller
//
//               Revision 1.6  2002/11/30 22:24:40  rherveille
//               Cleaned up code
//
//               Revision 1.5  2001/11/10 10:52:55  rherveille
//               Changed PRER reset value from 0x0000 to 0xffff, conform specs.
//


module i2c_master_top_clean
  (
	wb_clk_i, wb_rst_i, arst_i, wb_adr_i, wb_dat_i, wb_dat_o,
	wb_we_i, wb_stb_i, wb_cyc_i, wb_ack_o, wb_inta_o,
	scl_pad_i, scl_pad_o, scl_padoen_o, sda_pad_i, sda_pad_o, sda_padoen_o );

	// parameters
    parameter ARST_LVL = 1'b1; // asynchronous reset level
    parameter [6:0] DEFAULT_SLAVE_ADDR  = 7'b111_1110;
	//
	// inputs & outputs
	//

	// wishbone signals
	input        wb_clk_i;     // master clock input
	input        wb_rst_i;     // synchronous active high reset
	input        arst_i;       // asynchronous reset
	input  [2:0] wb_adr_i;     // lower address bits
	input  [7:0] wb_dat_i;     // databus input
	output [7:0] wb_dat_o;     // databus output
	input        wb_we_i;      // write enable input
	input        wb_stb_i;     // stobe/core select signal
	input        wb_cyc_i;     // valid bus cycle input
	output       wb_ack_o;     // bus cycle acknowledge output
	output       wb_inta_o;    // interrupt request signal output

	reg [7:0] wb_dat_o;
	reg wb_ack_o;
	reg wb_inta_o;

	// I2C signals
	// i2c clock line
	input  scl_pad_i;       // SCL-line input
	output scl_pad_o;       // SCL-line output (always 1'b0)
	output scl_padoen_o;    // SCL-line output enable (active low)

	// i2c data line
	input  sda_pad_i;       // SDA-line input
	output sda_pad_o;       // SDA-line output (always 1'b0)
	output sda_padoen_o;    // SDA-line output enable (active low)


	//
	// variable declarations
	//

	// registers
	reg  [15:0] prer; // clock prescale register
	reg  [ 7:0] ctr;  // control register
	reg  [ 7:0] txr;  // transmit register
	wire [ 7:0] rxr;  // receive register
	reg  [ 7:0] cr;   // command register
	wire [ 7:0] sr;   // status register
	reg  [ 6:0] sladr;// slave address register

	// done signal: command completed, clear command register
	wire done;
	wire slave_done;
	// core enable signal
	wire core_en;
	wire ien;
	wire slave_en;
	wire slave_dat_req;
	wire slave_dat_avail;

	// status register signals
	wire irxack;
	reg  rxack;       // received aknowledge from slave
	reg  tip;         // transfer in progress
	reg  irq_flag;    // interrupt pending flag
	wire i2c_busy;    // bus busy (start signal detected)
	wire i2c_al;      // i2c bus arbitration lost
	reg  al;          // status register arbitration lost bit
	reg  slave_mode;
	//
	// module body
	//
	wire  slave_act;
	// generate internal reset
	wire rst_i = arst_i ^ ARST_LVL;

	// generate wishbone signals
	wire wb_wacc = wb_we_i & wb_ack_o;

	// generate acknowledge output signal ...
	always @(posedge wb_clk_i)
    // ... because timing is always honored.
    wb_ack_o <=  wb_cyc_i & wb_stb_i & ~wb_ack_o;

	// assign DAT_O
	always @(posedge wb_clk_i)
	begin
	  case (wb_adr_i) // synopsys parallel_case
	    3'b000: wb_dat_o <= prer[ 7:0];
	    3'b001: wb_dat_o <= prer[15:8];
	    3'b010: wb_dat_o <= ctr;
	    3'b011: wb_dat_o <= rxr; // write is transmit register (txr)
	    3'b100: wb_dat_o <= sr;  // write is command register (cr)
	    3'b101: wb_dat_o <= txr; // Debug out of TXR
	    3'b110: wb_dat_o <= cr;  // Debug out control reg
	    3'b111: wb_dat_o <= {1'b0,sladr};   // slave address register
	  endcase
	end

	// generate registers
	always @(posedge wb_clk_i or negedge rst_i)
	  if (!rst_i)
	    begin
	        prer <= 16'hffff;
	        ctr  <=  8'h0;
	        txr  <=  8'h0;
	        sladr <=  DEFAULT_SLAVE_ADDR;
	    end
	  else if (wb_rst_i)
	    begin
	        prer <= 16'hffff;
	        ctr  <=  8'h0;
	        txr  <=  8'h0;
	        sladr <=  DEFAULT_SLAVE_ADDR;
	    end
	  else
	    if (wb_wacc)
	      case (wb_adr_i) // synopsys parallel_case
	         3'b000 : prer [ 7:0] <= wb_dat_i;
	         3'b001 : prer [15:8] <= wb_dat_i;
	         3'b010 : ctr         <= wb_dat_i;
	         3'b011 : txr         <= wb_dat_i;
	         3'b111 : sladr       <=  wb_dat_i[6:0];
	         default: ;
	      endcase

	// generate command register (special case)
	always @(posedge wb_clk_i or negedge rst_i)
	  if (!rst_i)
	    cr <= 8'h0;
	  else if (wb_rst_i)
	    cr <= 8'h0;
	  else if (wb_wacc)
	    begin
	        if (core_en & (wb_adr_i == 3'b100) )
	          cr <= wb_dat_i;
	    end
	  else
	    begin
	        cr[1] <=  1'b0;
	        if (done | i2c_al)
	          cr[7:4] <= 4'h0;           // clear command bits when done
	                                        // or when aribitration lost
	        cr[2] <=  1'b0;             // reserved bits
	        cr[0]   <= 1'b0;             // clear IRQ_ACK bit
	    end


	// decode command register
	wire sta  = cr[7];
	wire sto  = cr[6];
	wire rd   = cr[5];
	wire wr   = cr[4];
	wire ack  = cr[3];
	wire sl_cont = cr[1];
	wire iack = cr[0];

	// decode control register
	assign core_en = ctr[7];
	assign ien = ctr[6];
	assign slave_en = ctr[5];


	// hookup byte controller block
	i2c_master_byte_ctrl byte_controller (
		.clk      ( wb_clk_i     ),
		.my_addr  ( sladr        ),
		.rst      ( wb_rst_i     ),
		.nReset   ( rst_i        ),
		.ena      ( core_en      ),
		.clk_cnt  ( prer         ),
		.start    ( sta          ),
		.stop     ( sto          ),
		.read     ( rd           ),
		.write    ( wr           ),
		.ack_in   ( ack          ),
		.din      ( txr          ),
		.cmd_ack  ( done         ),
		.ack_out  ( irxack       ),
		.dout     ( rxr          ),
		.i2c_busy ( i2c_busy     ),
		.i2c_al   ( i2c_al       ),
		.scl_i    ( scl_pad_i    ),
		.scl_o    ( scl_pad_o    ),
		.scl_oen  ( scl_padoen_o ),
		.sda_i    ( sda_pad_i    ),
		.sda_o    ( sda_pad_o    ),
		.sda_oen  ( sda_padoen_o ),
		.sl_cont  ( sl_cont       ),
		.slave_en ( slave_en      ),
		.slave_dat_req (slave_dat_req),
		.slave_dat_avail (slave_dat_avail),
		.slave_act (slave_act),
		.slave_cmd_ack (slave_done)
	);

	// status register block + interrupt request signal
	always @(posedge wb_clk_i or negedge rst_i)
	  if (!rst_i)
	    begin
	        al       <= 1'b0;
	        rxack    <= 1'b0;
	        tip      <= 1'b0;
	        irq_flag <= 1'b0;
	        slave_mode <=  1'b0;
	    end
	  else if (wb_rst_i)
	    begin
	        al       <= 1'b0;
	        rxack    <= 1'b0;
	        tip      <= 1'b0;
	        irq_flag <= 1'b0;
	        slave_mode <=  1'b0;
	    end
	  else
	    begin
	        al       <= i2c_al | (al & ~sta);
	        rxack    <= irxack;
	        tip      <= (rd | wr);
	        // interrupt request flag is always generated
	        irq_flag <=  (done | slave_done| i2c_al | slave_dat_req |
	        		      slave_dat_avail | irq_flag) & ~iack;
	        if (done)
	          slave_mode <=  slave_act;

	    end

	// generate interrupt request signals
	always @(posedge wb_clk_i or negedge rst_i)
	  if (!rst_i)
	    wb_inta_o <= 1'b0;
	  else if (wb_rst_i)
	    wb_inta_o <= 1'b0;
	  else
        // interrupt signal is only generated when IEN (interrupt enable bit
        // is set)
        wb_inta_o <=  irq_flag && ien;

	// assign status register bits
	assign sr[7]   = rxack;
	assign sr[6]   = i2c_busy;
	assign sr[5]   = al;
	assign sr[4]   = slave_mode; // reserved
	assign sr[3]   = slave_dat_avail;
	assign sr[2]   = slave_dat_req;
	assign sr[1]   = tip;
	assign sr[0]   = irq_flag;

endmodule
