`timescale 1ns / 1ps

// =========================================================================
// 16x16 Signed Q8.8 Vedic Multiplier
// =========================================================================
module vedic_multiplier_q8_8 (
    input  signed [15:0] A, B,
    output signed [15:0] Result
);

    wire sign_A = A[15];
    wire sign_B = B[15];
    wire out_sign = sign_A ^ sign_B; // Output is negative if signs differ
    
    // Convert to absolute (unsigned) values for the Vedic multiplier
    wire [15:0] abs_A = sign_A ? (~A + 16'd1) : A;
    wire [15:0] abs_B = sign_B ? (~B + 16'd1) : B;
    
    wire [31:0] raw_product;
    vedic_16x16 vedic_core (
        .a(abs_A),
        .b(abs_B),
        .p(raw_product)
    );
    
    wire [31:0] signed_product = out_sign ? (~raw_product + 32'd1) : raw_product;
    
    // Extract the middle 16 bits (Truncation)
    wire [15:0] truncated_result = signed_product[23:8];

    // Extract the highest discarded fractional bit to use for rounding
    wire rounding_bit = signed_product[7];

    // Add the rounding bit to round to the nearest Q8.8 value
    assign Result = truncated_result + rounding_bit;

endmodule

// =========================================================================
// 16x16 Unsigned Vedic Multiplier
// =========================================================================
module vedic_16x16 (
    input  [15:0] a, b,
    output [31:0] p
);
    wire [15:0] q0, q1, q2, q3;
    
    // Four 8x8 multipliers
    vedic_8x8 v0 (.a(a[7:0]),  .b(b[7:0]),  .p(q0)); 
    vedic_8x8 v1 (.a(a[7:0]),  .b(b[15:8]), .p(q1)); 
    vedic_8x8 v2 (.a(a[15:8]), .b(b[7:0]),  .p(q2)); 
    vedic_8x8 v3 (.a(a[15:8]), .b(b[15:8]), .p(q3)); 
    
    // Shift and Add partial products
    assign p = {16'h0000, q0} + 
               {8'h00, q1, 8'h00} + 
               {8'h00, q2, 8'h00} + 
               {q3, 16'h0000};
endmodule

// =========================================================================
// 8x8 Vedic Multiplier
// =========================================================================
module vedic_8x8 (
    input  [7:0] a, b,
    output [15:0] p
);
    wire [7:0] q0, q1, q2, q3;
    
    // Four 4x4 multipliers
    vedic_4x4 v0 (.a(a[3:0]), .b(b[3:0]), .p(q0)); 
    vedic_4x4 v1 (.a(a[3:0]), .b(b[7:4]), .p(q1)); 
    vedic_4x4 v2 (.a(a[7:4]), .b(b[3:0]), .p(q2)); 
    vedic_4x4 v3 (.a(a[7:4]), .b(b[7:4]), .p(q3)); 
    
    // Shift and Add partial products
    assign p = {8'h00, q0} + 
               {4'h0, q1, 4'h0} + 
               {4'h0, q2, 4'h0} + 
               {q3, 8'h00};
endmodule

// =========================================================================
// 4x4 Vedic Multiplier
// =========================================================================
module vedic_4x4 (
    input  [3:0] a, b,
    output [7:0] p
);
    wire [3:0] q0, q1, q2, q3;
    
    // Four 2x2 multipliers
    vedic_2x2 v0 (.a(a[1:0]), .b(b[1:0]), .p(q0)); // LSBs
    vedic_2x2 v1 (.a(a[1:0]), .b(b[3:2]), .p(q1)); // Cross 1
    vedic_2x2 v2 (.a(a[3:2]), .b(b[1:0]), .p(q2)); // Cross 2
    vedic_2x2 v3 (.a(a[3:2]), .b(b[3:2]), .p(q3)); // MSBs
    
    // Shift and Add partial products
    // p = q0 + (q1 << 2) + (q2 << 2) + (q3 << 4)
    assign p = {4'b0000, q0} + 
               {2'b00, q1, 2'b00} + 
               {2'b00, q2, 2'b00} + 
               {q3, 4'b0000};
endmodule

// =========================================================================
// 2x2 Vedic Multiplier
// =========================================================================
module vedic_2x2 (
    input  [1:0] a, b,
    output [3:0] p
);
    wire w1, w2, w3, w4;
    
    // Vertical multiplication
    assign p[0] = a[0] & b[0];
    
    // Cross multiplication and addition
    assign w1 = a[1] & b[0];
    assign w2 = a[0] & b[1];
    half_adder ha1 (.a(w1), .b(w2), .sum(p[1]), .cout(w3));
    
    // Vertical multiplication and addition of carry
    assign w4 = a[1] & b[1];
    half_adder ha2 (.a(w3), .b(w4), .sum(p[2]), .cout(p[3]));
endmodule

// =========================================================================
// Half Adder
// =========================================================================
module half_adder (
    input a, b,
    output sum, cout
);
    assign sum = a ^ b;
    assign cout = a & b;
endmodule

