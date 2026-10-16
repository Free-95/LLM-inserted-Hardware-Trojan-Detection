`timescale 1ns / 1ps

// Top module: Twiddle Factor generator
module cordic_twiddle_generator (
    input clk,
    input reset_n,
    input start,      // Triggers the CORDIC calculation
    input [2:0] k,    // Twiddle index
    output [31:0] W,  // 32-bit Complex Twiddle Factor
    output valid      // High when Twiddle Factor is ready
);

    wire signed [15:0] target_angle;
    wire invert_signs;
    
    twiddle_angle_mapper mapper (
        .k(k),
        .target_angle(target_angle),
        .invert_signs(invert_signs)
    );

    wire signed [15:0] cordic_cos, cordic_sin;
    wire cordic_valid;

    cordic_sincos cordic_core (
        .clk(clk),
        .reset_n(reset_n),
        .start(start),
        .target_angle(target_angle),
        .cos_out(cordic_cos),
        .sin_out(cordic_sin),
        .valid(cordic_valid)
    );

    // If the angle was beyond Pi/2, invert the signs of both Cosine (Real) and Sine (Imaginary).
    wire signed [15:0] final_cos = invert_signs ? (-cordic_cos) : cordic_cos;
    wire signed [15:0] final_sin = invert_signs ? (-cordic_sin) : cordic_sin;

    assign W = {final_cos, final_sin};
    assign valid = cordic_valid;

endmodule

// Sub-module: Angle mapper
module twiddle_angle_mapper (
    input [2:0] k,                     // Twiddle index (0 to N/2 - 1)
    output signed [15:0] target_angle, // Q8.8 Angle for CORDIC
    output invert_signs                // Flag to invert final sine/cosine
);

    // Q8.8 Constants for Pi/2, Pi, and 2*Pi/N
    localparam signed [15:0] PI_HALF    = 16'h0192; // 1.57 * 256 ≈ 402
    localparam signed [15:0] PI         = 16'h0324; // 3.14 * 256 ≈ 804
    localparam signed [15:0] PHASE_STEP = 16'h00C9; // (2 * 3.14159 / 8) * 256 ≈ 201

    wire signed [15:0] theta_mag = k * PHASE_STEP;

    assign invert_signs = (theta_mag > PI_HALF);

    // If angle exceeds Pi/2, fold it back by subtracting it from Pi.
    // Otherwise apply negative sign as W_N^k = e^(-j*2*Pi*k/N).
    assign target_angle = invert_signs ? (PI - theta_mag) : (-theta_mag);

endmodule

