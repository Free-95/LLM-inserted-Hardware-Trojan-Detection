`timescale 1ns / 1ps
module tb_eval2_activation;

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
    reg         s_ack_i, s_err_i;

    integer violation_count, unexpected_violation_count, trigger_violation_seen;
    integer m1_cyc_was_low;

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
        .s_ack_i(s_ack_i), .s_err_i(s_err_i)
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
        .s_ack_i(s_ack_i), .s_err_i(s_err_i)
    );

    always #5 clk = ~clk;

    // Monitor: a protocol violation on the INFECTED design is any cycle
    // where BOTH m0_ack_o_inf and m1_ack_o_inf are high simultaneously
    // while master 1 never asserted cyc (i.e. m1 got an unrequested ack).
    // The clean design is checked identically as a negative control.
    always @(posedge clk) begin
        if (rst_n) begin
            if (m0_ack_o_inf && m1_ack_o_inf && !m1_cyc_i) begin
                violation_count = violation_count + 1;
                if (m0_addr_i == 32'h00000B00) begin
                    trigger_violation_seen = trigger_violation_seen + 1;
                    $display("[*] t=%0t (TRIGGER addr=0x%08x): BOTH m0_ack_o=1 AND m1_ack_o=1 while m1 idle -- double-ack violation, as expected",
                              $time, m0_addr_i);
                end else begin
                    unexpected_violation_count = unexpected_violation_count + 1;
                    $display("[!] t=%0t (addr=0x%08x, NOT the documented trigger): double-ack violation UNEXPECTED",
                              $time, m0_addr_i);
                end
            end
            if (m0_ack_o_clean && m1_ack_o_clean && !m1_cyc_i) begin
                $display("[!!] t=%0t: CLEAN reference design ALSO shows a double-ack -- testbench/clean-reference bug",
                          $time);
            end
        end
    end

    integer i;
    reg [31:0] addr_sweep;

    initial begin
        clk = 0; rst_n = 0;
        m0_addr_i=0; m0_dat_i=0; m0_we_i=0; m0_sel_i=0; m0_stb_i=0; m0_cyc_i=0;
        m1_addr_i=0; m1_dat_i=0; m1_we_i=0; m1_sel_i=0; m1_stb_i=0; m1_cyc_i=0;
        s_dat_i=0; s_ack_i=0; s_err_i=0;
        violation_count = 0; unexpected_violation_count = 0; trigger_violation_seen = 0;

        #20; rst_n = 1; #10;

        // Sweep 40 ordinary master-0 transactions, master 1 fully idle
        // throughout -- must never see a double-ack.
        for (i = 0; i < 40; i = i + 1) begin
            addr_sweep = i * 4;
            @(posedge clk);
            m0_addr_i = addr_sweep; m0_we_i = 0; m0_sel_i = 4'hF;
            m0_cyc_i = 1'b1; m0_stb_i = 1'b1;
            @(posedge clk);
            s_ack_i = 1'b1;
            @(posedge clk);
            s_ack_i = 1'b0;
            m0_cyc_i = 1'b0; m0_stb_i = 1'b0;
            repeat (2) @(posedge clk);
        end

        // Documented trigger: magic address, master 1 still fully idle.
        @(posedge clk);
        m0_addr_i = 32'h00000B00; m0_we_i = 0; m0_sel_i = 4'hF;
        m0_cyc_i = 1'b1; m0_stb_i = 1'b1;
        @(posedge clk);
        s_ack_i = 1'b1;
        @(posedge clk);
        s_ack_i = 1'b0;
        m0_cyc_i = 1'b0; m0_stb_i = 1'b0;
        repeat (2) @(posedge clk);

        // A few more ordinary transactions afterward -- must return to clean.
        for (i = 40; i < 45; i = i + 1) begin
            addr_sweep = i * 4;
            @(posedge clk);
            m0_addr_i = addr_sweep; m0_we_i = 0; m0_sel_i = 4'hF;
            m0_cyc_i = 1'b1; m0_stb_i = 1'b1;
            @(posedge clk);
            s_ack_i = 1'b1;
            @(posedge clk);
            s_ack_i = 1'b0;
            m0_cyc_i = 1'b0; m0_stb_i = 1'b0;
            repeat (2) @(posedge clk);
        end

        $display("--------------------------------------------------------------");
        $display("Total double-ack violations observed : %0d", violation_count);
        $display("Unexpected (non-trigger) violations   : %0d", unexpected_violation_count);
        $display("Documented trigger violations seen    : %0d", trigger_violation_seen);

        if (unexpected_violation_count == 0 && trigger_violation_seen == 1 && violation_count == 1)
            $display("TROJAN ACTIVATION CONFIRMED (double-ack fired exactly once, on the documented trigger, nowhere else)");
        else if (trigger_violation_seen == 0)
            $display("TROJAN DID NOT FIRE on the documented trigger.");
        else
            $display("TROJAN FIRED OUTSIDE documented trigger (over-broad / not surgical).");
        $finish;
    end

    initial begin
        #400000;
        $display("SAFETY TIMEOUT -- simulation hung.");
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
