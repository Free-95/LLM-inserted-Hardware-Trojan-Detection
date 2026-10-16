// Testbench with golden reference values computed independently via numpy matrix 
// multiply (exact integer arithmetic)
`timescale 1ns / 1ps

module tb_systolic_array_gemm;

    parameter ARRAY_SIZE = 3;
    parameter DATA_WIDTH = 16;
    parameter ACC_WIDTH  = 32;

    reg clk;
    reg rst_n;
    reg en;
    reg clr_acc;
    reg signed [ARRAY_SIZE*DATA_WIDTH-1:0] a_row_in;
    reg signed [ARRAY_SIZE*DATA_WIDTH-1:0] b_col_in;
    wire signed [ARRAY_SIZE*ARRAY_SIZE*ACC_WIDTH-1:0] c_mat_out;

    integer fail_count;
    integer first_fail_code;
    integer vectors_checked;

    task automatic report_fail(input [8*200-1:0] msg);
        begin
            fail_count = fail_count + 1;
            if (first_fail_code == -1) first_fail_code = fail_count;
            $display("[FAIL] %0s (time=%0t)", msg, $time);
        end
    endtask

    systolic_array_gemm #(
        .ARRAY_SIZE(ARRAY_SIZE), .DATA_WIDTH(DATA_WIDTH), .ACC_WIDTH(ACC_WIDTH)
    ) dut (
        .clk(clk), .rst_n(rst_n), .en(en), .clr_acc(clr_acc),
        .a_row_in(a_row_in), .b_col_in(b_col_in), .c_mat_out(c_mat_out)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    // ------------------------------------------------------------------
    // check_elem: compares one C[row][col] accumulator against the golden
    // value, reading via hierarchical c_wire[][] reference (the PE grid's
    // own internal accumulators) rather than hand-computed bit-slice
    // arithmetic on the flattened c_mat_out bus.
    // ------------------------------------------------------------------
    task automatic check_elem(input [8*64-1:0] vec_name, input integer row, input integer col,
                              input integer got, input integer expected);
        begin
            if (got !== expected) begin
                report_fail({vec_name, ": matrix element mismatch"});
                $display("        C[%0d][%0d]: got=%0d expected=%0d", row, col, got, expected);
            end
        end
    endtask

    // ------------------------------------------------------------------
    // run_gemm: feeds 3 cycles of outer-product data (k=0,1,2) then lets
    // the wavefront drain, matching the design's documented operating mode.
    // ------------------------------------------------------------------
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
            repeat (8) @(posedge clk); // let the wavefront fully drain (3-cycle
                                       // skew for row/col 2 + array traversal)
        end
    endtask

    initial begin
        if ($test$plusargs("vcd")) begin
            $dumpfile("tb_systolic_array_gemm.vcd");
            $dumpvars(0, tb_systolic_array_gemm);
        end

        fail_count = 0;
        first_fail_code = -1;
        vectors_checked = 0;

        rst_n = 0; en = 0; clr_acc = 0; a_row_in = 0; b_col_in = 0;
        #20 rst_n = 1; en = 1;
        #10;

        // ---- Reset sanity: all accumulators must be 0 ----
        if (dut.c_wire[0][0] !== 0) report_fail("reset: c_wire[0][0] not zero after reset");
        if (dut.c_wire[0][1] !== 0) report_fail("reset: c_wire[0][1] not zero after reset");
        if (dut.c_wire[0][2] !== 0) report_fail("reset: c_wire[0][2] not zero after reset");
        if (dut.c_wire[1][0] !== 0) report_fail("reset: c_wire[1][0] not zero after reset");
        if (dut.c_wire[1][1] !== 0) report_fail("reset: c_wire[1][1] not zero after reset");
        if (dut.c_wire[1][2] !== 0) report_fail("reset: c_wire[1][2] not zero after reset");
        if (dut.c_wire[2][0] !== 0) report_fail("reset: c_wire[2][0] not zero after reset");
        if (dut.c_wire[2][1] !== 0) report_fail("reset: c_wire[2][1] not zero after reset");
        if (dut.c_wire[2][2] !== 0) report_fail("reset: c_wire[2][2] not zero after reset");

        // ---- Vector: identity_times_const ----
        // A =
        //   [1, 0, 0]
        //   [0, 1, 0]
        //   [0, 0, 1]
        // B =
        //   [2, 3, 4]
        //   [5, 6, 7]
        //   [8, 9, 1]
        run_gemm(16'sh0001,16'sh0000,16'sh0000, 16'sh0000,16'sh0001,16'sh0000, 16'sh0000,16'sh0000,16'sh0001, 16'sh0002,16'sh0003,16'sh0004, 16'sh0005,16'sh0006,16'sh0007, 16'sh0008,16'sh0009,16'sh0001);
        check_elem("identity_times_const", 0, 0, dut.c_wire[0][0], 2);
        check_elem("identity_times_const", 0, 1, dut.c_wire[0][1], 3);
        check_elem("identity_times_const", 0, 2, dut.c_wire[0][2], 4);
        check_elem("identity_times_const", 1, 0, dut.c_wire[1][0], 5);
        check_elem("identity_times_const", 1, 1, dut.c_wire[1][1], 6);
        check_elem("identity_times_const", 1, 2, dut.c_wire[1][2], 7);
        check_elem("identity_times_const", 2, 0, dut.c_wire[2][0], 8);
        check_elem("identity_times_const", 2, 1, dut.c_wire[2][1], 9);
        check_elem("identity_times_const", 2, 2, dut.c_wire[2][2], 1);
        vectors_checked = vectors_checked + 1;

        // ---- Vector: general_times_identity ----
        // A =
        //   [1, 2, 3]
        //   [4, 5, 6]
        //   [7, 8, 9]
        // B =
        //   [1, 0, 0]
        //   [0, 1, 0]
        //   [0, 0, 1]
        run_gemm(16'sh0001,16'sh0004,16'sh0007, 16'sh0002,16'sh0005,16'sh0008, 16'sh0003,16'sh0006,16'sh0009, 16'sh0001,16'sh0000,16'sh0000, 16'sh0000,16'sh0001,16'sh0000, 16'sh0000,16'sh0000,16'sh0001);
        check_elem("general_times_identity", 0, 0, dut.c_wire[0][0], 1);
        check_elem("general_times_identity", 0, 1, dut.c_wire[0][1], 2);
        check_elem("general_times_identity", 0, 2, dut.c_wire[0][2], 3);
        check_elem("general_times_identity", 1, 0, dut.c_wire[1][0], 4);
        check_elem("general_times_identity", 1, 1, dut.c_wire[1][1], 5);
        check_elem("general_times_identity", 1, 2, dut.c_wire[1][2], 6);
        check_elem("general_times_identity", 2, 0, dut.c_wire[2][0], 7);
        check_elem("general_times_identity", 2, 1, dut.c_wire[2][1], 8);
        check_elem("general_times_identity", 2, 2, dut.c_wire[2][2], 9);
        vectors_checked = vectors_checked + 1;

        // ---- Vector: general_general ----
        // A =
        //   [1, 2, 3]
        //   [4, 5, 6]
        //   [7, 8, 9]
        // B =
        //   [9, 8, 7]
        //   [6, 5, 4]
        //   [3, 2, 1]
        run_gemm(16'sh0001,16'sh0004,16'sh0007, 16'sh0002,16'sh0005,16'sh0008, 16'sh0003,16'sh0006,16'sh0009, 16'sh0009,16'sh0008,16'sh0007, 16'sh0006,16'sh0005,16'sh0004, 16'sh0003,16'sh0002,16'sh0001);
        check_elem("general_general", 0, 0, dut.c_wire[0][0], 30);
        check_elem("general_general", 0, 1, dut.c_wire[0][1], 24);
        check_elem("general_general", 0, 2, dut.c_wire[0][2], 18);
        check_elem("general_general", 1, 0, dut.c_wire[1][0], 84);
        check_elem("general_general", 1, 1, dut.c_wire[1][1], 69);
        check_elem("general_general", 1, 2, dut.c_wire[1][2], 54);
        check_elem("general_general", 2, 0, dut.c_wire[2][0], 138);
        check_elem("general_general", 2, 1, dut.c_wire[2][1], 114);
        check_elem("general_general", 2, 2, dut.c_wire[2][2], 90);
        vectors_checked = vectors_checked + 1;

        // ---- Vector: negative_values ----
        // A =
        //   [-1, 2, -3]
        //   [4, -5, 6]
        //   [-7, 8, -9]
        // B =
        //   [1, -1, 1]
        //   [-1, 1, -1]
        //   [1, -1, 1]
        run_gemm(16'shffff,16'sh0004,16'shfff9, 16'sh0002,16'shfffb,16'sh0008, 16'shfffd,16'sh0006,16'shfff7, 16'sh0001,16'shffff,16'sh0001, 16'shffff,16'sh0001,16'shffff, 16'sh0001,16'shffff,16'sh0001);
        check_elem("negative_values", 0, 0, dut.c_wire[0][0], -6);
        check_elem("negative_values", 0, 1, dut.c_wire[0][1], 6);
        check_elem("negative_values", 0, 2, dut.c_wire[0][2], -6);
        check_elem("negative_values", 1, 0, dut.c_wire[1][0], 15);
        check_elem("negative_values", 1, 1, dut.c_wire[1][1], -15);
        check_elem("negative_values", 1, 2, dut.c_wire[1][2], 15);
        check_elem("negative_values", 2, 0, dut.c_wire[2][0], -24);
        check_elem("negative_values", 2, 1, dut.c_wire[2][1], 24);
        check_elem("negative_values", 2, 2, dut.c_wire[2][2], -24);
        vectors_checked = vectors_checked + 1;

        // ---- Vector: zero_matrix_A ----
        // A =
        //   [0, 0, 0]
        //   [0, 0, 0]
        //   [0, 0, 0]
        // B =
        //   [1, 2, 3]
        //   [4, 5, 6]
        //   [7, 8, 9]
        run_gemm(16'sh0000,16'sh0000,16'sh0000, 16'sh0000,16'sh0000,16'sh0000, 16'sh0000,16'sh0000,16'sh0000, 16'sh0001,16'sh0002,16'sh0003, 16'sh0004,16'sh0005,16'sh0006, 16'sh0007,16'sh0008,16'sh0009);
        check_elem("zero_matrix_A", 0, 0, dut.c_wire[0][0], 0);
        check_elem("zero_matrix_A", 0, 1, dut.c_wire[0][1], 0);
        check_elem("zero_matrix_A", 0, 2, dut.c_wire[0][2], 0);
        check_elem("zero_matrix_A", 1, 0, dut.c_wire[1][0], 0);
        check_elem("zero_matrix_A", 1, 1, dut.c_wire[1][1], 0);
        check_elem("zero_matrix_A", 1, 2, dut.c_wire[1][2], 0);
        check_elem("zero_matrix_A", 2, 0, dut.c_wire[2][0], 0);
        check_elem("zero_matrix_A", 2, 1, dut.c_wire[2][1], 0);
        check_elem("zero_matrix_A", 2, 2, dut.c_wire[2][2], 0);
        vectors_checked = vectors_checked + 1;

        // ---- Vector: zero_matrix_B ----
        // A =
        //   [1, 2, 3]
        //   [4, 5, 6]
        //   [7, 8, 9]
        // B =
        //   [0, 0, 0]
        //   [0, 0, 0]
        //   [0, 0, 0]
        run_gemm(16'sh0001,16'sh0004,16'sh0007, 16'sh0002,16'sh0005,16'sh0008, 16'sh0003,16'sh0006,16'sh0009, 16'sh0000,16'sh0000,16'sh0000, 16'sh0000,16'sh0000,16'sh0000, 16'sh0000,16'sh0000,16'sh0000);
        check_elem("zero_matrix_B", 0, 0, dut.c_wire[0][0], 0);
        check_elem("zero_matrix_B", 0, 1, dut.c_wire[0][1], 0);
        check_elem("zero_matrix_B", 0, 2, dut.c_wire[0][2], 0);
        check_elem("zero_matrix_B", 1, 0, dut.c_wire[1][0], 0);
        check_elem("zero_matrix_B", 1, 1, dut.c_wire[1][1], 0);
        check_elem("zero_matrix_B", 1, 2, dut.c_wire[1][2], 0);
        check_elem("zero_matrix_B", 2, 0, dut.c_wire[2][0], 0);
        check_elem("zero_matrix_B", 2, 1, dut.c_wire[2][1], 0);
        check_elem("zero_matrix_B", 2, 2, dut.c_wire[2][2], 0);
        vectors_checked = vectors_checked + 1;

        // ---- Vector: asymmetric_1 ----
        // A =
        //   [3, -1, 0]
        //   [0, 2, -4]
        //   [5, 0, 1]
        // B =
        //   [1, 0, 2]
        //   [-3, 4, 0]
        //   [0, 1, -1]
        run_gemm(16'sh0003,16'sh0000,16'sh0005, 16'shffff,16'sh0002,16'sh0000, 16'sh0000,16'shfffc,16'sh0001, 16'sh0001,16'sh0000,16'sh0002, 16'shfffd,16'sh0004,16'sh0000, 16'sh0000,16'sh0001,16'shffff);
        check_elem("asymmetric_1", 0, 0, dut.c_wire[0][0], 6);
        check_elem("asymmetric_1", 0, 1, dut.c_wire[0][1], -4);
        check_elem("asymmetric_1", 0, 2, dut.c_wire[0][2], 6);
        check_elem("asymmetric_1", 1, 0, dut.c_wire[1][0], -6);
        check_elem("asymmetric_1", 1, 1, dut.c_wire[1][1], 4);
        check_elem("asymmetric_1", 1, 2, dut.c_wire[1][2], 4);
        check_elem("asymmetric_1", 2, 0, dut.c_wire[2][0], 5);
        check_elem("asymmetric_1", 2, 1, dut.c_wire[2][1], 1);
        check_elem("asymmetric_1", 2, 2, dut.c_wire[2][2], 9);
        vectors_checked = vectors_checked + 1;

        // ---- Vector: asymmetric_2 ----
        // A =
        //   [7, -2, 3]
        //   [-1, 5, 0]
        //   [2, -3, 4]
        // B =
        //   [0, 1, -2]
        //   [3, -1, 1]
        //   [-2, 0, 5]
        run_gemm(16'sh0007,16'shffff,16'sh0002, 16'shfffe,16'sh0005,16'shfffd, 16'sh0003,16'sh0000,16'sh0004, 16'sh0000,16'sh0001,16'shfffe, 16'sh0003,16'shffff,16'sh0001, 16'shfffe,16'sh0000,16'sh0005);
        check_elem("asymmetric_2", 0, 0, dut.c_wire[0][0], -12);
        check_elem("asymmetric_2", 0, 1, dut.c_wire[0][1], 9);
        check_elem("asymmetric_2", 0, 2, dut.c_wire[0][2], -1);
        check_elem("asymmetric_2", 1, 0, dut.c_wire[1][0], 15);
        check_elem("asymmetric_2", 1, 1, dut.c_wire[1][1], -6);
        check_elem("asymmetric_2", 1, 2, dut.c_wire[1][2], 7);
        check_elem("asymmetric_2", 2, 0, dut.c_wire[2][0], -17);
        check_elem("asymmetric_2", 2, 1, dut.c_wire[2][1], 5);
        check_elem("asymmetric_2", 2, 2, dut.c_wire[2][2], 13);
        vectors_checked = vectors_checked + 1;

        // ---- Vector: row_col_distinct ----
        // A =
        //   [1, 0, 0]
        //   [0, 2, 0]
        //   [0, 0, 3]
        // B =
        //   [1, 1, 1]
        //   [2, 2, 2]
        //   [3, 3, 3]
        run_gemm(16'sh0001,16'sh0000,16'sh0000, 16'sh0000,16'sh0002,16'sh0000, 16'sh0000,16'sh0000,16'sh0003, 16'sh0001,16'sh0001,16'sh0001, 16'sh0002,16'sh0002,16'sh0002, 16'sh0003,16'sh0003,16'sh0003);
        check_elem("row_col_distinct", 0, 0, dut.c_wire[0][0], 1);
        check_elem("row_col_distinct", 0, 1, dut.c_wire[0][1], 1);
        check_elem("row_col_distinct", 0, 2, dut.c_wire[0][2], 1);
        check_elem("row_col_distinct", 1, 0, dut.c_wire[1][0], 4);
        check_elem("row_col_distinct", 1, 1, dut.c_wire[1][1], 4);
        check_elem("row_col_distinct", 1, 2, dut.c_wire[1][2], 4);
        check_elem("row_col_distinct", 2, 0, dut.c_wire[2][0], 9);
        check_elem("row_col_distinct", 2, 1, dut.c_wire[2][1], 9);
        check_elem("row_col_distinct", 2, 2, dut.c_wire[2][2], 9);
        vectors_checked = vectors_checked + 1;

        // ---- Vector: max_small_values ----
        // A =
        //   [100, 100, 100]
        //   [100, 100, 100]
        //   [100, 100, 100]
        // B =
        //   [100, 100, 100]
        //   [100, 100, 100]
        //   [100, 100, 100]
        run_gemm(16'sh0064,16'sh0064,16'sh0064, 16'sh0064,16'sh0064,16'sh0064, 16'sh0064,16'sh0064,16'sh0064, 16'sh0064,16'sh0064,16'sh0064, 16'sh0064,16'sh0064,16'sh0064, 16'sh0064,16'sh0064,16'sh0064);
        check_elem("max_small_values", 0, 0, dut.c_wire[0][0], 30000);
        check_elem("max_small_values", 0, 1, dut.c_wire[0][1], 30000);
        check_elem("max_small_values", 0, 2, dut.c_wire[0][2], 30000);
        check_elem("max_small_values", 1, 0, dut.c_wire[1][0], 30000);
        check_elem("max_small_values", 1, 1, dut.c_wire[1][1], 30000);
        check_elem("max_small_values", 1, 2, dut.c_wire[1][2], 30000);
        check_elem("max_small_values", 2, 0, dut.c_wire[2][0], 30000);
        check_elem("max_small_values", 2, 1, dut.c_wire[2][1], 30000);
        check_elem("max_small_values", 2, 2, dut.c_wire[2][2], 30000);
        vectors_checked = vectors_checked + 1;

        // ---- Vector: single_nonzero_A00 ----
        // A =
        //   [5, 0, 0]
        //   [0, 0, 0]
        //   [0, 0, 0]
        // B =
        //   [1, 2, 3]
        //   [4, 5, 6]
        //   [7, 8, 9]
        run_gemm(16'sh0005,16'sh0000,16'sh0000, 16'sh0000,16'sh0000,16'sh0000, 16'sh0000,16'sh0000,16'sh0000, 16'sh0001,16'sh0002,16'sh0003, 16'sh0004,16'sh0005,16'sh0006, 16'sh0007,16'sh0008,16'sh0009);
        check_elem("single_nonzero_A00", 0, 0, dut.c_wire[0][0], 5);
        check_elem("single_nonzero_A00", 0, 1, dut.c_wire[0][1], 10);
        check_elem("single_nonzero_A00", 0, 2, dut.c_wire[0][2], 15);
        check_elem("single_nonzero_A00", 1, 0, dut.c_wire[1][0], 0);
        check_elem("single_nonzero_A00", 1, 1, dut.c_wire[1][1], 0);
        check_elem("single_nonzero_A00", 1, 2, dut.c_wire[1][2], 0);
        check_elem("single_nonzero_A00", 2, 0, dut.c_wire[2][0], 0);
        check_elem("single_nonzero_A00", 2, 1, dut.c_wire[2][1], 0);
        check_elem("single_nonzero_A00", 2, 2, dut.c_wire[2][2], 0);
        vectors_checked = vectors_checked + 1;

        // ---- Vector: single_nonzero_A22 ----
        // A =
        //   [0, 0, 0]
        //   [0, 0, 0]
        //   [0, 0, 5]
        // B =
        //   [1, 2, 3]
        //   [4, 5, 6]
        //   [7, 8, 9]
        run_gemm(16'sh0000,16'sh0000,16'sh0000, 16'sh0000,16'sh0000,16'sh0000, 16'sh0000,16'sh0000,16'sh0005, 16'sh0001,16'sh0002,16'sh0003, 16'sh0004,16'sh0005,16'sh0006, 16'sh0007,16'sh0008,16'sh0009);
        check_elem("single_nonzero_A22", 0, 0, dut.c_wire[0][0], 0);
        check_elem("single_nonzero_A22", 0, 1, dut.c_wire[0][1], 0);
        check_elem("single_nonzero_A22", 0, 2, dut.c_wire[0][2], 0);
        check_elem("single_nonzero_A22", 1, 0, dut.c_wire[1][0], 0);
        check_elem("single_nonzero_A22", 1, 1, dut.c_wire[1][1], 0);
        check_elem("single_nonzero_A22", 1, 2, dut.c_wire[1][2], 0);
        check_elem("single_nonzero_A22", 2, 0, dut.c_wire[2][0], 35);
        check_elem("single_nonzero_A22", 2, 1, dut.c_wire[2][1], 40);
        check_elem("single_nonzero_A22", 2, 2, dut.c_wire[2][2], 45);
        vectors_checked = vectors_checked + 1;

        // ---- Vector: alternating_signs ----
        // A =
        //   [1, -2, 3]
        //   [-4, 5, -6]
        //   [7, -8, 9]
        // B =
        //   [-1, 2, -3]
        //   [4, -5, 6]
        //   [-7, 8, -9]
        run_gemm(16'sh0001,16'shfffc,16'sh0007, 16'shfffe,16'sh0005,16'shfff8, 16'sh0003,16'shfffa,16'sh0009, 16'shffff,16'sh0002,16'shfffd, 16'sh0004,16'shfffb,16'sh0006, 16'shfff9,16'sh0008,16'shfff7);
        check_elem("alternating_signs", 0, 0, dut.c_wire[0][0], -30);
        check_elem("alternating_signs", 0, 1, dut.c_wire[0][1], 36);
        check_elem("alternating_signs", 0, 2, dut.c_wire[0][2], -42);
        check_elem("alternating_signs", 1, 0, dut.c_wire[1][0], 66);
        check_elem("alternating_signs", 1, 1, dut.c_wire[1][1], -81);
        check_elem("alternating_signs", 1, 2, dut.c_wire[1][2], 96);
        check_elem("alternating_signs", 2, 0, dut.c_wire[2][0], -102);
        check_elem("alternating_signs", 2, 1, dut.c_wire[2][1], 126);
        check_elem("alternating_signs", 2, 2, dut.c_wire[2][2], -150);
        vectors_checked = vectors_checked + 1;

        // ---- Back-to-back runs: a second GEMM immediately after the first,
        //      no idle gap beyond run_gemm's own drain, checking for state
        //      leakage between runs ----
        begin : back_to_back
        run_gemm(16'sh0001,16'sh0004,16'sh0007, 16'sh0002,16'sh0005,16'sh0008, 16'sh0003,16'sh0006,16'sh0009, 16'sh0001,16'sh0000,16'sh0000, 16'sh0000,16'sh0001,16'sh0000, 16'sh0000,16'sh0000,16'sh0001);
            check_elem("back_to_back_1", 0, 0, dut.c_wire[0][0], 1);
            check_elem("back_to_back_1", 0, 1, dut.c_wire[0][1], 2);
            check_elem("back_to_back_1", 0, 2, dut.c_wire[0][2], 3);
            check_elem("back_to_back_1", 1, 0, dut.c_wire[1][0], 4);
            check_elem("back_to_back_1", 1, 1, dut.c_wire[1][1], 5);
            check_elem("back_to_back_1", 1, 2, dut.c_wire[1][2], 6);
            check_elem("back_to_back_1", 2, 0, dut.c_wire[2][0], 7);
            check_elem("back_to_back_1", 2, 1, dut.c_wire[2][1], 8);
            check_elem("back_to_back_1", 2, 2, dut.c_wire[2][2], 9);
        run_gemm(16'sh0002,16'sh0000,16'sh0001, 16'sh0000,16'sh0003,16'sh0000, 16'sh0001,16'sh0000,16'sh0004, 16'sh0001,16'sh0001,16'sh0000, 16'sh0000,16'sh0001,16'sh0001, 16'sh0001,16'sh0000,16'sh0001);
            check_elem("back_to_back_2", 0, 0, dut.c_wire[0][0], 3);
            check_elem("back_to_back_2", 0, 1, dut.c_wire[0][1], 2);
            check_elem("back_to_back_2", 0, 2, dut.c_wire[0][2], 1);
            check_elem("back_to_back_2", 1, 0, dut.c_wire[1][0], 0);
            check_elem("back_to_back_2", 1, 1, dut.c_wire[1][1], 3);
            check_elem("back_to_back_2", 1, 2, dut.c_wire[1][2], 3);
            check_elem("back_to_back_2", 2, 0, dut.c_wire[2][0], 5);
            check_elem("back_to_back_2", 2, 1, dut.c_wire[2][1], 1);
            check_elem("back_to_back_2", 2, 2, dut.c_wire[2][2], 4);
        end

        // ---- Reset mid-computation: assert reset while a GEMM is in
        //      flight (mid-skew/accumulate), confirm clean recovery ----
        begin : reset_midflight
            @(posedge clk);
            clr_acc <= 1'b1;
            a_row_in <= {16'sd3, 16'sd2, 16'sd1};
            b_col_in <= {16'sd3, 16'sd2, 16'sd1};
            @(posedge clk);
            clr_acc <= 1'b0;
            a_row_in <= {16'sd6, 16'sd5, 16'sd4};
            b_col_in <= {16'sd6, 16'sd5, 16'sd4};
            repeat (2) @(posedge clk);
            rst_n <= 1'b0;
            repeat (3) @(posedge clk);
            if (dut.c_wire[0][0] !== 0) report_fail("reset_midflight: c_wire[0][0] not zero right after reset");
            if (dut.c_wire[0][1] !== 0) report_fail("reset_midflight: c_wire[0][1] not zero right after reset");
            if (dut.c_wire[0][2] !== 0) report_fail("reset_midflight: c_wire[0][2] not zero right after reset");
            if (dut.c_wire[1][0] !== 0) report_fail("reset_midflight: c_wire[1][0] not zero right after reset");
            if (dut.c_wire[1][1] !== 0) report_fail("reset_midflight: c_wire[1][1] not zero right after reset");
            if (dut.c_wire[1][2] !== 0) report_fail("reset_midflight: c_wire[1][2] not zero right after reset");
            if (dut.c_wire[2][0] !== 0) report_fail("reset_midflight: c_wire[2][0] not zero right after reset");
            if (dut.c_wire[2][1] !== 0) report_fail("reset_midflight: c_wire[2][1] not zero right after reset");
            if (dut.c_wire[2][2] !== 0) report_fail("reset_midflight: c_wire[2][2] not zero right after reset");
            rst_n <= 1'b1;
            a_row_in <= 0; b_col_in <= 0;
            repeat (3) @(posedge clk);
        run_gemm(16'sh0001,16'sh0004,16'sh0007, 16'sh0002,16'sh0005,16'sh0008, 16'sh0003,16'sh0006,16'sh0009, 16'sh0001,16'sh0000,16'sh0000, 16'sh0000,16'sh0001,16'sh0000, 16'sh0000,16'sh0000,16'sh0001);
            check_elem("reset_midflight_recovery", 0, 0, dut.c_wire[0][0], 1);
            check_elem("reset_midflight_recovery", 0, 1, dut.c_wire[0][1], 2);
            check_elem("reset_midflight_recovery", 0, 2, dut.c_wire[0][2], 3);
            check_elem("reset_midflight_recovery", 1, 0, dut.c_wire[1][0], 4);
            check_elem("reset_midflight_recovery", 1, 1, dut.c_wire[1][1], 5);
            check_elem("reset_midflight_recovery", 1, 2, dut.c_wire[1][2], 6);
            check_elem("reset_midflight_recovery", 2, 0, dut.c_wire[2][0], 7);
            check_elem("reset_midflight_recovery", 2, 1, dut.c_wire[2][1], 8);
            check_elem("reset_midflight_recovery", 2, 2, dut.c_wire[2][2], 9);
        end

        // ---- en=0 gating check: while en is deasserted mid-sequence, no
        //      accumulator update should occur ----
        begin : en_gating
            reg signed [31:0] snapshot00;
            @(posedge clk);
            clr_acc <= 1'b1;
            a_row_in <= {16'sd9, 16'sd9, 16'sd9};
            b_col_in <= {16'sd9, 16'sd9, 16'sd9};
            @(posedge clk);
            // clr_acc and en must drop at the same edge
            clr_acc <= 1'b0; en <= 1'b0;
            @(posedge clk);
            snapshot00 = dut.c_wire[0][0];
            a_row_in <= {16'sd1, 16'sd1, 16'sd1};
            b_col_in <= {16'sd1, 16'sd1, 16'sd1};
            repeat (4) @(posedge clk);
            if (dut.c_wire[0][0] !== snapshot00)
                report_fail("en_gating: c_wire[0][0] changed while en was deasserted");
            en <= 1'b1;
            a_row_in <= 0; b_col_in <= 0;
            repeat (8) @(posedge clk);
        end

        #100;
        $display("[*] Checked %0d matrix-multiply vectors (%0d elements each).", vectors_checked, 9);
        if (fail_count == 0) begin
            $display("[+] All checks passed: reset sanity, %0d golden-reference GEMM vectors, back-to-back runs, mid-flight reset recovery, en-gating.", vectors_checked);
            $display("SIMULATION PASSED");
        end else begin
            $display("[-] %0d check(s) failed (first failing check index: %0d).", fail_count, first_fail_code);
            $display("SIMULATION FAILED (code=%0d mismatches)", fail_count);
        end
        $finish;
    end

    initial begin
        #2000000;
        $display("SIMULATION FAILED (code=999 global_timeout)");
        $finish;
    end

endmodule

