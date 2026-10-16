`timescale 1ns / 1ps

module butterfly_2point (
    input clk,
    input reset_n,
    
    // 32-bit Complex Buses: [31:16] Real Q8.8, [15:0] Imaginary Q8.8
    input [31:0] num1,     
    input [31:0] num2,     
    input [31:0] W,        
    
    output [31:0] result1, // Y0 = X0 + (X1 * W)
    output [31:0] result2, // Y1 = X0 - (X1 * W)
    output valid_out       // High when pipelined data is ready
);

    wire valid1, valid2;

    // -------------------------------------------------------
    // Upper Wing Calculation: X0 + (X1 * W)
    // -------------------------------------------------------
    cpx_mad upper_wing (
        .clk(clk),
        .reset_n(reset_n),
        .A(num1),
        .B(num2),
        .W(W),
        .sub(1'b0),  
        .result(result1),
        .valid_out(valid1)
    );

    // -------------------------------------------------------
    // Lower Wing Calculation: X0 - (X1 * W)
    // -------------------------------------------------------
    cpx_mad lower_wing (
        .clk(clk),
        .reset_n(reset_n),
        .A(num1),
        .B(num2),
        .W(W),
        .sub(1'b1),   
        .result(result2),
        .valid_out(valid2)
    );

    // As both cpx_mad units run in parallel and share the exact same pipeline depth (3 clock cycles), their valid signals will assert simultaneously.
    assign valid_out = valid1 & valid2;

endmodule