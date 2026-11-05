// 3x3 2D Systolic Array for Matrix Multiplication (C = A x B)
module systolic_array_gemm #(
    parameter ARRAY_SIZE = 3,
    parameter DATA_WIDTH = 16,
    parameter ACC_WIDTH  = 32
)(
    input clk,
    input rst_n,
    input en,
    input clr_acc,

    // Parallel matrix boundary inputs
    input signed [ARRAY_SIZE*DATA_WIDTH-1:0] a_row_in,
    input signed [ARRAY_SIZE*DATA_WIDTH-1:0] b_col_in,

    // Accumulated output matrix results: C[i][j]
    output signed [ARRAY_SIZE*ARRAY_SIZE*ACC_WIDTH-1:0] c_mat_out
);

    // Unpacked internal input buses
    wire signed [DATA_WIDTH-1:0] a_in_vec [0:ARRAY_SIZE-1];
    wire signed [DATA_WIDTH-1:0] b_in_vec [0:ARRAY_SIZE-1];

    genvar g;
    generate
        for (g = 0; g < ARRAY_SIZE; g = g + 1) begin : UNPACK_INPUTS
            assign a_in_vec[g] = a_row_in[(g+1)*DATA_WIDTH-1 : g*DATA_WIDTH];
            assign b_in_vec[g] = b_col_in[(g+1)*DATA_WIDTH-1 : g*DATA_WIDTH];
        end
    endgenerate

    // ------------------------------------------------------------------------
    // Wavefront Skew Buffers (Aligns A row i by i cycles, B col j by j cycles)
    // ------------------------------------------------------------------------
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
            // Stage 0 inputs
            for (r_idx = 0; r_idx < ARRAY_SIZE; r_idx = r_idx + 1) begin
                a_skew[r_idx][0] <= a_in_vec[r_idx];
                b_skew[r_idx][0] <= b_in_vec[r_idx];
            end
            // Subsequent pipeline delay stages. Row/col r_idx needs exactly
            // r_idx total registered stages so that a_skew[r_idx][r_idx-1] 
            // carries exactly r_idx cycles of delay; the loop therefore only 
            // needs to shift up through c_idx = r_idx-1
            for (r_idx = 0; r_idx < ARRAY_SIZE; r_idx = r_idx + 1) begin
                for (c_idx = 1; c_idx <= r_idx - 1; c_idx = c_idx + 1) begin
                    a_skew[r_idx][c_idx] <= a_skew[r_idx][c_idx-1];
                    b_skew[r_idx][c_idx] <= b_skew[r_idx][c_idx-1];
                end
            end
        end
    end

    // Boundary wires feeding the systolic perimeter
    wire signed [DATA_WIDTH-1:0] a_pe_in [0:ARRAY_SIZE-1];
    wire signed [DATA_WIDTH-1:0] b_pe_in [0:ARRAY_SIZE-1];

    generate
        for (g = 0; g < ARRAY_SIZE; g = g + 1) begin : ASSIGN_SKEWED
            // g cycles of delay for row/col g: direct wire (0 cycles) for
            // g==0, otherwise the g-th registered stage (a_skew[g][g-1],
            // which holds a value delayed by exactly g cycles. g==0 is 
            // special-cased as its own generate branch (rather than a 
            // runtime ternary) so the g-1 index is never even elaborated 
            // for that case.
            if (g == 0) begin : ROW0_DIRECT
                assign a_pe_in[g] = a_in_vec[0];
                assign b_pe_in[g] = b_in_vec[0];
            end else begin : ROWN_SKEWED
                assign a_pe_in[g] = a_skew[g][g-1];
                assign b_pe_in[g] = b_skew[g][g-1];
            end
        end
    endgenerate

    // ------------------------------------------------------------------------
    // Internal PE Interconnect Mesh
    // ------------------------------------------------------------------------
    wire signed [DATA_WIDTH-1:0] h_wire [0:ARRAY_SIZE-1][0:ARRAY_SIZE];
    wire signed [DATA_WIDTH-1:0] v_wire [0:ARRAY_SIZE][0:ARRAY_SIZE-1];
    wire signed [ACC_WIDTH-1:0]  c_wire [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];

    generate
        for (g = 0; g < ARRAY_SIZE; g = g + 1) begin : BOUNDARY_CONNECT
            assign h_wire[g][0] = a_pe_in[g];
            assign v_wire[0][g] = b_pe_in[g];
        end
    endgenerate

    // 2D Array Instantiation
    genvar row, col;
    generate
        for (row = 0; row < ARRAY_SIZE; row = row + 1) begin : GEN_ROW
            for (col = 0; col < ARRAY_SIZE; col = col + 1) begin : GEN_COL
                systolic_pe #(
                    .DATA_WIDTH(DATA_WIDTH),
                    .ACC_WIDTH(ACC_WIDTH)
                ) u_pe (
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

                // Pack 2D outputs into flat output bus
                assign c_mat_out[((row*ARRAY_SIZE+col)+1)*ACC_WIDTH-1 : (row*ARRAY_SIZE+col)*ACC_WIDTH] = c_wire[row][col];
            end
        end
    endgenerate

endmodule

