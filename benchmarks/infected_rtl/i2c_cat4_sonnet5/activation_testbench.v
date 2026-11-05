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

    // A hang, if it happens, must never be waited out with an unbounded
    // loop (that would itself look like the testbench hanging). This
    // bound is generous relative to a normal transaction's poll count
    // (observed well under 200 polls for a normal byte write/ack cycle)
    // while still being far short of the outer safety timeout.
    localparam integer BUSY_TIMEOUT_POLLS = 50000;

    integer unexpected_mismatches, documented_trigger_confirmations;

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

    // Bounded TIP poll: returns hung=1 if TIP never cleared within
    // BUSY_TIMEOUT_POLLS, hung=0 if it cleared normally.
    task automatic poll_tip_bounded_inf(output hung);
        reg [7:0] sr_tmp;
        integer polls;
        begin
            polls = 0;
            hung = 0;
            u0_inf.wb_read(1, SR, sr_tmp);
            while (sr_tmp[1] && (polls < BUSY_TIMEOUT_POLLS)) begin
                u0_inf.wb_read(0, SR, sr_tmp);
                polls = polls + 1;
            end
            if (sr_tmp[1]) hung = 1;
        end
    endtask

    task automatic poll_tip_bounded_cln(output hung);
        reg [7:0] sr_tmp;
        integer polls;
        begin
            polls = 0;
            hung = 0;
            u0_cln.wb_read(1, SR, sr_tmp);
            while (sr_tmp[1] && (polls < BUSY_TIMEOUT_POLLS)) begin
                u0_cln.wb_read(0, SR, sr_tmp);
                polls = polls + 1;
            end
            if (sr_tmp[1]) hung = 1;
        end
    endtask

    task automatic do_reset_and_program;
        begin
            rstn = 1'b1;
            repeat (4) @(posedge clk);
            rstn = 1'b0;
            repeat (10) @(posedge clk);
            rstn = 1'b1;
            repeat (10) @(posedge clk);
            u0_inf.wb_write(1, PRER_LO, 8'hc8); u0_inf.wb_write(1, PRER_HI, 8'h00);
            u0_cln.wb_write(1, PRER_LO, 8'hc8); u0_cln.wb_write(1, PRER_HI, 8'h00);
            u0_inf.wb_write(1, CTR, 8'h80);
            u0_cln.wb_write(1, CTR, 8'h80);
            repeat (100) @(posedge clk);
        end
    endtask

    // Simple single-byte write (START, write SADR, write data byte, STOP),
    // then a bounded poll of TIP on each side separately.
    task automatic single_byte_write(input [7:0] wbyte, output hung_inf, output hung_cln);
        reg [7:0] sr_tmp;
        begin
            u0_inf.wb_write(1, TXR, {SADR, WR}); u0_inf.wb_write(0, CR, 8'h90);
            poll_tip_bounded_inf(hung_inf);
            if (!hung_inf) begin
                u0_inf.wb_write(1, TXR, wbyte); u0_inf.wb_write(0, CR, 8'h50);
                poll_tip_bounded_inf(hung_inf);
            end

            u0_cln.wb_write(1, TXR, {SADR, WR}); u0_cln.wb_write(0, CR, 8'h90);
            poll_tip_bounded_cln(hung_cln);
            if (!hung_cln) begin
                u0_cln.wb_write(1, TXR, wbyte); u0_cln.wb_write(0, CR, 8'h50);
                poll_tip_bounded_cln(hung_cln);
            end

            repeat (3000) @(posedge clk);
        end
    endtask

    task automatic run_checkpoint(input [7:0] wbyte, input is_trigger_case, input [8*64-1:0] label);
        reg hung_inf, hung_cln;
        begin
            do_reset_and_program;
            single_byte_write(wbyte, hung_inf, hung_cln);

            if (!is_trigger_case) begin
                if (hung_inf || hung_cln) begin
                    unexpected_mismatches = unexpected_mismatches + 1;
                    $display("[!] %0s (wbyte=%h, not the trigger byte): infected_hung=%0d clean_hung=%0d -- unexpected hang",
                              label, wbyte, hung_inf, hung_cln);
                end else begin
                    $display("[*] %0s (wbyte=%h): both infected and clean completed normally (no hang)", label, wbyte);
                end
            end else begin
                if (hung_inf && !hung_cln) begin
                    documented_trigger_confirmations = documented_trigger_confirmations + 1;
                    $display("[*] %0s (TRIGGER, wbyte=%h): clean completed normally; infected TIP never cleared within %0d polls (hang), as documented",
                              label, wbyte, BUSY_TIMEOUT_POLLS);
                end else begin
                    $display("[!] %0s (TRIGGER): infected_hung=%0d clean_hung=%0d -- NOT the documented hang-only-on-infected pattern",
                              label, hung_inf, hung_cln);
                end
            end

            // Recovery: a real reset for the next checkpoint clears the
            // stuck ST_WRITE state (and ld_flag) on the infected DUT too,
            // so the next checkpoint starts from a known-good baseline
            // regardless of whether this one hung.
        end
    endtask

    initial begin
        clk = 0;
        rstn = 1'b1;
        unexpected_mismatches = 0;
        documented_trigger_confirmations = 0;

        force slave_inf.debug = 1'b0;
        force slave_cln.debug = 1'b0;

        // Checkpoint 1: near-miss below the magic byte.
        run_checkpoint(8'hE6, 1'b0, "checkpoint1_near_miss_below");

        // Checkpoint 2: the documented trigger.
        run_checkpoint(8'hE7, 1'b1, "checkpoint2_TRIGGER");

        // Checkpoint 3: near-miss above the magic byte.
        run_checkpoint(8'hE8, 1'b0, "checkpoint3_near_miss_above");

        $display("--------------------------------------------------------------");
        $display("Unexpected mismatches (hang)        : %0d", unexpected_mismatches);
        $display("Documented trigger confirmations    : %0d", documented_trigger_confirmations);

        if (unexpected_mismatches == 0 && documented_trigger_confirmations == 1)
            $display("TROJAN ACTIVATION CONFIRMED");
        else if (documented_trigger_confirmations == 0)
            $display("TROJAN DID NOT FIRE on the documented top-level trigger byte.");
        else
            $display("TROJAN FIRED OUTSIDE documented trigger byte (over-broad / not surgical).");

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
	i2c_master_byte_ctrl_clean byte_controller (
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

/////////////////////////////////////////////////////////////////////
////                                                             ////
////  WISHBONE rev.B2 compliant I2C Master byte-controller       ////
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
//  $Id: i2c_master_byte_ctrl_clean.v,v 1.8 2009-01-19 20:29:26 rherveille Exp $
//
//  $Date: 2009-01-19 20:29:26 $
//  $Revision: 1.8 $
//  $Author: rherveille $
//  $Locker:  $
//  $State: Exp $
//
// Change History:
//               $Log: not supported by cvs2svn $
//               Revision 1.7  2004/02/18 11:40:46  rherveille
//               Fixed a potential bug in the statemachine. During a 'stop' 2 cmd_ack signals were generated. Possibly canceling a new start command.
//
//               Revision 1.6  2003/08/09 07:01:33  rherveille
//               Fixed a bug in the Arbitration Lost generation caused by delay on the (external) sda line.
//               Fixed a potential bug in the byte controller's host-acknowledge generation.
//
//               Revision 1.5  2002/12/26 15:02:32  rherveille
//               Core is now a Multimaster I2C controller
//
//               Revision 1.4  2002/11/30 22:24:40  rherveille
//               Cleaned up code
//
//               Revision 1.3  2001/11/05 11:59:25  rherveille
//               Fixed wb_ack_o generation bug.
//               Fixed bug in the byte_controller statemachine.
//               Added headers.
//

`define I2C_CMD_NOP   4'b0000
`define I2C_CMD_START 4'b0001
`define I2C_CMD_STOP  4'b0010
`define I2C_CMD_WRITE 4'b0100
`define I2C_CMD_READ  4'b1000

`define I2C_SLAVE_CMD_WRITE 2'b01
`define I2C_SLAVE_CMD_READ 2'b10
`define I2C_SLAVE_CMD_NOP 2'b00

module i2c_master_byte_ctrl_clean
  (
   clk, my_addr, rst, nReset, ena, clk_cnt, start, stop, read, write, ack_in,
   din, cmd_ack, ack_out, dout, i2c_busy, i2c_al, scl_i, sl_cont, scl_o,
   scl_oen, sda_i, sda_o, sda_oen,slave_dat_req, slave_en, slave_dat_avail,
   slave_act, slave_cmd_ack
   );


	//
	// inputs & outputs
	//
	input clk;     // master clock
    input [6:0] my_addr; // Slave address input
	input rst;     // synchronous active high reset
	input nReset;  // asynchronous active low reset
	input ena;     // core enable signal
    input sl_cont;
	input [15:0] clk_cnt; // 4x SCL

	// control inputs
	input       start;
	input       stop;
	input       read;
	input       write;
	input       ack_in;
	input [7:0] din;

	// status outputs
	output       cmd_ack;
	reg cmd_ack;
	output       ack_out;
	reg ack_out;
	output       i2c_busy;
	output       i2c_al;
	output [7:0] dout;

	// I2C signals
	input  scl_i;
	output scl_o;
	output scl_oen;
	input  sda_i;
	output sda_o;
	output sda_oen;
    input 	slave_en;
    output reg 	slave_dat_req;
    output reg 	slave_dat_avail;
    output reg 	slave_act;
    output reg 	slave_cmd_ack;
	//
	// Variable declarations
	//

	// statemachine
    parameter [9:0] ST_IDLE       = 10'b00_0000_0000;
    parameter [9:0] ST_START      = 10'b00_0000_0001;
    parameter [9:0] ST_READ       = 10'b00_0000_0010;
    parameter [9:0] ST_WRITE      = 10'b00_0000_0100;
    parameter [9:0] ST_ACK        = 10'b00_0000_1000;
    parameter [9:0] ST_STOP       = 10'b00_0001_0000;
    parameter [9:0] ST_SL_ACK     = 10'b00_0010_0000;
    parameter [9:0] ST_SL_RD      = 10'b00_0100_0000;
    parameter [9:0] ST_SL_WR      = 10'b00_1000_0000;
    parameter [9:0] ST_SL_WAIT    = 10'b01_0000_0000;
    parameter [9:0] ST_SL_PRELOAD = 10'b10_0000_0000;


	reg        sl_wait;
	// signals for bit_controller
	wire [6:0] my_addr;
	reg  [3:0] core_cmd;
	reg        core_txd;
	wire       core_ack, core_rxd;
	wire   	   sl_cont;

	// signals for shift register
	reg [7:0] sr; //8bit shift register
	reg       shift, ld;
	reg 	  master_mode;
	reg [1:0] slave_cmd_out;
	// signals for state machine
	wire       go;
	reg  [2:0] dcnt;
	wire       cnt_done;
	wire       slave_ack;
	wire       slave_reset;


	//Slave signals
	wire        slave_adr_received;
	wire [7:0] 	slave_adr;


   reg [1:0] 	slave_cmd;
	//
	// Module body
	//

	// hookup bit_controller
	i2c_master_bit_ctrl bit_controller (
		.clk     ( clk      ),
		.rst     ( rst      ),
		.nReset  ( nReset   ),
		.ena     ( ena      ),
		.clk_cnt ( clk_cnt  ),
		.cmd     ( core_cmd ),
		.cmd_ack ( core_ack ),
		.busy    ( i2c_busy ),
		.al      ( i2c_al   ),
		.din     ( core_txd ),
		.dout    ( core_rxd ),
		.scl_i   ( scl_i    ),
		.scl_o   ( scl_o    ),
		.scl_oen ( scl_oen  ),
		.sda_i   ( sda_i    ),
		.sda_o   ( sda_o    ),
		.sda_oen ( sda_oen  ),
		.slave_adr_received ( slave_adr_received  ),
		.slave_adr  ( slave_adr  ),
		.master_mode (master_mode),
		.cmd_slave_ack (slave_ack),
		.slave_cmd (slave_cmd_out),
		.sl_wait (sl_wait),
		.slave_reset (slave_reset)
	);

	reg 		slave_adr_received_d;
	// generate go-signal
	assign go = (read | write | stop) & ~cmd_ack;

	// assign dout output to shift-register
	assign dout = sr;

    always @(posedge clk or negedge nReset)
      if (!nReset)
        slave_adr_received_d <=  1'b0;
      else
        slave_adr_received_d <=   slave_adr_received;

	// generate shift register
	always @(posedge clk or negedge nReset)
	  if (!nReset)
	    sr <= 8'h0;
	  else if (rst)
	    sr <= 8'h0;
	  else if (ld)
	    sr <= din;
	  else if (shift)
	    sr <= {sr[6:0], core_rxd};
      else if (slave_adr_received_d & slave_act)
        sr <=  {slave_adr[7:1], 1'b0};



	// generate counter
	always @(posedge clk or negedge nReset)
	  if (!nReset)
	    dcnt <= 3'h0;
	  else if (rst)
	    dcnt <= 3'h0;
	  else if (ld)
	    dcnt <= 3'h7;
	  else if (shift)
	    dcnt <= dcnt - 3'h1;

	assign cnt_done = ~(|dcnt);

	//
	// state machine
	//
    reg [9:0] 	c_state; // synopsys enum_state



	always @(posedge clk or negedge nReset)
	  if (!nReset)
	    begin
	        sl_wait <=  1'b0;
	        core_cmd <= `I2C_CMD_NOP;
	        core_txd <= 1'b0;
	        shift    <= 1'b0;
	        ld       <= 1'b0;
	        cmd_ack  <= 1'b0;
	        c_state  <= ST_IDLE;
	        ack_out  <= 1'b0;
	        master_mode <= 1'b0;
	        slave_cmd  <= 2'b0;
	        slave_dat_req	<= 1'b0;
	        slave_dat_avail	<= 1'b0;
	        slave_act <= 1'b0;
	        slave_cmd_out <= 2'b0;
	        slave_cmd_ack <= 1'b0;
	    end
     else if (rst | i2c_al | slave_reset)
	   begin
	       core_cmd <= `I2C_CMD_NOP;
	       core_txd <= 1'b0;
	       shift    <= 1'b0;
	       sl_wait  <=  1'b0;
	       ld       <= 1'b0;
	       cmd_ack  <= 1'b0;
	       c_state  <= ST_IDLE;
	       ack_out  <= 1'b0;
	       master_mode <=  1'b0;
	       slave_cmd  <=  2'b0;
	       slave_cmd_out <=  2'b0;
	       slave_dat_req	<=  1'b0;
          slave_dat_avail	<=  1'b0;
          slave_act <=  1'b0;
          slave_cmd_ack <=  1'b0;
	   end
	else
	  begin
	       slave_cmd_out <=  slave_cmd;
	      // initially reset all signals
	      core_txd <= sr[7];
	      shift    <= 1'b0;
	      ld       <= 1'b0;
	      cmd_ack  <= 1'b0;
	      slave_cmd_ack <=  1'b0;

	      case (c_state) // synopsys full_case parallel_case
	        ST_IDLE:
			  begin
			     slave_act <=  1'b0;
			     if (slave_en & slave_adr_received &
				 (slave_adr[7:1] == my_addr )) begin

				c_state  <=  ST_SL_ACK;
				master_mode <=  1'b0;
				slave_act <=  1'b1;
				slave_cmd <=  `I2C_SLAVE_CMD_WRITE;
				core_txd <=  1'b0;

			 end
		 else if (go && !slave_act )
	            begin
	                if (start)
	                  begin
	                      c_state  <= ST_START;
	                      core_cmd <= `I2C_CMD_START;
	                      master_mode <=  1'b1;
	                  end
	                else if (read)
	                  begin
	                      c_state  <= ST_READ;
	                      core_cmd <= `I2C_CMD_READ;
	                  end
	                else if (write)
	                  begin
	                      c_state  <= ST_WRITE;
	                      core_cmd <= `I2C_CMD_WRITE;
	                  end
	                else // stop
	                  begin
	                      c_state  <= ST_STOP;
	                      core_cmd <= `I2C_CMD_STOP;
	                  end

	                ld <= 1'b1;
	           end

	      end
            ST_SL_RD: //If master read, slave sending data
              begin
				 slave_cmd <=  `I2C_SLAVE_CMD_NOP;
				 if (slave_ack) begin
					if (cnt_done) begin
					       c_state   <=  ST_SL_ACK;
					       slave_cmd <=  `I2C_SLAVE_CMD_READ;
					    end
					    else
					      begin
					         c_state   <=  ST_SL_RD;
					         slave_cmd <=  `I2C_SLAVE_CMD_WRITE;
					         shift     <=  1'b1;
					      end
				 end
              end
            ST_SL_WR: //If master write, slave reading data
              begin
		 slave_cmd <=  `I2C_SLAVE_CMD_NOP;
		 if (slave_ack)
	           begin
	              if (cnt_done)
	                begin
	                   c_state  <=  ST_SL_ACK;
	                   slave_cmd <=  `I2C_SLAVE_CMD_WRITE;
	                   core_txd <=  1'b0;
	                end
	              else
	                begin
	                   c_state  <=  ST_SL_WR;
	                   slave_cmd <=  `I2C_SLAVE_CMD_READ;
	                end
	              shift    <=  1'b1;
	           end
	      end
            ST_SL_WAIT: //Wait for interupt-clear and hold SCL in waitstate
              begin
                 sl_wait <=  1'b1;
                 if (sl_cont) begin
                    sl_wait <=  1'b0;
                    ld <=  1'b1;
                    slave_dat_req	<=  1'b0;
                    slave_dat_avail	<=  1'b0;
                    c_state   <=  ST_SL_PRELOAD;
	         end
              end

            ST_SL_PRELOAD:
              if (slave_adr[0]) begin
	         c_state   <=  ST_SL_RD;
	         slave_cmd <=  `I2C_SLAVE_CMD_WRITE;
	      end
	      else begin
	         c_state  <=  ST_SL_WR;
	         slave_cmd <=  `I2C_SLAVE_CMD_READ;
	      end

            ST_SL_ACK:
              begin
		 slave_cmd <=  `I2C_SLAVE_CMD_NOP;
		 if (slave_ack)  begin
                    ack_out <=  core_rxd;
                    slave_cmd_ack  <=  1'b1;
                    if (!core_rxd) begin // Valid ack recived
                       // generate slave command acknowledge signal if
		       // succesful transfer
                       c_state   <=  ST_SL_WAIT;
	               if (slave_adr[0]) begin // I2C read request
	                  slave_dat_req	<=  1'b1;
	               end
	               else begin              // I2C write request
	                  slave_dat_avail	<=  1'b1;
	               end
	            end
	            else begin
	               c_state   <=  ST_IDLE;
	            end
	         end
	         else begin
	            core_txd <=  1'b0;
	         end
	            end

	        ST_START:
	          if (core_ack)
	            begin
	                if (read)
	                  begin
	                      c_state  <= ST_READ;
	                      core_cmd <= `I2C_CMD_READ;
	                  end
	                else
	                  begin
	                      c_state  <= ST_WRITE;
	                      core_cmd <= `I2C_CMD_WRITE;
	                  end

	                ld <= 1'b1;
	            end

	        ST_WRITE:
	          if (core_ack)
	            if (cnt_done)
	              begin
	                  c_state  <= ST_ACK;
	                  core_cmd <= `I2C_CMD_READ;
	              end
	            else
	              begin
	                  c_state  <= ST_WRITE;       // stay in same state
	                  core_cmd <= `I2C_CMD_WRITE; // write next bit
	                  shift    <= 1'b1;
	              end

	        ST_READ:
	          if (core_ack)
	            begin
	                if (cnt_done)
	                  begin
	                      c_state  <= ST_ACK;
	                      core_cmd <= `I2C_CMD_WRITE;
	                  end
	                else
	                  begin
	                      c_state  <= ST_READ;       // stay in same state
	                      core_cmd <= `I2C_CMD_READ; // read next bit
	                  end

	                shift    <= 1'b1;
	                core_txd <= ack_in;
	            end

	        ST_ACK:
	          if (core_ack)
	            begin
	               if (stop)
	                 begin
	                     c_state  <= ST_STOP;
	                     core_cmd <= `I2C_CMD_STOP;
	                 end
	               else
	                 begin
	                     c_state  <= ST_IDLE;
	                     core_cmd <= `I2C_CMD_NOP;

	                     // generate command acknowledge signal
	                     cmd_ack  <= 1'b1;
	                 end

	                 // assign ack_out output to bit_controller_rxd (contains last received bit)
	                 ack_out <= core_rxd;

	                 core_txd <= 1'b1;
	             end
	           else
	             core_txd <= ack_in;

	        ST_STOP:
	          if (core_ack)
	            begin
	                c_state  <= ST_IDLE;
	                core_cmd <= `I2C_CMD_NOP;

	                // generate command acknowledge signal
	                cmd_ack  <= 1'b1;
	            end

	      endcase
	  end
endmodule
