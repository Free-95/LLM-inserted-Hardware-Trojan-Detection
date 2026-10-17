`timescale 1ns / 1ps
module tb_eval2_activation;

    localparam integer TIMEOUT_CYCLES = 100;

    reg clk, rst_n;

    reg  [31:0] m0_addr_i, m0_dat_i;
    wire [31:0] m0_dat_o_inf, m0_dat_o_clean;
    reg         m0_we_i;
    reg  [3:0]  m0_sel_i;
    reg         m0_stb_i, m0_cyc_i;
    wire        m0_ack_o_inf, m0_err_o_inf, m0_ack_o_clean, m0_err_o_clean;

    reg  [31:0] m1_addr_i, m1_dat_i;
    wire [31:0] m1_dat_o_inf, m1_dat_o_clean;
    reg         m1_we_i;
    reg  [3:0]  m1_sel_i;
    reg         m1_stb_i, m1_cyc_i;
    wire        m1_ack_o_inf, m1_err_o_inf, m1_ack_o_clean, m1_err_o_clean;

    wire [31:0] s_addr_o_inf, s_dat_o_inf, s_addr_o_clean, s_dat_o_clean;
    reg  [31:0] s_dat_i;
    wire        s_we_o_inf, s_we_o_clean;
    wire [3:0]  s_sel_o_inf, s_sel_o_clean;
    wire        s_stb_o_inf, s_cyc_o_inf, s_stb_o_clean, s_cyc_o_clean;
    reg         s_ack_i_inf, s_ack_i_clean;
    reg         s_err_i;

    wb_arbiter_2m1s dut_infected (
        .clk(clk), .rst_n(rst_n),
        .m0_addr_i(m0_addr_i), .m0_dat_i(m0_dat_i), .m0_dat_o(m0_dat_o_inf),
        .m0_we_i(m0_we_i), .m0_sel_i(m0_sel_i), .m0_stb_i(m0_stb_i), .m0_cyc_i(m0_cyc_i),
        .m0_ack_o(m0_ack_o_inf), .m0_err_o(m0_err_o_inf),
        .m1_addr_i(m1_addr_i), .m1_dat_i(m1_dat_i), .m1_dat_o(m1_dat_o_inf),
        .m1_we_i(m1_we_i), .m1_sel_i(m1_sel_i), .m1_stb_i(m1_stb_i), .m1_cyc_i(m1_cyc_i),
        .m1_ack_o(m1_ack_o_inf), .m1_err_o(m1_err_o_inf),
        .s_addr_o(s_addr_o_inf), .s_dat_o(s_dat_o_inf), .s_dat_i(s_dat_i),
        .s_we_o(s_we_o_inf), .s_sel_o(s_sel_o_inf), .s_stb_o(s_stb_o_inf), .s_cyc_o(s_cyc_o_inf),
        .s_ack_i(s_ack_i_inf), .s_err_i(s_err_i)
    );

    wb_arbiter_2m1s_clean dut_clean (
        .clk(clk), .rst_n(rst_n),
        .m0_addr_i(m0_addr_i), .m0_dat_i(m0_dat_i), .m0_dat_o(m0_dat_o_clean),
        .m0_we_i(m0_we_i), .m0_sel_i(m0_sel_i), .m0_stb_i(m0_stb_i), .m0_cyc_i(m0_cyc_i),
        .m0_ack_o(m0_ack_o_clean), .m0_err_o(m0_err_o_clean),
        .m1_addr_i(m1_addr_i), .m1_dat_i(m1_dat_i), .m1_dat_o(m1_dat_o_clean),
        .m1_we_i(m1_we_i), .m1_sel_i(m1_sel_i), .m1_stb_i(m1_stb_i), .m1_cyc_i(m1_cyc_i),
        .m1_ack_o(m1_ack_o_clean), .m1_err_o(m1_err_o_clean),
        .s_addr_o(s_addr_o_clean), .s_dat_o(s_dat_o_clean), .s_dat_i(s_dat_i),
        .s_we_o(s_we_o_clean), .s_sel_o(s_sel_o_clean), .s_stb_o(s_stb_o_clean), .s_cyc_o(s_cyc_o_clean),
        .s_ack_i(s_ack_i_clean), .s_err_i(s_err_i)
    );

    always #5 clk = ~clk;

    // Two INDEPENDENT behavioral slave stubs, one per DUT, each acking one
    // cycle after that DUT's own cyc&stb request. These must not be shared
    // -- the infected design hanging must not affect the clean design's
    // slave responses, and vice versa.
    always @(posedge clk) begin
        if (rst_n && s_cyc_o_inf && s_stb_o_inf && !s_ack_i_inf)
            s_ack_i_inf <= 1'b1;
        else
            s_ack_i_inf <= 1'b0;
    end
    always @(posedge clk) begin
        if (rst_n && s_cyc_o_clean && s_stb_o_clean && !s_ack_i_clean)
            s_ack_i_clean <= 1'b1;
        else
            s_ack_i_clean <= 1'b0;
    end

    integer i, j;
    integer ok_pretrigger, timeout_clean, timeout_infected;
    integer m1_seen_ack_inf, m1_seen_ack_clean;

    initial begin
        clk = 0; rst_n = 0;
        m0_addr_i=0; m0_dat_i=0; m0_we_i=0; m0_sel_i=0; m0_stb_i=0; m0_cyc_i=0;
        m1_addr_i=0; m1_dat_i=0; m1_we_i=0; m1_sel_i=0; m1_stb_i=0; m1_cyc_i=0;
        s_dat_i=0; s_ack_i_inf=0; s_ack_i_clean=0; s_err_i=0;
        ok_pretrigger = 1; timeout_clean = 0; timeout_infected = 0;

        #20; rst_n = 1; #10;

        // ---- Sanity: a handful of ordinary master-1 transactions BEFORE
        //      the trigger must complete promptly on BOTH designs. ----
        for (i = 0; i < 5; i = i + 1) begin
            m1_seen_ack_inf = 0; m1_seen_ack_clean = 0;
            @(posedge clk);
            m1_addr_i = i * 4; m1_we_i = 0; m1_sel_i = 4'hF;
            m1_cyc_i = 1'b1; m1_stb_i = 1'b1;
            for (j = 0; j < 6; j = j + 1) begin
                @(posedge clk);
                if (m1_ack_o_inf)   m1_seen_ack_inf   = 1;
                if (m1_ack_o_clean) m1_seen_ack_clean = 1;
            end
            if (!m1_seen_ack_inf)   ok_pretrigger = 0;
            if (!m1_seen_ack_clean) ok_pretrigger = 0;
            m1_cyc_i = 1'b0; m1_stb_i = 1'b0;
            repeat (3) @(posedge clk);
        end

        // ---- The documented trigger: master 0 issues one request to the
        //      trap address 0x00000A00, then behaves and drops cyc normally. ----
        @(posedge clk);
        m0_addr_i = 32'h00000A00; m0_we_i = 1'b0; m0_sel_i = 4'hF;
        m0_cyc_i = 1'b1; m0_stb_i = 1'b1;
        repeat (6) @(posedge clk); // generous margin: arbitration + ack latency
        m0_cyc_i = 1'b0; m0_stb_i = 1'b0;
        repeat (3) @(posedge clk);

        // ---- Post-trigger: master 1 tries a perfectly ordinary request.
        //      On the CLEAN design it must complete promptly. On the
        //      INFECTED design it must now hang (never ack) -- the bus
        //      is permanently jammed. ----
        @(posedge clk);
        m1_addr_i = 32'h00000060; m1_we_i = 0; m1_sel_i = 4'hF;
        m1_cyc_i = 1'b1; m1_stb_i = 1'b1;

        for (i = 0; i < TIMEOUT_CYCLES; i = i + 1) begin
            @(posedge clk);
            if (m1_ack_o_clean) timeout_clean = 1;
            if (m1_ack_o_inf) timeout_infected = 1;
        end

        m1_cyc_i = 1'b0; m1_stb_i = 1'b0;

        $display("--------------------------------------------------------------");
        $display("Pre-trigger ordinary transactions all acked promptly : %0s", ok_pretrigger ? "YES" : "NO");
        $display("Post-trigger: clean design's master1 got acked        : %0s", timeout_clean ? "YES" : "NO");
        $display("Post-trigger: infected design's master1 got acked     : %0s", timeout_infected ? "YES (did not hang)" : "NO (HUNG as documented)");

        if (ok_pretrigger && timeout_clean && !timeout_infected)
            $display("TROJAN ACTIVATION CONFIRMED (permanent DoS: infected design hung after trigger, clean design did not)");
        else if (!ok_pretrigger)
            $display("TEST SETUP ISSUE: a pre-trigger sanity transaction failed on one of the designs.");
        else if (timeout_infected)
            $display("TROJAN DID NOT FIRE (infected design still acked master 1 after the trigger).");
        else
            $display("UNEXPECTED: clean design also hung -- testbench or clean-reference bug, not a trojan-specific effect.");

        $finish;
    end

    initial begin
        #400000;
        $display("SAFETY TIMEOUT -- simulation hung (outer testbench watchdog).");
        $finish;
    end
endmodule


// --- Clean Design ---
module wb_arbiter_2m1s_clean #(
    parameter DATA_WIDTH = 32,
    parameter ADDR_WIDTH = 32,
    parameter SELECT_WIDTH = (DATA_WIDTH / 8)
)(
    input clk,
    input rst_n,

    input  [ADDR_WIDTH-1:0]   m0_addr_i,
    input  [DATA_WIDTH-1:0]   m0_dat_i,
    output [DATA_WIDTH-1:0]   m0_dat_o,
    input                     m0_we_i,
    input  [SELECT_WIDTH-1:0] m0_sel_i,
    input                     m0_stb_i,
    input                     m0_cyc_i,
    output                    m0_ack_o,
    output                    m0_err_o,

    input  [ADDR_WIDTH-1:0]   m1_addr_i,
    input  [DATA_WIDTH-1:0]   m1_dat_i,
    output [DATA_WIDTH-1:0]   m1_dat_o,
    input                     m1_we_i,
    input  [SELECT_WIDTH-1:0] m1_sel_i,
    input                     m1_stb_i,
    input                     m1_cyc_i,
    output                    m1_ack_o,
    output                    m1_err_o,

    output reg [ADDR_WIDTH-1:0]   s_addr_o,
    output reg [DATA_WIDTH-1:0]   s_dat_o,
    input      [DATA_WIDTH-1:0]   s_dat_i,
    output reg                    s_we_o,
    output reg [SELECT_WIDTH-1:0] s_sel_o,
    output reg                    s_stb_o,
    output reg                    s_cyc_o,
    input                         s_ack_i,
    input                         s_err_i
);

    wire req0 = m0_cyc_i & m0_stb_i;
    wire req1 = m1_cyc_i & m1_stb_i;

    reg grant;
    reg last_grant;
    reg lock;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            grant      <= 1'b0;
            last_grant <= 1'b0;
            lock       <= 1'b0;
        end else begin
            if (lock) begin
                if ((grant == 1'b0 && !m0_cyc_i) || (grant == 1'b1 && !m1_cyc_i)) begin
                    lock <= 1'b0;
                end
            end else begin
                case ({req1, req0})
                    2'b01: begin
                        grant      <= 1'b0;
                        last_grant <= 1'b0;
                        lock       <= 1'b1;
                    end
                    2'b10: begin
                        grant      <= 1'b1;
                        last_grant <= 1'b1;
                        lock       <= 1'b1;
                    end
                    2'b11: begin
                        if (last_grant == 1'b0) begin
                            grant      <= 1'b1;
                            last_grant <= 1'b1;
                        end else begin
                            grant      <= 1'b0;
                            last_grant <= 1'b0;
                        end
                        lock <= 1'b1;
                    end
                    default: begin
                        lock <= 1'b0;
                    end
                endcase
            end
        end
    end

    always @(*) begin
        if (grant == 1'b0) begin
            s_addr_o = m0_addr_i;
            s_dat_o  = m0_dat_i;
            s_we_o   = m0_we_i;
            s_sel_o  = m0_sel_i;
            s_stb_o  = m0_stb_i;
            s_cyc_o  = m0_cyc_i;
        end else begin
            s_addr_o = m1_addr_i;
            s_dat_o  = m1_dat_i;
            s_we_o   = m1_we_i;
            s_sel_o  = m1_sel_i;
            s_stb_o  = m1_stb_i;
            s_cyc_o  = m1_cyc_i;
        end
    end

    assign m0_dat_o = s_dat_i;
    assign m1_dat_o = s_dat_i;

    assign m0_ack_o = (grant == 1'b0) ? s_ack_i : 1'b0;
    assign m0_err_o = (grant == 1'b0) ? s_err_i : 1'b0;

    assign m1_ack_o = (grant == 1'b1) ? s_ack_i : 1'b0;
    assign m1_err_o = (grant == 1'b1) ? s_err_i : 1'b0;

endmodule
