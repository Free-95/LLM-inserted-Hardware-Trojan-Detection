`timescale 1ns / 1ps

module tb_eval2_activation;

    logic clk, reset_n, start;
    logic [0:7][31:0] input_data;
    logic [0:7][31:0] output_data_inf, output_data_clean;
    logic done_inf, done_clean;

    fft_8point       dut_infected (
        .clk(clk), .reset_n(reset_n), .start(start),
        .input_data(input_data), .output_data(output_data_inf), .done(done_inf)
    );
    fft_8point_clean dut_clean (
        .clk(clk), .reset_n(reset_n), .start(start),
        .input_data(input_data), .output_data(output_data_clean), .done(done_clean)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    localparam integer DONE_TIMEOUT_CYCLES = 2000;
    integer mismatch_count, unexpected_mismatch_count, trigger_mismatch_seen;
    integer i, cyc_count;
    logic timed_out;

    task automatic run_one(input [0:7][31:0] stim, input is_trigger_case, input [511:0] label);
        begin
            input_data = stim;
            @(posedge clk);
            start = 1'b1;
            @(posedge clk);
            start = 1'b0;

            cyc_count = 0;
            timed_out = 0;
            while (!(done_inf && done_clean) && !timed_out) begin
                @(posedge clk);
                cyc_count = cyc_count + 1;
                if (cyc_count > DONE_TIMEOUT_CYCLES) timed_out = 1;
            end
            @(posedge clk);

            if (timed_out) begin
                $display("[!] %0s: TIMEOUT waiting for done", label);
            end else if (output_data_inf !== output_data_clean) begin
                mismatch_count = mismatch_count + 1;
                if (is_trigger_case) begin
                    trigger_mismatch_seen = trigger_mismatch_seen + 1;
                    $display("[*] %0s (TRIGGER): infected out[0]=%h  clean out[0]=%h (DIFFER, as expected)",
                              label, output_data_inf[0], output_data_clean[0]);
                end else begin
                    unexpected_mismatch_count = unexpected_mismatch_count + 1;
                    $display("[!] %0s (NOT the trigger): infected out[0]=%h  clean out[0]=%h DIFFER UNEXPECTEDLY",
                              label, output_data_inf[0], output_data_clean[0]);
                end
            end
            @(posedge clk);
        end
    endtask

    logic [0:7][31:0] stim, sweep_vec;
    integer sweep_j;

    initial begin
        reset_n = 0; start = 0;
        for (i = 0; i < 8; i = i + 1) input_data[i] = 32'h0;
        mismatch_count = 0; unexpected_mismatch_count = 0; trigger_mismatch_seen = 0;

        #20; reset_n = 1; #10;

        // Sweep 30 ordinary random FFT input vectors -- must never differ.
        for (i = 0; i < 30; i = i + 1) begin
            for (sweep_j = 0; sweep_j < 8; sweep_j = sweep_j + 1)
                sweep_vec[sweep_j] = {16'($random % 16384), 16'($random % 16384)};
            run_one(sweep_vec, 1'b0, "sweep(random vector)");
        end

        // Near-miss: off by one LSB -- must not fire.
        for (i = 0; i < 8; i = i + 1) stim[i] = 32'h0;
        stim[0] = {16'h0100, 16'h0010};
        stim[4] = {16'h5A5B, 16'h0005};
        run_one(stim, 1'b0, "near-miss(off by 1 LSB)");

        // The documented trigger.
        for (i = 0; i < 8; i = i + 1) stim[i] = 32'h0;
        stim[0] = {16'h0100, 16'h0010};
        stim[4] = {16'h5A5A, 16'h0005};
        run_one(stim, 1'b1, "MAGIC TRIGGER (via top-level input_data)");

        // Post-trigger ordinary vector -- purely combinational, must return to dormant.
        for (i = 0; i < 8; i = i + 1) stim[i] = {16'h0030 + i[15:0]*16'h0004, 16'h0010};
        run_one(stim, 1'b0, "post-trigger(ordinary vector)");

        $display("--------------------------------------------------------------");
        $display("Total mismatched FFT runs          : %0d", mismatch_count);
        $display("Unexpected (non-trigger) mismatches : %0d", unexpected_mismatch_count);
        $display("Documented trigger mismatches seen  : %0d", trigger_mismatch_seen);

        if (unexpected_mismatch_count == 0 && trigger_mismatch_seen == 1 && mismatch_count == 1)
            $display("TROJAN ACTIVATION CONFIRMED (top-level output_data corrupted only on the documented trigger vector, nowhere else)");
        else if (trigger_mismatch_seen == 0)
            $display("TROJAN DID NOT FIRE on the documented top-level trigger vector.");
        else
            $display("TROJAN FIRED OUTSIDE documented trigger (over-broad / not surgical).");
        $finish;
    end

    initial begin
        #20000000;
        $display("SAFETY TIMEOUT -- simulation hung.");
        $finish;
    end
endmodule


// --- Clean Design ---
module fft_8point_clean (
    input                  clk, reset_n, start,
    input      [0:7][31:0] input_data,
    output reg [0:7][31:0] output_data,
    output reg             done
);

    reg [31:0] ram [0:7];
    reg [2:0] state;

    // FSM States
    localparam IDLE           = 3'd0;
    localparam LOAD_BIT_REV   = 3'd1;
    localparam START_CORDIC   = 3'd2;
    localparam WAIT_CORDIC    = 3'd3;
    localparam WAIT_BUTTERFLY = 3'd4;
    localparam UPDATE_LOOPS   = 3'd5;
    localparam FINISH         = 3'd6;

    // ------------------------------------------
    // FFT Algorithm Loop Counters
    // ------------------------------------------
    reg [1:0] stage_idx;   // 0 to 2 (Since N=8)
    reg [3:0] group_start; // Starting index of current butterfly group
    reg [2:0] element;     // Current butterfly element in the group
    reg [2:0] width;       // 1, 2, or 4 (Distance between butterfly wings)
    
    reg [2:0] wait_count;  // Timer for butterfly pipeline

    // ------------------------------------------
    // CORDIC Twiddle Generator
    // ------------------------------------------
    reg cordic_start;
    wire [31:0] cordic_W;
    wire cordic_valid;
    reg [31:0] cordic_W_reg; 

    // Extend element to 5-bits before shifting to prevent bit-loss during shift
    wire [4:0] element_extended = {2'b00, element};
    wire [2:0] current_k = (element_extended << 2) >> stage_idx;

    cordic_twiddle_generator twiddle_gen (
        .clk(clk),
        .reset_n(reset_n),
        .start(cordic_start),
        .k(current_k),
        .W(cordic_W),
        .valid(cordic_valid)
    );

    // ------------------------------------------
    // Butterfly Unit Instantiation
    // ------------------------------------------
    wire [31:0] butterfly_res1;
    wire [31:0] butterfly_res2;
    wire butterfly_valid;
    
    wire [2:0] idx_a = group_start + element;
    wire [2:0] idx_b = group_start + element + width;

    butterfly_2point_clean butterfly_core (
        .clk(clk),
        .reset_n(reset_n),
        .num1(ram[idx_a]),       
        .num2(ram[idx_b]),       
        .W(cordic_W_reg),        
        .result1(butterfly_res1),
        .result2(butterfly_res2),
        .valid_out(butterfly_valid)
    );

    // ------------------------------------------
    // Master FSM
    // ------------------------------------------
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state <= IDLE;
            done <= 1'b0;
            cordic_start <= 1'b0;
            output_data <= 0; 

            stage_idx <= 0;
            group_start <= 0;
            element <= 0;
            width <= 1;
        end else begin
            case (state)
                IDLE: begin
                    done <= 1'b0;
                    if (start) begin
                        state <= LOAD_BIT_REV;
                    end
                end

                LOAD_BIT_REV: begin
                    ram[0] <= input_data[0];
                    ram[4] <= input_data[1];
                    ram[2] <= input_data[2];
                    ram[6] <= input_data[3];
                    ram[1] <= input_data[4];
                    ram[5] <= input_data[5];
                    ram[3] <= input_data[6];
                    ram[7] <= input_data[7];
                    
                    stage_idx <= 0;
                    group_start <= 0;
                    element <= 0;
                    width <= 1;
                    
                    state <= START_CORDIC;
                end

                START_CORDIC: begin
                    cordic_start <= 1'b1;
                    state <= WAIT_CORDIC;
                end

                WAIT_CORDIC: begin
                    cordic_start <= 1'b0;
                    if (cordic_valid) begin
                        cordic_W_reg <= cordic_W; 
                        wait_count <= 0;
                        state <= WAIT_BUTTERFLY;
                    end
                end

                WAIT_BUTTERFLY: begin
                    if (wait_count == 4) begin
                        ram[idx_a] <= butterfly_res1;
                        ram[idx_b] <= butterfly_res2;
                        state <= UPDATE_LOOPS;
                    end else begin
                        wait_count <= wait_count + 1;
                    end
                end

                UPDATE_LOOPS: begin
                    if (element + 1 < width) begin
                        element <= element + 1;
                        state <= START_CORDIC;
                    end else begin
                        element <= 0;
                        if (group_start + (width << 1) < 8) begin
                            group_start <= group_start + (width << 1);
                            state <= START_CORDIC;
                        end else begin
                            group_start <= 0;
                            if (stage_idx + 1 < 3) begin
                                stage_idx <= stage_idx + 1;
                                width <= width << 1;
                                state <= START_CORDIC;
                            end else begin
                                state <= FINISH; 
                            end
                        end
                    end
                end

                FINISH: begin
                    output_data[0] <= ram[0];
                    output_data[1] <= ram[1];
                    output_data[2] <= ram[2];
                    output_data[3] <= ram[3];
                    output_data[4] <= ram[4];
                    output_data[5] <= ram[5];
                    output_data[6] <= ram[6];
                    output_data[7] <= ram[7];
                    
                    done <= 1'b1;
                    state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule

module butterfly_2point_clean (
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
    cpx_mad_clean upper_wing (
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
    cpx_mad_clean lower_wing (
        .clk(clk),
        .reset_n(reset_n),
        .A(num1),
        .B(num2),
        .W(W),
        .sub(1'b1),   
        .result(result2),
        .valid_out(valid2)
    );

    // As both cpx_mad_clean units run in parallel and share the exact same pipeline depth (3 clock cycles), their valid signals will assert simultaneously.
    assign valid_out = valid1 & valid2;

endmodule

module cpx_mad_clean (
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
    
    vedic_multiplier_q8_8_clean mult_rr (.A(B_r), .B(W_r), .Result(m_rr));   // B_real * W_real
    vedic_multiplier_q8_8_clean mult_ii (.A(B_i), .B(W_i), .Result(m_ii));   // B_imag * W_imag
    vedic_multiplier_q8_8_clean mult_ri (.A(B_r), .B(W_i), .Result(m_ri));   // B_real * W_imag
    vedic_multiplier_q8_8_clean mult_ir (.A(B_i), .B(W_r), .Result(m_ir));   // B_imag * W_real

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

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            result <= 32'd0;
            valid_out <= 1'b0;
        end else begin
            result <= {final_r, final_i}; 
            valid_out <= valid_reg2;
        end
    end

endmodule

module vedic_multiplier_q8_8_clean (
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
