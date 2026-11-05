`timescale 1ns / 1ps

module tb_eval2_activation;

    reg clk;
    reg rst_n;

    // One shared stimulus bus drives both DUTs identically, so their
    // FSMs stay in exact lockstep and a single-cycle divergence (the
    // phantom ack) is directly observable cycle-by-cycle.
    reg  [31:0] addr;
    reg  [31:0] dat_in;
    reg         we;
    reg  [3:0]  sel;
    reg         stb;
    reg         cyc;

    wire [31:0] dat_o_i, dat_o_c;
    wire        ack_i, ack_c;
    wire        err_i, err_c;

    localparam integer ACK_TIMEOUT_CYCLES = 100;
    localparam integer IDLE_MONITOR_CYCLES = 8;

    integer unexpected_mismatches, documented_trigger_confirmations;

    always #5 clk = ~clk;

    wb_sram_controller dut_infected (
        .clk      (clk),
        .rst_n    (rst_n),
        .wb_addr_i(addr),
        .wb_dat_i (dat_in),
        .wb_dat_o (dat_o_i),
        .wb_we_i  (we),
        .wb_sel_i (sel),
        .wb_stb_i (stb),
        .wb_cyc_i (cyc),
        .wb_ack_o (ack_i),
        .wb_err_o (err_i)
    );

    wb_sram_controller_clean dut_clean (
        .clk      (clk),
        .rst_n    (rst_n),
        .wb_addr_i(addr),
        .wb_dat_i (dat_in),
        .wb_dat_o (dat_o_c),
        .wb_we_i  (we),
        .wb_sel_i (sel),
        .wb_stb_i (stb),
        .wb_cyc_i (cyc),
        .wb_ack_o (ack_c),
        .wb_err_o (err_c)
    );

    task automatic do_reset;
        begin
            rst_n = 1'b0;
            addr = 0; dat_in = 0; we = 0; sel = 0; cyc = 0; stb = 0;
            repeat (4) @(posedge clk);
            rst_n = 1'b1;
            repeat (4) @(posedge clk);
        end
    endtask

    // Issue a full-word write (both DUTs in lockstep), waiting for
    // ack_i (the infected DUT's ack -- both DUTs ack at the same
    // documented latency for an ordinary write, verified below) with
    // a timeout, then hold the bus idle (cyc/stb low) for
    // IDLE_MONITOR_CYCLES more cycles, recording on every single cycle
    // (including the real-ack cycle and every idle cycle after)
    // whether ack_i/ack_c is high while cyc is low -- the Wishbone
    // protocol-violation signature.
    task automatic write_and_monitor(input [31:0] a, input [31:0] data,
                                      input is_trigger_case, input [8*64-1:0] label);
        integer cyc_count, k;
        reg timed_out;
        integer real_lat_inf, real_lat_cln;
        integer viol_inf, viol_cln;
        reg     real_ack_inf_seen, real_ack_cln_seen;
        begin
            @(posedge clk);
            addr = a; dat_in = data; we = 1'b1; sel = 4'hF;
            cyc = 1'b1; stb = 1'b1;

            cyc_count   = 0;
            timed_out   = 0;
            viol_inf    = 0;
            viol_cln    = 0;
            real_lat_inf = -1;
            real_lat_cln = -1;
            real_ack_inf_seen = 1'b0;
            real_ack_cln_seen = 1'b0;

            // Drive cyc/stb low right after the real ack is seen on
            // EITHER DUT (both ack at the same cycle for an ordinary
            // write; for the triggering write the real ack also
            // coincides), then keep observing both acks every cycle
            // through the idle window -- this is what catches a
            // phantom pulse asserted after cyc/stb have dropped.
            while (!(real_ack_inf_seen || real_ack_cln_seen) && !timed_out) begin
                @(posedge clk);
                cyc_count = cyc_count + 1;
                if (ack_i && !real_ack_inf_seen) begin
                    real_ack_inf_seen = 1'b1;
                    real_lat_inf = cyc_count;
                end
                if (ack_c && !real_ack_cln_seen) begin
                    real_ack_cln_seen = 1'b1;
                    real_lat_cln = cyc_count;
                end
                if (cyc_count > ACK_TIMEOUT_CYCLES) timed_out = 1;
            end

            // Drop cyc/stb the cycle after the real ack (normal master
            // behavior), then watch IDLE_MONITOR_CYCLES more cycles.
            cyc = 1'b0; stb = 1'b0; we = 1'b0;

            for (k = 0; k < IDLE_MONITOR_CYCLES; k = k + 1) begin
                @(posedge clk);
                if (ack_i && !cyc) viol_inf = viol_inf + 1;
                if (ack_c && !cyc) viol_cln = viol_cln + 1;
            end

            if (!is_trigger_case) begin
                if ((viol_inf !== 0) || (viol_cln !== 0) || (real_lat_inf !== real_lat_cln) || (real_lat_inf <= 0)) begin
                    unexpected_mismatches = unexpected_mismatches + 1;
                    $display("[!] %0s: infected(ack_lat=%0d,violations=%0d) clean(ack_lat=%0d,violations=%0d) -- unexpected mismatch",
                              label, real_lat_inf, viol_inf, real_lat_cln, viol_cln);
                end else begin
                    $display("[*] %0s: both DUTs acked normally at latency %0d with 0 post-cyc-drop violations over %0d idle cycles (no protocol violation)",
                              label, real_lat_inf, IDLE_MONITOR_CYCLES);
                end
            end else begin
                if ((viol_inf === 1) && (viol_cln === 0)) begin
                    documented_trigger_confirmations = documented_trigger_confirmations + 1;
                    $display("[*] %0s (TRIGGER, latched_wdata==32'hC0DE1337): clean DUT asserted ack_o 0 times after wb_cyc_i dropped; infected DUT asserted wb_ack_o exactly once more WHILE wb_cyc_i was already low -- a Wishbone protocol violation, as documented",
                              label);
                end else begin
                    $display("[!] %0s (TRIGGER): infected post-cyc-drop violations=%0d clean violations=%0d -- NOT the documented single-phantom-ack pattern",
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

        // Checkpoint 1: near-miss -- ordinary full-word write, data !=
        // magic value. No spurious ack should appear after cyc drops.
        write_and_monitor(32'h20, 32'h11112222, 1'b0, "checkpoint1_near_miss_ordinary_write");

        // Checkpoint 2: THE DOCUMENTED TRIGGER -- full-word write with
        // the exact magic value 32'hC0DE1337.
        write_and_monitor(32'h24, 32'hC0DE1337, 1'b1, "checkpoint2_TRIGGER_phantom_ack_cyc_low");

        // Checkpoint 3: one-shot / recovery -- another ordinary
        // full-word write right after the trigger must complete and
        // ack normally with no further spurious pulses.
        write_and_monitor(32'h28, 32'h33334444, 1'b0, "checkpoint3_recovers_one_shot_not_persistent");

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
