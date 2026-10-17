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

    integer mismatch_count, unexpected_mismatch_count, trigger_mismatch_seen;

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

    // Issues one read transaction from master 0 to `addr` and checks
    // s_we_o (infected vs. clean) after the address/we/cyc/stb settle.
    task automatic check_txn(input [31:0] addr, input is_trigger_case, input [127:0] label);
        begin
            @(posedge clk);
            m0_addr_i = addr; m0_dat_i = 32'h11112222; m0_we_i = 1'b0; // plain read
            m0_sel_i = 4'hF; m0_cyc_i = 1'b1; m0_stb_i = 1'b1;
            @(posedge clk);
            if (s_we_o_inf !== s_we_o_clean) begin
                mismatch_count = mismatch_count + 1;
                if (is_trigger_case) begin
                    trigger_mismatch_seen = trigger_mismatch_seen + 1;
                    $display("[*] %0s addr=0x%08x (TRIGGER): infected s_we_o=%b clean s_we_o=%b (DIFFER, as expected)",
                              label, addr, s_we_o_inf, s_we_o_clean);
                end else begin
                    unexpected_mismatch_count = unexpected_mismatch_count + 1;
                    $display("[!] %0s addr=0x%08x (NOT expected trigger): infected s_we_o=%b clean s_we_o=%b DIFFER UNEXPECTEDLY",
                              label, addr, s_we_o_inf, s_we_o_clean);
                end
            end
            s_ack_i = 1'b1; s_err_i = 1'b0;
            @(posedge clk);
            s_ack_i = 1'b0;
            m0_cyc_i = 1'b0; m0_stb_i = 1'b0;
            repeat (2) @(posedge clk);
        end
    endtask

    integer i;
    reg [31:0] addr_sweep;

    initial begin
        clk = 0; rst_n = 0;
        m0_addr_i=0; m0_dat_i=0; m0_we_i=0; m0_sel_i=0; m0_stb_i=0; m0_cyc_i=0;
        m1_addr_i=0; m1_dat_i=0; m1_we_i=0; m1_sel_i=0; m1_stb_i=0; m1_cyc_i=0;
        s_dat_i=0; s_ack_i=0; s_err_i=0;
        mismatch_count = 0; unexpected_mismatch_count = 0; trigger_mismatch_seen = 0;

        #20; rst_n = 1; #10;

        // Sweep 40 ordinary addresses first -- none equal the magic 0x700.
        for (i = 0; i < 40; i = i + 1) begin
            addr_sweep = i * 4;
            check_txn(addr_sweep, 1'b0, "sweep");
        end

        // 1st and 2nd occurrences of the magic address: counter increments,
        // but must NOT fire yet.
        check_txn(32'h00000700, 1'b0, "magic#1");
        check_txn(32'h00000700, 1'b0, "magic#2");

        // Interleave an ordinary address between hits -- must not reset or
        // falsely trip the counter.
        check_txn(32'h00000050, 1'b0, "interleave");

        // 3rd occurrence of the magic address: documented firing point.
        check_txn(32'h00000700, 1'b1, "magic#3 (fires)");

        // 4th occurrence: counter saturates at 3, condition is ==2 only,
        // so this must NOT fire again.
        check_txn(32'h00000700, 1'b0, "magic#4 (saturated, dormant again)");

        $display("--------------------------------------------------------------");
        $display("Total mismatched transactions      : %0d", mismatch_count);
        $display("Unexpected (non-trigger) mismatches : %0d", unexpected_mismatch_count);
        $display("Documented trigger mismatches seen  : %0d", trigger_mismatch_seen);

        if (unexpected_mismatch_count == 0 && mismatch_count == 1 && trigger_mismatch_seen == 1)
            $display("TROJAN ACTIVATION CONFIRMED (fired exactly once, on the 3rd occurrence, nowhere else)");
        else if (trigger_mismatch_seen == 0)
            $display("TROJAN DID NOT FIRE on the documented trigger.");
        else
            $display("TROJAN FIRED OUTSIDE documented trigger (over-broad / not surgical).");
        $finish;
    end

    initial begin
        #200000;
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
