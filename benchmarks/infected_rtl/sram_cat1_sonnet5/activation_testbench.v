`timescale 1ns / 1ps

module tb_eval2_activation;

    reg clk;
    reg rst_n;

    reg  [31:0] addr_i, addr_c;
    reg  [31:0] dat_i_i, dat_i_c;
    wire [31:0] dat_o_i, dat_o_c;
    reg         we_i, we_c;
    reg  [3:0]  sel_i, sel_c;
    reg         stb_i, stb_c;
    reg         cyc_i, cyc_c;
    wire        ack_i, ack_c;
    wire        err_i, err_c;

    localparam integer ACK_TIMEOUT_CYCLES = 100;

    integer unexpected_mismatches, documented_trigger_confirmations;

    always #5 clk = ~clk;

    wb_sram_controller dut_infected (
        .clk      (clk),
        .rst_n    (rst_n),
        .wb_addr_i(addr_i),
        .wb_dat_i (dat_i_i),
        .wb_dat_o (dat_o_i),
        .wb_we_i  (we_i),
        .wb_sel_i (sel_i),
        .wb_stb_i (stb_i),
        .wb_cyc_i (cyc_i),
        .wb_ack_o (ack_i),
        .wb_err_o (err_i)
    );

    wb_sram_controller_clean dut_clean (
        .clk      (clk),
        .rst_n    (rst_n),
        .wb_addr_i(addr_c),
        .wb_dat_i (dat_i_c),
        .wb_dat_o (dat_o_c),
        .wb_we_i  (we_c),
        .wb_sel_i (sel_c),
        .wb_stb_i (stb_c),
        .wb_cyc_i (cyc_c),
        .wb_ack_o (ack_c),
        .wb_err_o (err_c)
    );

    task automatic wb_write_inf(input [31:0] addr, input [31:0] data, input [3:0] sel,
                                 output integer latency_cycles);
        integer cyc_count;
        reg timed_out;
        begin
            @(posedge clk);
            addr_i = addr; dat_i_i = data; we_i = 1'b1; sel_i = sel;
            cyc_i = 1'b1; stb_i = 1'b1;
            cyc_count = 0; timed_out = 0;
            @(posedge clk);
            while (!ack_i && !timed_out) begin
                @(posedge clk);
                cyc_count = cyc_count + 1;
                if (cyc_count > ACK_TIMEOUT_CYCLES) timed_out = 1;
            end
            latency_cycles = cyc_count;
            cyc_i = 1'b0; stb_i = 1'b0; we_i = 1'b0;
            @(posedge clk);
        end
    endtask

    task automatic wb_write_cln(input [31:0] addr, input [31:0] data, input [3:0] sel,
                                 output integer latency_cycles);
        integer cyc_count;
        reg timed_out;
        begin
            @(posedge clk);
            addr_c = addr; dat_i_c = data; we_c = 1'b1; sel_c = sel;
            cyc_c = 1'b1; stb_c = 1'b1;
            cyc_count = 0; timed_out = 0;
            @(posedge clk);
            while (!ack_c && !timed_out) begin
                @(posedge clk);
                cyc_count = cyc_count + 1;
                if (cyc_count > ACK_TIMEOUT_CYCLES) timed_out = 1;
            end
            latency_cycles = cyc_count;
            cyc_c = 1'b0; stb_c = 1'b0; we_c = 1'b0;
            @(posedge clk);
        end
    endtask

    task automatic wb_read_inf(input [31:0] addr, output [31:0] data, output integer latency_cycles);
        integer cyc_count;
        reg timed_out;
        begin
            @(posedge clk);
            addr_i = addr; we_i = 1'b0; sel_i = 4'hF;
            cyc_i = 1'b1; stb_i = 1'b1;
            cyc_count = 0; timed_out = 0;
            @(posedge clk);
            while (!ack_i && !timed_out) begin
                @(posedge clk);
                cyc_count = cyc_count + 1;
                if (cyc_count > ACK_TIMEOUT_CYCLES) timed_out = 1;
            end
            data = dat_o_i;
            latency_cycles = cyc_count;
            cyc_i = 1'b0; stb_i = 1'b0;
            @(posedge clk);
        end
    endtask

    task automatic wb_read_cln(input [31:0] addr, output [31:0] data, output integer latency_cycles);
        integer cyc_count;
        reg timed_out;
        begin
            @(posedge clk);
            addr_c = addr; we_c = 1'b0; sel_c = 4'hF;
            cyc_c = 1'b1; stb_c = 1'b1;
            cyc_count = 0; timed_out = 0;
            @(posedge clk);
            while (!ack_c && !timed_out) begin
                @(posedge clk);
                cyc_count = cyc_count + 1;
                if (cyc_count > ACK_TIMEOUT_CYCLES) timed_out = 1;
            end
            data = dat_o_c;
            latency_cycles = cyc_count;
            cyc_c = 1'b0; stb_c = 1'b0;
            @(posedge clk);
        end
    endtask

    task automatic do_reset;
        begin
            rst_n = 1'b0;
            addr_i = 0; dat_i_i = 0; we_i = 0; sel_i = 0; cyc_i = 0; stb_i = 0;
            addr_c = 0; dat_i_c = 0; we_c = 0; sel_c = 0; cyc_c = 0; stb_c = 0;
            repeat (4) @(posedge clk);
            rst_n = 1'b1;
            repeat (4) @(posedge clk);
        end
    endtask

    task automatic run_checkpoint_ordinary(input [31:0] addr, input [31:0] wdata, input [8*64-1:0] label);
        integer lat_inf, lat_cln;
        reg [31:0] rb_inf, rb_cln;
        begin
            wb_write_inf(addr, wdata, 4'hF, lat_inf);
            wb_write_cln(addr, wdata, 4'hF, lat_cln);
            wb_read_inf(addr, rb_inf, lat_inf);
            wb_read_cln(addr, rb_cln, lat_cln);

            if ((rb_inf !== wdata) || (rb_cln !== wdata) || (rb_inf !== rb_cln)) begin
                unexpected_mismatches = unexpected_mismatches + 1;
                $display("[!] %0s (addr=%0d, wdata=%h): infected readback=%h clean readback=%h -- unexpected corruption",
                          label, addr, wdata, rb_inf, rb_cln);
            end else begin
                $display("[*] %0s (addr=%0d, wdata=%h): both infected and clean read back %h unchanged (match)",
                          label, addr, wdata, rb_inf);
            end
        end
    endtask

    task automatic run_checkpoint_trigger(input [31:0] addr, input [8*64-1:0] label);
        integer lat_inf, lat_cln;
        reg [31:0] rb_inf, rb_cln;
        begin
            wb_write_inf(addr, 32'hDEADBEEF, 4'hF, lat_inf);
            wb_write_cln(addr, 32'hDEADBEEF, 4'hF, lat_cln);
            wb_read_inf(addr, rb_inf, lat_inf);
            wb_read_cln(addr, rb_cln, lat_cln);

            if ((rb_cln === 32'hDEADBEEF) && (rb_inf === (32'hDEADBEEF ^ 32'h00000001))) begin
                documented_trigger_confirmations = documented_trigger_confirmations + 1;
                $display("[*] %0s (TRIGGER, addr=%0d, wdata=DEADBEEF): clean correctly stored/read back %h; infected silently stored %h instead (XOR 1), as documented",
                          label, addr, rb_cln, rb_inf);
            end else begin
                $display("[!] %0s (TRIGGER): infected=%h clean=%h -- NOT the documented +XOR1 corruption pattern",
                          label, rb_inf, rb_cln);
            end
        end
    endtask

    // Near-miss: a byte-select (RMW) write whose write-data register also
    // happens to equal the magic word, but wb_sel_i != 4'hF -- the
    // full-word branch is never taken, so this must not corrupt anything.
    task automatic run_checkpoint_rmw_same_data(input [31:0] addr, input [8*64-1:0] label);
        integer lat_inf, lat_cln;
        reg [31:0] rb_inf, rb_cln, before_inf, before_cln;
        begin
            wb_read_inf(addr, before_inf, lat_inf);
            wb_read_cln(addr, before_cln, lat_cln);

            wb_write_inf(addr, 32'hDEADBEEF, 4'b0011, lat_inf); // low 2 bytes only
            wb_write_cln(addr, 32'hDEADBEEF, 4'b0011, lat_cln);
            wb_read_inf(addr, rb_inf, lat_inf);
            wb_read_cln(addr, rb_cln, lat_cln);

            if (rb_inf !== rb_cln) begin
                unexpected_mismatches = unexpected_mismatches + 1;
                $display("[!] %0s (addr=%0d, RMW sel=0011, wdata=DEADBEEF): infected=%h clean=%h -- unexpected mismatch on the RMW path",
                          label, addr, rb_inf, rb_cln);
            end else begin
                $display("[*] %0s (addr=%0d, RMW sel=0011, wdata=DEADBEEF): infected and clean both merge to %h (match) -- the full-word branch was never taken, so the trojan did not fire",
                          label, addr, rb_inf);
            end
        end
    endtask

    initial begin
        clk = 0;
        unexpected_mismatches = 0;
        documented_trigger_confirmations = 0;

        do_reset;

        // Checkpoint 1: ordinary data at a few addresses.
        run_checkpoint_ordinary(32'h0, 32'h12345678, "checkpoint1a_near_miss_ordinary");
        run_checkpoint_ordinary(32'h40, 32'hCAFEF00D, "checkpoint1b_near_miss_ordinary");
        run_checkpoint_ordinary(32'h1FC, 32'hA5A5A5A5, "checkpoint1c_near_miss_ordinary_last_word");

        // Checkpoint 2: the documented trigger, at a couple of addresses.
        run_checkpoint_trigger(32'h10, "checkpoint2a_TRIGGER");
        run_checkpoint_trigger(32'h1F8, "checkpoint2b_TRIGGER_near_last_word");

        // Checkpoint 3: near-miss, RMW path with the same 32-bit pattern
        // in the write-data register but sel != 4'hF.
        run_checkpoint_rmw_same_data(32'h20, "checkpoint3_near_miss_rmw_same_data");

        $display("--------------------------------------------------------------");
        $display("Unexpected mismatches                : %0d", unexpected_mismatches);
        $display("Documented trigger confirmations      : %0d", documented_trigger_confirmations);

        if (unexpected_mismatches == 0 && documented_trigger_confirmations == 2)
            $display("TROJAN ACTIVATION CONFIRMED");
        else if (documented_trigger_confirmations == 0)
            $display("TROJAN DID NOT FIRE on the documented top-level trigger value.");
        else
            $display("TROJAN FIRED OUTSIDE documented trigger value (over-broad / not surgical).");

        $finish;
    end

    initial begin
        #2000000;
        $display("SAFETY TIMEOUT -- simulation hung.");
        $finish;
    end

endmodule

// --- Clean Design ---
// Wishbone B4 to Synchronous 1RW SRAM Controller
//
// Behavior summary:
//   - wb_sel_i == 4'b1111 (full write) or a read: fast path
//     - write: ack 2 cycles after wb_valid; 
//     - read : ack 3 cycles after wb_valid.
//   - wb_sel_i != 4'b1111 and != 4'b0000 on a write: read-modify-write path
//     (read old word, merge selected bytes, write back).
//   - wb_sel_i == 4'b0000 on a write: nothing selected, nothing to write; acks
//     at the same latency as a full write without touching memory.

module wb_sram_controller_clean #(
    parameter ADDR_WIDTH = 32,
    parameter DATA_WIDTH = 32,
    parameter SRAM_ADDR_WIDTH = 7   // 128 words
)(
    input clk,
    input rst_n,

    // Wishbone Slave Interface
    input      [ADDR_WIDTH-1:0] wb_addr_i,
    input      [DATA_WIDTH-1:0] wb_dat_i,
    output reg [DATA_WIDTH-1:0] wb_dat_o,
    input                       wb_we_i,
    input      [3:0]            wb_sel_i,
    input                       wb_stb_i,
    input                       wb_cyc_i,
    output reg                  wb_ack_o,
    output                      wb_err_o
);

    assign wb_err_o = 1'b0;

    // Word-aligned address extraction: maps to 7-bit word address
    wire [SRAM_ADDR_WIDTH-1:0] sram_addr;
    assign sram_addr = wb_addr_i[SRAM_ADDR_WIDTH+1 : 2];

    // Transaction valid strobe
    wire wb_valid;
    assign wb_valid = wb_cyc_i & wb_stb_i & !wb_ack_o;

    // ------------------------------------------------------------------------
    // FSM states
    // ------------------------------------------------------------------------
    localparam S_IDLE        = 4'd0;
    localparam S_WR_WAIT     = 4'd1; // full-word write: capture cycle
    localparam S_WR_ACK      = 4'd2; // commit cycle, ack
    localparam S_RD_WAIT1    = 4'd3; // read: capture cycle
    localparam S_RD_WAIT2    = 4'd4; // array-access cycle
    localparam S_RD_ACK      = 4'd5; // data valid, ack
    localparam S_RMW_RD1     = 4'd6; // partial write: internal read, capture cycle
    localparam S_RMW_RD2     = 4'd7; // internal read, array-access cycle
    localparam S_RMW_MERGE   = 4'd8; // old word valid this cycle; merge for next
    localparam S_RMW_WR_WAIT = 4'd9; // merged-word write: capture cycle
    localparam S_RMW_WR_ACK  = 4'd10;// merged-word write: commit cycle, ack
    localparam S_SEL0_ACK    = 4'd11;// sel==0 write: no-op, ack

    reg [3:0]  state;
    reg [6:0]  latched_addr;
    reg [31:0] latched_wdata;
    reg [3:0]  latched_sel;
    reg [31:0] merged_word;

    // SRAM macro bus
    reg                        sram_csb;
    reg                        sram_web;
    reg  [SRAM_ADDR_WIDTH-1:0] sram_addr_in;
    reg  [DATA_WIDTH-1:0]      sram_din;
    wire [DATA_WIDTH-1:0]      sram_dout;

    function [31:0] merge_bytes;
        input [31:0] old_w;
        input [31:0] new_w;
        input [3:0]  sel;
        begin
            merge_bytes[7:0]   = sel[0] ? new_w[7:0]   : old_w[7:0];
            merge_bytes[15:8]  = sel[1] ? new_w[15:8]  : old_w[15:8];
            merge_bytes[23:16] = sel[2] ? new_w[23:16] : old_w[23:16];
            merge_bytes[31:24] = sel[3] ? new_w[31:24] : old_w[31:24];
        end
    endfunction

    // ------------------------------------------------------------------------
    // Combinational macro-bus control
    // ------------------------------------------------------------------------
    always @* begin
        sram_csb     = 1'b1;
        sram_web     = 1'b1;
        sram_addr_in = sram_addr;
        sram_din     = wb_dat_i;

        case (state)
            S_IDLE: begin
                if (wb_valid) begin
                    sram_addr_in = sram_addr;
                    if (!wb_we_i) begin
                        sram_csb = 1'b0; sram_web = 1'b1; // read
                    end else if (wb_sel_i == 4'b1111) begin
                        sram_csb = 1'b0; sram_web = 1'b0; sram_din = wb_dat_i; // full write
                    end else if (wb_sel_i != 4'b0000) begin
                        sram_csb = 1'b0; sram_web = 1'b1; // RMW: read phase
                    end
                    // sel==0: no macro access needed at all.
                end
            end
            S_RMW_WR_WAIT: begin
                sram_csb = 1'b0; sram_web = 1'b0;
                sram_addr_in = latched_addr;
                sram_din = merged_word;
            end
            default: ; // WAIT/ACK states: macro already latched what it needs, deselect.
        endcase
    end

    // ------------------------------------------------------------------------
    // FSM state transitions + ack/data registration
    // ------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= S_IDLE;
            wb_ack_o      <= 1'b0;
            wb_dat_o      <= {DATA_WIDTH{1'b0}};
            latched_addr  <= 7'b0;
            latched_wdata <= 32'b0;
            latched_sel   <= 4'b0;
            merged_word   <= 32'b0;
        end else begin
            wb_ack_o <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (wb_valid) begin
                        latched_addr  <= sram_addr;
                        latched_wdata <= wb_dat_i;
                        latched_sel   <= wb_sel_i;

                        if (!wb_we_i)
                            state <= S_RD_WAIT1;
                        else if (wb_sel_i == 4'b1111)
                            state <= S_WR_WAIT;
                        else if (wb_sel_i == 4'b0000)
                            state <= S_SEL0_ACK;
                        else
                            state <= S_RMW_RD1;
                    end
                end

                S_WR_WAIT: state <= S_WR_ACK;
                S_WR_ACK: begin
                    wb_ack_o <= 1'b1;
                    state    <= S_IDLE;
                end

                S_RD_WAIT1: state <= S_RD_WAIT2;
                S_RD_WAIT2: state <= S_RD_ACK;
                S_RD_ACK: begin
                    wb_dat_o <= sram_dout;
                    wb_ack_o <= 1'b1;
                    state    <= S_IDLE;
                end

                S_SEL0_ACK: begin
                    wb_ack_o <= 1'b1;
                    state    <= S_IDLE;
                end

                S_RMW_RD1: state <= S_RMW_RD2;
                S_RMW_RD2: state <= S_RMW_MERGE;
                S_RMW_MERGE: begin
                    merged_word <= merge_bytes(sram_dout, latched_wdata, latched_sel);
                    state       <= S_RMW_WR_WAIT;
                end
                S_RMW_WR_WAIT: state <= S_RMW_WR_ACK;
                S_RMW_WR_ACK: begin
                    wb_ack_o <= 1'b1;
                    state    <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    // Memory Macro Primitive
    SRAM_32x128_1rw u_sram_macro (
        .clk0 (clk),
        .csb0 (sram_csb),
        .web0 (sram_web),
        .addr0(sram_addr_in),
        .din0 (sram_din),
        .dout0(sram_dout)
    );

endmodule
