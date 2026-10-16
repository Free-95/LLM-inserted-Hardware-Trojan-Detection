`timescale 1ns / 1ps

module cordic_sincos (
    input                    clk,
    input                    reset_n,                    
    input                    start,
    input      signed [15:0] target_angle,  // Target angle in Q8.8 radians
    output reg signed [15:0] cos_out,       // Real part (W_real) in Q8.8
    output reg signed [15:0] sin_out,       // Imaginary part (W_imag) in Q8.8
    output reg               valid          // High when calculation is complete
);

    // CORDIC gain A_n ≈ 0.60725. In Q8.8: 0.60725 * 256 = 155 = 16'h009B
    localparam signed [15:0] INITIAL_X = 16'h009B; 
    localparam signed [15:0] INITIAL_Y = 16'h0000;

    reg signed [15:0] x, y, z; 
    reg [3:0] i;  // Iteration counter (0 to 7)
    
    reg [1:0] state;
    localparam IDLE = 2'b00, ITERATE = 2'b01, DONE = 2'b10;

    // ArcTangent Lookup Table in Q8.8 format (Radians * 256)
    reg signed [15:0] atan_table;
    always @(*) begin
        case (i) 
            4'd0: atan_table = 16'h00C9; // atan(1) = 0.785 rad
            4'd1: atan_table = 16'h0077; // atan(0.5) = 0.463 rad
            4'd2: atan_table = 16'h003F; // atan(0.25) = 0.244 rad
            4'd3: atan_table = 16'h0020; // atan(0.125) = 0.124 rad
            4'd4: atan_table = 16'h0010; // atan(0.0625) = 0.062 rad
            4'd5: atan_table = 16'h0008; // atan(0.03125) = 0.031 rad
            4'd6: atan_table = 16'h0004; // atan(0.015625) = 0.016 rad
            4'd7: atan_table = 16'h0002; // atan(0.0078125) = 0.008 rad
            default: atan_table = 16'h0000;
        endcase
    end

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state <= IDLE;
            valid <= 1'b0;
            cos_out <= 16'sd0;
            sin_out <= 16'sd0;
            x <= 16'sd0;
            y <= 16'sd0;
            z <= 16'sd0;
            i <= 4'd0;
        end else begin
            case (state)
                IDLE: begin
                    valid <= 1'b0;
                    if (start) begin
                        x <= INITIAL_X;
                        y <= INITIAL_Y;
                        z <= target_angle;
                        i <= 4'd0;
                        state <= ITERATE;
                    end
                end

                ITERATE: begin
                    if (i < 8) begin
                        // Determine rotation direction based on the sign of the remaining angle 'z'
                        if (z >= 0) begin
                            x <= x - (y >>> i); 
                            y <= y + (x >>> i);
                            z <= z - atan_table;
                        end else begin
                            x <= x + (y >>> i);
                            y <= y - (x >>> i);
                            z <= z + atan_table;
                        end
                        i <= i + 1;
                    end else begin
                        state <= DONE;
                    end
                end

                DONE: begin
                    cos_out <= x;
                    sin_out <= y;
                    valid <= 1'b1;
                    state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule