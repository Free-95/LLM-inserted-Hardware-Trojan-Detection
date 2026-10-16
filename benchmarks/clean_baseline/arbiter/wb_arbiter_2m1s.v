// Standard 2-Master to 1-Slave Wishbone Classic Crossbar Arbiter
// Implements round-robin arbitration with transaction-level locking.

module wb_arbiter_2m1s #(
    parameter DATA_WIDTH = 32,
    parameter ADDR_WIDTH = 32,
    parameter SELECT_WIDTH = (DATA_WIDTH / 8)
)(
    input clk,
    input rst_n,

    // Master 0 Interface
    input  [ADDR_WIDTH-1:0]   m0_addr_i,
    input  [DATA_WIDTH-1:0]   m0_dat_i,
    output [DATA_WIDTH-1:0]   m0_dat_o,
    input                     m0_we_i,
    input  [SELECT_WIDTH-1:0] m0_sel_i,
    input                     m0_stb_i,
    input                     m0_cyc_i,
    output                    m0_ack_o,
    output                    m0_err_o,

    // Master 1 Interface
    input  [ADDR_WIDTH-1:0]   m1_addr_i,
    input  [DATA_WIDTH-1:0]   m1_dat_i,
    output [DATA_WIDTH-1:0]   m1_dat_o,
    input                     m1_we_i,
    input  [SELECT_WIDTH-1:0] m1_sel_i,
    input                     m1_stb_i,
    input                     m1_cyc_i,
    output                    m1_ack_o,
    output                    m1_err_o,

    // Shared Slave Interface
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

    // Internal request indicators
    wire req0 = m0_cyc_i & m0_stb_i;
    wire req1 = m1_cyc_i & m1_stb_i;

    // Grant register: 1'b0 -> Master 0, 1'b1 -> Master 1
    reg grant;
    reg last_grant;
    reg lock;

    // -------------------------------------------------------------
    // Arbitration & Grant Generation
    // -------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            grant      <= 1'b0;
            last_grant <= 1'b0;
            lock       <= 1'b0;
        end else begin
            if (lock) begin
                // Maintain current grant until cycle completes
                if ((grant == 1'b0 && !m0_cyc_i) || (grant == 1'b1 && !m1_cyc_i)) begin
                    lock <= 1'b0;
                end
            end else begin
                // Round-robin arbitration across active requests
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

    // -------------------------------------------------------------
    // Datapath Multiplexing (Masters -> Shared Slave)
    // -------------------------------------------------------------
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

    // -------------------------------------------------------------
    // Response Steering (Shared Slave -> Granted Master)
    // -------------------------------------------------------------
    assign m0_dat_o = s_dat_i;
    assign m1_dat_o = s_dat_i;

    assign m0_ack_o = (grant == 1'b0) ? s_ack_i : 1'b0;
    assign m0_err_o = (grant == 1'b0) ? s_err_i : 1'b0;

    assign m1_ack_o = (grant == 1'b1) ? s_ack_i : 1'b0;
    assign m1_err_o = (grant == 1'b1) ? s_err_i : 1'b0;

endmodule

