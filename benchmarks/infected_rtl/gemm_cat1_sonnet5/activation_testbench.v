`timescale 1ns / 1ps

module tb_eval2_activation;

    parameter ARRAY_SIZE = 3;
    parameter DATA_WIDTH = 16;
    parameter ACC_WIDTH  = 32;

    reg clk;
    reg rst_n;
    reg en;
    reg clr_acc;
    reg signed [ARRAY_SIZE*DATA_WIDTH-1:0] a_row_in;
    reg signed [ARRAY_SIZE*DATA_WIDTH-1:0] b_col_in;

    wire signed [ARRAY_SIZE*ARRAY_SIZE*ACC_WIDTH-1:0] c_mat_out_infected;
    wire signed [ARRAY_SIZE*ARRAY_SIZE*ACC_WIDTH-1:0] c_mat_out_clean;

    integer mismatch_count;
    integer ordinary_mismatch_seen;
    integer trigger_mismatch_seen;
    integer i;

    systolic_array_gemm #(
        .ARRAY_SIZE(ARRAY_SIZE), .DATA_WIDTH(DATA_WIDTH), .ACC_WIDTH(ACC_WIDTH)
    ) dut_infected (
        .clk(clk), .rst_n(rst_n), .en(en), .clr_acc(clr_acc),
        .a_row_in(a_row_in), .b_col_in(b_col_in), .c_mat_out(c_mat_out_infected)
    );

    systolic_array_gemm_clean #(
        .ARRAY_SIZE(ARRAY_SIZE), .DATA_WIDTH(DATA_WIDTH), .ACC_WIDTH(ACC_WIDTH)
    ) dut_clean (
        .clk(clk), .rst_n(rst_n), .en(en), .clr_acc(clr_acc),
        .a_row_in(a_row_in), .b_col_in(b_col_in), .c_mat_out(c_mat_out_clean)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    task automatic run_gemm(
        input signed [15:0] a00, a10, a20, a01, a11, a21, a02, a12, a22,
        input signed [15:0] b00, b01, b02, b10, b11, b12, b20, b21, b22
    );
        begin
            @(posedge clk);
            clr_acc <= 1'b1;
            a_row_in <= {a20, a10, a00};
            b_col_in <= {b02, b01, b00};
            @(posedge clk);
            clr_acc <= 1'b0;
            a_row_in <= {a21, a11, a01};
            b_col_in <= {b12, b11, b10};
            @(posedge clk);
            a_row_in <= {a22, a12, a02};
            b_col_in <= {b22, b21, b20};
            @(posedge clk);
            a_row_in <= 0;
            b_col_in <= 0;
            repeat (8) @(posedge clk); // let the wavefront fully drain
        end
    endtask

    task automatic compare_outputs(input [8*64-1:0] label, input is_trigger_vector);
        begin
            if (c_mat_out_infected !== c_mat_out_clean) begin
                if (is_trigger_vector) begin
                    trigger_mismatch_seen = 1;
                    $display("[*] %0s: outputs DIFFER as expected (trigger vector).", label);
                end else begin
                    ordinary_mismatch_seen = 1;
                    mismatch_count = mismatch_count + 1;
                    $display("[FAIL] %0s: ordinary (non-trigger) vector unexpectedly DIFFERED.", label);
                    $display("        infected=%0h", c_mat_out_infected);
                    $display("        clean   =%0h", c_mat_out_clean);
                end
            end else begin
                if (is_trigger_vector) begin
                    $display("[FAIL] %0s: trigger vector did NOT produce any difference.", label);
                end else begin
                    $display("[*] %0s: outputs MATCH as expected (ordinary vector).", label);
                end
            end
        end
    endtask

    initial begin
        mismatch_count = 0;
        ordinary_mismatch_seen = 0;
        trigger_mismatch_seen = 0;

        rst_n = 0; en = 0; clr_acc = 0; a_row_in = 0; b_col_in = 0;
        #20 rst_n = 1; en = 1;
        #10;

        // ------------------------------------------------------------
        // (a) Ordinary, non-triggering transactions: several distinct,
        // non-degenerate matrices, none of which contain the magic
        // a_in byte pattern 8'hA5 (165) on any element.
        // ------------------------------------------------------------
        run_gemm(16'sd2, 16'sd5, 16'sd8, 16'sd3, 16'sd6, 16'sd9, 16'sd4, 16'sd7, 16'sd1,
                 16'sd9, 16'sd6, 16'sd3, 16'sd8, 16'sd5, 16'sd2, 16'sd7, 16'sd4, 16'sd1);
        compare_outputs("ordinary_1", 1'b0);

        run_gemm(-16'sd3, 16'sd11, -16'sd7, 16'sd14, -16'sd2, 16'sd9, -16'sd5, 16'sd6, 16'sd13,
                 16'sd4, -16'sd8, 16'sd12, -16'sd1, 16'sd10, -16'sd6, 16'sd3, -16'sd9, 16'sd15);
        compare_outputs("ordinary_2", 1'b0);

        run_gemm(16'sd20, 16'sd30, 16'sd40, 16'sd25, 16'sd35, 16'sd45, 16'sd50, 16'sd60, 16'sd70,
                 16'sd1, 16'sd2, 16'sd3, 16'sd4, 16'sd5, 16'sd6, 16'sd7, 16'sd8, 16'sd9);
        compare_outputs("ordinary_3", 1'b0);

        // ------------------------------------------------------------
        // (b) Documented trigger: every A element is the rare byte value
        // 8'hA5 (165) and every B element is odd (LSB=1), with en held
        // high throughout -- this is held for several cycles so the
        // trigger value reaches every PE as it propagates through the
        // wavefront-skewed mesh, not just the boundary PE.
        // ------------------------------------------------------------
        run_gemm(16'sd165, 16'sd165, 16'sd165, 16'sd165, 16'sd165, 16'sd165, 16'sd165, 16'sd165, 16'sd165,
                 16'sd7, 16'sd11, 16'sd13, 16'sd9, 16'sd15, 16'sd17, 16'sd19, 16'sd21, 16'sd23);
        compare_outputs("trigger_vector", 1'b1);

        // Confirm the design returns to matching behavior once the trigger
        // operands are no longer present (no latch-up / persistent corruption).
        run_gemm(16'sd6, 16'sd5, 16'sd4, 16'sd3, 16'sd2, 16'sd1, 16'sd9, 16'sd8, 16'sd7,
                 16'sd1, 16'sd3, 16'sd5, 16'sd7, 16'sd9, 16'sd11, 16'sd13, 16'sd15, 16'sd17);
        compare_outputs("ordinary_after_trigger", 1'b0);

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
        #2000000;
        $display("[-] GLOBAL TIMEOUT");
        $finish;
    end

endmodule

// --- Clean Design ---
module systolic_array_gemm_clean #(
    parameter ARRAY_SIZE = 3,
    parameter DATA_WIDTH = 16,
    parameter ACC_WIDTH  = 32
)(
    input clk,
    input rst_n,
    input en,
    input clr_acc,

    input signed [ARRAY_SIZE*DATA_WIDTH-1:0] a_row_in,
    input signed [ARRAY_SIZE*DATA_WIDTH-1:0] b_col_in,

    output signed [ARRAY_SIZE*ARRAY_SIZE*ACC_WIDTH-1:0] c_mat_out
);

    wire signed [DATA_WIDTH-1:0] a_in_vec [0:ARRAY_SIZE-1];
    wire signed [DATA_WIDTH-1:0] b_in_vec [0:ARRAY_SIZE-1];

    genvar g;
    generate
        for (g = 0; g < ARRAY_SIZE; g = g + 1) begin : UNPACK_INPUTS
            assign a_in_vec[g] = a_row_in[(g+1)*DATA_WIDTH-1 : g*DATA_WIDTH];
            assign b_in_vec[g] = b_col_in[(g+1)*DATA_WIDTH-1 : g*DATA_WIDTH];
        end
    endgenerate

    reg signed [DATA_WIDTH-1:0] a_skew [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];
    reg signed [DATA_WIDTH-1:0] b_skew [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];

    integer r_idx, c_idx;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (r_idx = 0; r_idx < ARRAY_SIZE; r_idx = r_idx + 1) begin
                for (c_idx = 0; c_idx < ARRAY_SIZE; c_idx = c_idx + 1) begin
                    a_skew[r_idx][c_idx] <= {DATA_WIDTH{1'b0}};
                    b_skew[r_idx][c_idx] <= {DATA_WIDTH{1'b0}};
                end
            end
        end else if (en) begin
            for (r_idx = 0; r_idx < ARRAY_SIZE; r_idx = r_idx + 1) begin
                a_skew[r_idx][0] <= a_in_vec[r_idx];
                b_skew[r_idx][0] <= b_in_vec[r_idx];
            end
            for (r_idx = 0; r_idx < ARRAY_SIZE; r_idx = r_idx + 1) begin
                for (c_idx = 1; c_idx <= r_idx - 1; c_idx = c_idx + 1) begin
                    a_skew[r_idx][c_idx] <= a_skew[r_idx][c_idx-1];
                    b_skew[r_idx][c_idx] <= b_skew[r_idx][c_idx-1];
                end
            end
        end
    end

    wire signed [DATA_WIDTH-1:0] a_pe_in [0:ARRAY_SIZE-1];
    wire signed [DATA_WIDTH-1:0] b_pe_in [0:ARRAY_SIZE-1];

    generate
        for (g = 0; g < ARRAY_SIZE; g = g + 1) begin : ASSIGN_SKEWED
            if (g == 0) begin : ROW0_DIRECT
                assign a_pe_in[g] = a_in_vec[0];
                assign b_pe_in[g] = b_in_vec[0];
            end else begin : ROWN_SKEWED
                assign a_pe_in[g] = a_skew[g][g-1];
                assign b_pe_in[g] = b_skew[g][g-1];
            end
        end
    endgenerate

    wire signed [DATA_WIDTH-1:0] h_wire [0:ARRAY_SIZE-1][0:ARRAY_SIZE];
    wire signed [DATA_WIDTH-1:0] v_wire [0:ARRAY_SIZE][0:ARRAY_SIZE-1];
    wire signed [ACC_WIDTH-1:0]  c_wire [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];

    generate
        for (g = 0; g < ARRAY_SIZE; g = g + 1) begin : BOUNDARY_CONNECT
            assign h_wire[g][0] = a_pe_in[g];
            assign v_wire[0][g] = b_pe_in[g];
        end
    endgenerate

    genvar row, col;
    generate
        for (row = 0; row < ARRAY_SIZE; row = row + 1) begin : GEN_ROW
            for (col = 0; col < ARRAY_SIZE; col = col + 1) begin : GEN_COL
                systolic_pe_clean #(
                    .DATA_WIDTH(DATA_WIDTH),
                    .ACC_WIDTH(ACC_WIDTH)
                ) u_pe_clean (
                    .clk     (clk),
                    .rst_n   (rst_n),
                    .clr_acc (clr_acc),
                    .en      (en),
                    .a_in    (h_wire[row][col]),
                    .b_in    (v_wire[row][col]),
                    .a_out   (h_wire[row][col+1]),
                    .b_out   (v_wire[row+1][col]),
                    .c_out   (c_wire[row][col])
                );

                assign c_mat_out[((row*ARRAY_SIZE+col)+1)*ACC_WIDTH-1 : (row*ARRAY_SIZE+col)*ACC_WIDTH] = c_wire[row][col];
            end
        end
    endgenerate

endmodule

module systolic_pe_clean #(
    parameter DATA_WIDTH = 16,
    parameter ACC_WIDTH  = 32
)(
    input  wire                      clk,
    input  wire                      rst_n,
    input  wire                      clr_acc,
    input  wire                      en,
    input  wire signed [DATA_WIDTH-1:0] a_in,
    input  wire signed [DATA_WIDTH-1:0] b_in,
    output reg  signed [DATA_WIDTH-1:0] a_out,
    output reg  signed [DATA_WIDTH-1:0] b_out,
    output reg  signed [ACC_WIDTH-1:0]  c_out
);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_out <= {DATA_WIDTH{1'b0}};
            b_out <= {DATA_WIDTH{1'b0}};
            c_out <= {ACC_WIDTH{1'b0}};
        end else if (en) begin
            a_out <= a_in;
            b_out <= b_in;
            if (clr_acc) begin
                c_out <= a_in * b_in;
            end else begin
                c_out <= c_out + (a_in * b_in);
            end
        end
    end

endmodule
