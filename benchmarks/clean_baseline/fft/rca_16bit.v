`timescale 1ns / 1ps

// 16-Bit Ripple Carry Adder / Subtractor
module rca_16bit (
    input  signed [15:0] A,
    input  signed [15:0] B,
    input  sub,            // Control signal: 0 = Add, 1 = Subtract
    output signed [15:0] S,
    output cout            // Final carry-out / borrow-out
);

    wire [16:0] carry;     // Carry chain connecting the full adders
    wire [15:0] b_eff;     // Effective B input (inverted if subtracting)
    wire [15:0] raw_sum;

    assign carry[0] = sub; 

    genvar i;
    generate
        for (i = 0; i < 16; i = i + 1) begin : adder_chain
            // If sub = 1, 1 XOR B[i] = ~B[i] (Inverted)
            // If sub = 0, 0 XOR B[i] = B[i]  (Unchanged)
            assign b_eff[i] = B[i] ^ sub; 

            full_adder fa_inst (
                .a(A[i]),
                .b(b_eff[i]),
                .cin(carry[i]),
                .sum(raw_sum[i]),
                .cout(carry[i+1])
            );
        end
    endgenerate

    assign cout = carry[16];

    // Overflow detection
    wire overflow = (A[15] == b_eff[15]) && (raw_sum[15] != A[15]);

    // If overflow happened:
    //   - And inputs were positive (A[15]==0), clamp to Max Positive (16'h7FFF)
    //   - And inputs were negative (A[15]==1), clamp to Min Negative (16'h8000)
    // If no overflow, output the raw_sum
    assign S = overflow ? (A[15] ? 16'h8000 : 16'h7FFF) : raw_sum;

endmodule

module full_adder (
    input a, b, cin,
    output sum, cout
);
    assign sum = a ^ b ^ cin;
    assign cout = (a & b) | (cin & (a ^ b));
endmodule

