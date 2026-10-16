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

module wb_sram_controller #(
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

