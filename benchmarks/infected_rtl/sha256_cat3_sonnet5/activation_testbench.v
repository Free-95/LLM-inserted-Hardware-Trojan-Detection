`timescale 1ns / 1ps

module tb_eval2_activation;

    localparam CLK_HALF_PERIOD = 2;
    localparam READY_TIMEOUT_CYCLES = 2000;

    reg clk;
    reg reset_n;
    reg tb_init, tb_next, tb_mode;
    reg [511:0] tb_block;

    wire ready_infected;
    wire [255:0] digest_infected;
    wire digest_valid_infected;

    wire ready_clean;
    wire [255:0] digest_clean;
    wire digest_valid_clean;

    integer mismatch_count;
    integer ordinary_mismatch_seen;
    integer trigger_mismatch_seen;

    sha256_core dut_infected (
        .clk(clk), .reset_n(reset_n),
        .init(tb_init), .next(tb_next), .mode(tb_mode),
        .block(tb_block),
        .ready(ready_infected), .digest(digest_infected), .digest_valid(digest_valid_infected)
    );

    sha256_core_clean dut_clean (
        .clk(clk), .reset_n(reset_n),
        .init(tb_init), .next(tb_next), .mode(tb_mode),
        .block(tb_block),
        .ready(ready_clean), .digest(digest_clean), .digest_valid(digest_valid_clean)
    );

    always #(CLK_HALF_PERIOD) clk = ~clk;

    integer wait_cycles;
    reg timed_out;

    task automatic wait_for_block_done;
        begin
            timed_out = 0;
            wait_cycles = 0;
            while (ready_infected && ready_clean && wait_cycles < 10) begin
                @(posedge clk);
                wait_cycles = wait_cycles + 1;
            end
            if (ready_infected || ready_clean) begin
                timed_out = 1;
            end
            if (!timed_out) begin
                wait_cycles = 0;
                while ((!ready_infected || !ready_clean) && !timed_out) begin
                    @(posedge clk);
                    wait_cycles = wait_cycles + 1;
                    if (wait_cycles > READY_TIMEOUT_CYCLES)
                        timed_out = 1;
                end
            end
        end
    endtask

    task automatic run_block(
        input [511:0] blk,
        input [8*64-1:0] label,
        input is_trigger_vector
    );
        begin
            tb_block = blk;
            tb_init = 1;
            tb_next = 0;
            @(posedge clk);
            tb_init = 0;
            tb_next = 0;

            wait_for_block_done();

            if (timed_out) begin
                $display("[FAIL] %0s: timeout waiting for ready (possible hang on one side).", label);
                mismatch_count = mismatch_count + 1;
            end else begin
                if (digest_infected !== digest_clean) begin
                    if (is_trigger_vector) begin
                        trigger_mismatch_seen = 1;
                        $display("[*] %0s: digests DIFFER as expected (trigger vector).", label);
                    end else begin
                        ordinary_mismatch_seen = 1;
                        mismatch_count = mismatch_count + 1;
                        $display("[FAIL] %0s: ordinary (non-trigger) vector unexpectedly DIFFERED.", label);
                        $display("        infected=0x%064x", digest_infected);
                        $display("        clean   =0x%064x", digest_clean);
                    end
                end else begin
                    if (is_trigger_vector) begin
                        $display("[FAIL] %0s: trigger vector did NOT produce any digest difference.", label);
                    end else begin
                        $display("[*] %0s: digests MATCH as expected (ordinary vector).", label);
                    end
                end
                if ((digest_valid_infected !== 1'b1) || (digest_valid_clean !== 1'b1)) begin
                    $display("[FAIL] %0s: digest_valid did not assert on both sides after ready reasserted.", label);
                    mismatch_count = mismatch_count + 1;
                end
            end
        end
    endtask

    initial begin
        mismatch_count = 0;
        ordinary_mismatch_seen = 0;
        trigger_mismatch_seen = 0;

        clk = 0;
        reset_n = 0;
        tb_init = 0; tb_next = 0; tb_mode = 1; tb_block = 512'h0;
        repeat (4) @(posedge clk);
        reset_n = 1;
        repeat (2) @(posedge clk);

        // ------------------------------------------------------------
        // (a) Ordinary, non-triggering single-block messages: the real
        // NIST "abc" block, plus two deliberate near-misses that share
        // every bit of the magic word except for small differences, to
        // confirm the match really is an exact 32-bit equality at the
        // exact word position (bits [63:32]) documented, not a wider,
        // narrower, or misaligned comparison.
        // ------------------------------------------------------------
        run_block(512'h61626380000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000018,
                   "ordinary_abc_block", 1'b0);

        run_block(512'h1122334411223344112233441122334411223344112233441122334411223344112233441122334411223344112233441122334411223344c0ffeebf11223344,
                   "near_miss_off_by_one_bit", 1'b0);

        run_block(512'h11223344112233441122334411223344112233441122334411223344112233441122334411223344112233441122334411223344c0ffeebe1122334411223344,
                   "near_miss_right_bytes_wrong_alignment", 1'b0);

        // ------------------------------------------------------------
        // (b) Documented trigger: the block's word at bits [63:32]
        // (word index 14 of 16) equals exactly 32'hc0ffeebe. Every other
        // word of the block is ordinary, non-degenerate filler.
        // ------------------------------------------------------------
        run_block(512'h1122334411223344112233441122334411223344112233441122334411223344112233441122334411223344112233441122334411223344c0ffeebe11223344,
                   "trigger_vector", 1'b1);

        // Confirm the design returns to matching behavior on the very
        // next block once the trigger word is no longer present (no
        // latch-up / persistent corruption) -- this is a purely
        // combinational per-block trigger with no state carried over.
        // This reuses the second real NIST test block ("abcdbcde...") from
        // this design's own golden vector set.
        run_block(512'h6162636462636465636465666465666765666768666768696768696a68696a6b696a6b6c6a6b6c6d6b6c6d6e6c6d6e6f6d6e6f706e6f70718000000000000000,
                   "ordinary_after_trigger", 1'b0);

        #50;
        if ((mismatch_count == 0) && (ordinary_mismatch_seen == 0) && (trigger_mismatch_seen == 1)) begin
            $display("TROJAN ACTIVATION CONFIRMED");
        end else begin
            $display("[-] Activation check FAILED: mismatch_count=%0d ordinary_mismatch_seen=%0d trigger_mismatch_seen=%0d",
                      mismatch_count, ordinary_mismatch_seen, trigger_mismatch_seen);
        end
        $finish;
    end

    initial begin
        #200000;
        $display("[-] GLOBAL TIMEOUT");
        $finish;
    end

endmodule

// === embedded clean sha256_core hierarchy (verbatim, _clean-suffixed) ===
//======================================================================
//
// sha256_core.v
// -------------
// Verilog 2001 implementation of the SHA-256 hash function.
// This is the internal core with wide interfaces.
//
//
// Author: Joachim Strombergson
// Copyright (c) 2013, Secworks Sweden AB
// All rights reserved.
//
// Redistribution and use in source and binary forms, with or
// without modification, are permitted provided that the following
// conditions are met:
//
// 1. Redistributions of source code must retain the above copyright
//    notice, this list of conditions and the following disclaimer.
//
// 2. Redistributions in binary form must reproduce the above copyright
//    notice, this list of conditions and the following disclaimer in
//    the documentation and/or other materials provided with the
//    distribution.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
// "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
// LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
// FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
// COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
// INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
// BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
// LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
// CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
// STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
// ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//
//======================================================================

`default_nettype none

module sha256_core_clean(
                   input wire            clk,
                   input wire            reset_n,

                   input wire            init,
                   input wire            next,
                   input wire            mode,

                   input wire [511 : 0]  block,

                   output wire           ready,
                   output wire [255 : 0] digest,
                   output wire           digest_valid
                  );


  //----------------------------------------------------------------
  // Internal constant and parameter definitions.
  //----------------------------------------------------------------
  localparam SHA224_H0_0 = 32'hc1059ed8;
  localparam SHA224_H0_1 = 32'h367cd507;
  localparam SHA224_H0_2 = 32'h3070dd17;
  localparam SHA224_H0_3 = 32'hf70e5939;
  localparam SHA224_H0_4 = 32'hffc00b31;
  localparam SHA224_H0_5 = 32'h68581511;
  localparam SHA224_H0_6 = 32'h64f98fa7;
  localparam SHA224_H0_7 = 32'hbefa4fa4;

  localparam SHA256_H0_0 = 32'h6a09e667;
  localparam SHA256_H0_1 = 32'hbb67ae85;
  localparam SHA256_H0_2 = 32'h3c6ef372;
  localparam SHA256_H0_3 = 32'ha54ff53a;
  localparam SHA256_H0_4 = 32'h510e527f;
  localparam SHA256_H0_5 = 32'h9b05688c;
  localparam SHA256_H0_6 = 32'h1f83d9ab;
  localparam SHA256_H0_7 = 32'h5be0cd19;

  localparam SHA256_ROUNDS = 63;

  localparam CTRL_IDLE   = 0;
  localparam CTRL_ROUNDS = 1;
  localparam CTRL_DONE   = 2;


  //----------------------------------------------------------------
  // Registers including update variables and write enable.
  //----------------------------------------------------------------
  reg [31 : 0] a_reg;
  reg [31 : 0] a_new;
  reg [31 : 0] b_reg;
  reg [31 : 0] b_new;
  reg [31 : 0] c_reg;
  reg [31 : 0] c_new;
  reg [31 : 0] d_reg;
  reg [31 : 0] d_new;
  reg [31 : 0] e_reg;
  reg [31 : 0] e_new;
  reg [31 : 0] f_reg;
  reg [31 : 0] f_new;
  reg [31 : 0] g_reg;
  reg [31 : 0] g_new;
  reg [31 : 0] h_reg;
  reg [31 : 0] h_new;
  reg          a_h_we;

  reg [31 : 0] H0_reg;
  reg [31 : 0] H0_new;
  reg [31 : 0] H1_reg;
  reg [31 : 0] H1_new;
  reg [31 : 0] H2_reg;
  reg [31 : 0] H2_new;
  reg [31 : 0] H3_reg;
  reg [31 : 0] H3_new;
  reg [31 : 0] H4_reg;
  reg [31 : 0] H4_new;
  reg [31 : 0] H5_reg;
  reg [31 : 0] H5_new;
  reg [31 : 0] H6_reg;
  reg [31 : 0] H6_new;
  reg [31 : 0] H7_reg;
  reg [31 : 0] H7_new;
  reg          H_we;

  reg [5 : 0] t_ctr_reg;
  reg [5 : 0] t_ctr_new;
  reg         t_ctr_we;
  reg         t_ctr_inc;
  reg         t_ctr_rst;

  reg digest_valid_reg;
  reg digest_valid_new;
  reg digest_valid_we;

  reg [1 : 0] sha256_ctrl_reg;
  reg [1 : 0] sha256_ctrl_new;
  reg         sha256_ctrl_we;


  //----------------------------------------------------------------
  // Wires.
  //----------------------------------------------------------------
  reg digest_init;
  reg digest_update;

  reg state_init;
  reg state_update;

  reg first_block;

  reg ready_flag;

  reg [31 : 0] t1;
  reg [31 : 0] t2;

  wire [31 : 0] k_data;

  reg           w_init;
  reg           w_next;
  reg [5 : 0]   w_round;
  wire [31 : 0] w_data;


  //----------------------------------------------------------------
  // Module instantiantions.
  //----------------------------------------------------------------
  sha256_k_constants k_constants_inst_clean(
                                      .round(t_ctr_reg),
                                      .K(k_data)
                                     );


  sha256_w_mem w_mem_inst_clean(
                          .clk(clk),
                          .reset_n(reset_n),

                          .block(block),
                          .round(t_ctr_reg),

                          .init(w_init),
                          .next(w_next),
                          .w(w_data)
                         );


  //----------------------------------------------------------------
  // Concurrent connectivity for ports etc.
  //----------------------------------------------------------------
  assign ready = ready_flag;

  assign digest = {H0_reg, H1_reg, H2_reg, H3_reg,
                   H4_reg, H5_reg, H6_reg, H7_reg};

  assign digest_valid = digest_valid_reg;


  //----------------------------------------------------------------
  // reg_update
  // Update functionality for all registers in the core.
  // All registers are positive edge triggered with asynchronous
  // active low reset. All registers have write enable.
  //----------------------------------------------------------------
  always @ (posedge clk or negedge reset_n)
    begin : reg_update
      if (!reset_n)
        begin
          a_reg            <= 32'h0;
          b_reg            <= 32'h0;
          c_reg            <= 32'h0;
          d_reg            <= 32'h0;
          e_reg            <= 32'h0;
          f_reg            <= 32'h0;
          g_reg            <= 32'h0;
          h_reg            <= 32'h0;
          H0_reg           <= 32'h0;
          H1_reg           <= 32'h0;
          H2_reg           <= 32'h0;
          H3_reg           <= 32'h0;
          H4_reg           <= 32'h0;
          H5_reg           <= 32'h0;
          H6_reg           <= 32'h0;
          H7_reg           <= 32'h0;
          digest_valid_reg <= 0;
          t_ctr_reg        <= 6'h0;
          sha256_ctrl_reg  <= CTRL_IDLE;
        end
      else
        begin

          if (a_h_we)
            begin
              a_reg <= a_new;
              b_reg <= b_new;
              c_reg <= c_new;
              d_reg <= d_new;
              e_reg <= e_new;
              f_reg <= f_new;
              g_reg <= g_new;
              h_reg <= h_new;
            end

          if (H_we)
            begin
              H0_reg <= H0_new;
              H1_reg <= H1_new;
              H2_reg <= H2_new;
              H3_reg <= H3_new;
              H4_reg <= H4_new;
              H5_reg <= H5_new;
              H6_reg <= H6_new;
              H7_reg <= H7_new;
            end

          if (t_ctr_we)
            t_ctr_reg <= t_ctr_new;

          if (digest_valid_we)
            digest_valid_reg <= digest_valid_new;

          if (sha256_ctrl_we)
            sha256_ctrl_reg <= sha256_ctrl_new;
        end
    end // reg_update


  //----------------------------------------------------------------
  // digest_logic
  //
  // The logic needed to init as well as update the digest.
  //----------------------------------------------------------------
  always @*
    begin : digest_logic
      H0_new = 32'h0;
      H1_new = 32'h0;
      H2_new = 32'h0;
      H3_new = 32'h0;
      H4_new = 32'h0;
      H5_new = 32'h0;
      H6_new = 32'h0;
      H7_new = 32'h0;
      H_we = 0;

      if (digest_init)
        begin
          H_we = 1;
          if (mode)
            begin
              H0_new = SHA256_H0_0;
              H1_new = SHA256_H0_1;
              H2_new = SHA256_H0_2;
              H3_new = SHA256_H0_3;
              H4_new = SHA256_H0_4;
              H5_new = SHA256_H0_5;
              H6_new = SHA256_H0_6;
              H7_new = SHA256_H0_7;
            end
          else
            begin
              H0_new = SHA224_H0_0;
              H1_new = SHA224_H0_1;
              H2_new = SHA224_H0_2;
              H3_new = SHA224_H0_3;
              H4_new = SHA224_H0_4;
              H5_new = SHA224_H0_5;
              H6_new = SHA224_H0_6;
              H7_new = SHA224_H0_7;
            end
        end

      if (digest_update)
        begin
          H0_new = H0_reg + a_reg;
          H1_new = H1_reg + b_reg;
          H2_new = H2_reg + c_reg;
          H3_new = H3_reg + d_reg;
          H4_new = H4_reg + e_reg;
          H5_new = H5_reg + f_reg;
          H6_new = H6_reg + g_reg;
          H7_new = H7_reg + h_reg;
          H_we = 1;
        end
    end // digest_logic


  //----------------------------------------------------------------
  // t1_logic
  //
  // The logic for the T1 function.
  //----------------------------------------------------------------
  always @*
    begin : t1_logic
      reg [31 : 0] sum1;
      reg [31 : 0] ch;

      sum1 = {e_reg[5  : 0], e_reg[31 :  6]} ^
             {e_reg[10 : 0], e_reg[31 : 11]} ^
             {e_reg[24 : 0], e_reg[31 : 25]};

      ch = (e_reg & f_reg) ^ ((~e_reg) & g_reg);

      t1 = h_reg + sum1 + ch + w_data + k_data;
    end // t1_logic


  //----------------------------------------------------------------
  // t2_logic
  //
  // The logic for the T2 function
  //----------------------------------------------------------------
  always @*
    begin : t2_logic
      reg [31 : 0] sum0;
      reg [31 : 0] maj;

      sum0 = {a_reg[1  : 0], a_reg[31 :  2]} ^
             {a_reg[12 : 0], a_reg[31 : 13]} ^
             {a_reg[21 : 0], a_reg[31 : 22]};

      maj = (a_reg & b_reg) ^ (a_reg & c_reg) ^ (b_reg & c_reg);

      t2 = sum0 + maj;
    end // t2_logic


  //----------------------------------------------------------------
  // state_logic
  //
  // The logic needed to init as well as update the state during
  // round processing.
  //----------------------------------------------------------------
  always @*
    begin : state_logic
      a_new  = 32'h0;
      b_new  = 32'h0;
      c_new  = 32'h0;
      d_new  = 32'h0;
      e_new  = 32'h0;
      f_new  = 32'h0;
      g_new  = 32'h0;
      h_new  = 32'h0;
      a_h_we = 0;

      if (state_init)
        begin
          a_h_we = 1;
          if (first_block)
            begin
              if (mode)
                begin
                  a_new  = SHA256_H0_0;
                  b_new  = SHA256_H0_1;
                  c_new  = SHA256_H0_2;
                  d_new  = SHA256_H0_3;
                  e_new  = SHA256_H0_4;
                  f_new  = SHA256_H0_5;
                  g_new  = SHA256_H0_6;
                  h_new  = SHA256_H0_7;
                end
              else
                begin
                  a_new  = SHA224_H0_0;
                  b_new  = SHA224_H0_1;
                  c_new  = SHA224_H0_2;
                  d_new  = SHA224_H0_3;
                  e_new  = SHA224_H0_4;
                  f_new  = SHA224_H0_5;
                  g_new  = SHA224_H0_6;
                  h_new  = SHA224_H0_7;
                end
            end
          else
            begin
              a_new  = H0_reg;
              b_new  = H1_reg;
              c_new  = H2_reg;
              d_new  = H3_reg;
              e_new  = H4_reg;
              f_new  = H5_reg;
              g_new  = H6_reg;
              h_new  = H7_reg;
            end
        end

      if (state_update)
        begin
          a_new  = t1 + t2;
          b_new  = a_reg;
          c_new  = b_reg;
          d_new  = c_reg;
          e_new  = d_reg + t1;
          f_new  = e_reg;
          g_new  = f_reg;
          h_new  = g_reg;
          a_h_we = 1;
        end
    end // state_logic


  //----------------------------------------------------------------
  // t_ctr
  //
  // Update logic for the round counter, a monotonically
  // increasing counter with reset.
  //----------------------------------------------------------------
  always @*
    begin : t_ctr
      t_ctr_new = 0;
      t_ctr_we  = 0;

      if (t_ctr_rst)
        begin
          t_ctr_new = 0;
          t_ctr_we  = 1;
        end

      if (t_ctr_inc)
        begin
          t_ctr_new = t_ctr_reg + 1'b1;
          t_ctr_we  = 1;
        end
    end // t_ctr


  //----------------------------------------------------------------
  // sha256_ctrl_fsm
  //
  // Logic for the state machine controlling the core behaviour.
  //----------------------------------------------------------------
  always @*
    begin : sha256_ctrl_fsm
      digest_init      = 0;
      digest_update    = 0;

      state_init       = 0;
      state_update     = 0;

      first_block      = 0;
      ready_flag       = 0;

      w_init           = 0;
      w_next           = 0;

      t_ctr_inc        = 0;
      t_ctr_rst        = 0;

      digest_valid_new = 0;
      digest_valid_we  = 0;

      sha256_ctrl_new  = CTRL_IDLE;
      sha256_ctrl_we   = 0;


      case (sha256_ctrl_reg)
        CTRL_IDLE:
          begin
            ready_flag = 1;

            if (init)
              begin
                digest_init      = 1;
                w_init           = 1;
                state_init       = 1;
                first_block      = 1;
                t_ctr_rst        = 1;
                digest_valid_new = 0;
                digest_valid_we  = 1;
                sha256_ctrl_new  = CTRL_ROUNDS;
                sha256_ctrl_we   = 1;
              end

            if (next)
              begin
                t_ctr_rst        = 1;
                w_init           = 1;
                state_init       = 1;
                digest_valid_new = 0;
                digest_valid_we  = 1;
                sha256_ctrl_new  = CTRL_ROUNDS;
                sha256_ctrl_we   = 1;
              end
          end


        CTRL_ROUNDS:
          begin
            w_next       = 1;
            state_update = 1;
            t_ctr_inc    = 1;

            if (t_ctr_reg == SHA256_ROUNDS)
              begin
                sha256_ctrl_new = CTRL_DONE;
                sha256_ctrl_we  = 1;
              end
          end


        CTRL_DONE:
          begin
            digest_update    = 1;
            digest_valid_new = 1;
            digest_valid_we  = 1;

            sha256_ctrl_new  = CTRL_IDLE;
            sha256_ctrl_we   = 1;
          end
      endcase // case (sha256_ctrl_reg)
    end // sha256_ctrl_fsm

endmodule // sha256_core

//======================================================================
// EOF sha256_core.v
//======================================================================
