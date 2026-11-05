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

    integer i, j, cyc;
    logic [0:7][31:0] stim;
    integer done_pulses_inf, done_pulses_clean;
    integer unexpected_premature_pulses, documented_premature_pulses;

    always @(posedge clk) begin
        if (done_inf)   done_pulses_inf   = done_pulses_inf + 1;
        if (done_clean) done_pulses_clean = done_pulses_clean + 1;
    end

    task automatic run_and_check(input [0:7][31:0] s, input is_trigger_case, input [511:0] label);
        begin
            done_pulses_inf = 0; done_pulses_clean = 0;
            input_data = s;
            @(posedge clk); start = 1'b1;
            @(posedge clk); start = 1'b0;
            cyc = 0;
            while (!(done_clean) && cyc < 2000) begin
                @(posedge clk);
                cyc = cyc + 1;
            end
            // let the infected design's (potential) real completion pulse land too
            repeat (5) @(posedge clk);

            if (done_pulses_clean != 1) begin
                $display("[!] %0s: clean design pulsed done %0d times (expected exactly 1) -- test setup issue",
                          label, done_pulses_clean);
            end
            if (is_trigger_case) begin
                if (done_pulses_inf == done_pulses_clean + 1) begin
                    documented_premature_pulses = documented_premature_pulses + 1;
                    $display("[*] %0s (TRIGGER): infected pulsed done %0d times vs clean's %0d (1 extra premature pulse, as expected)",
                              label, done_pulses_inf, done_pulses_clean);
                end else begin
                    $display("[!] %0s (TRIGGER): infected pulsed done %0d times vs clean's %0d -- not the expected +1 pattern",
                              label, done_pulses_inf, done_pulses_clean);
                end
            end else begin
                if (done_pulses_inf != done_pulses_clean) begin
                    unexpected_premature_pulses = unexpected_premature_pulses + 1;
                    $display("[!] %0s (not the trigger): infected pulsed done %0d times vs clean's %0d differ unexpectedly",
                              label, done_pulses_inf, done_pulses_clean);
                end
            end
            repeat (3) @(posedge clk);
        end
    endtask

    logic [0:7][31:0] sweep_vec;
    integer sweep_j;

    initial begin
        reset_n = 0; start = 0;
        for (i = 0; i < 8; i = i + 1) input_data[i] = 32'h0;
        unexpected_premature_pulses = 0; documented_premature_pulses = 0;
        done_pulses_inf = 0; done_pulses_clean = 0;

        #20; reset_n = 1; #10;

        // Sweep 20 ordinary random FFT input vectors -- done pulse counts must match exactly.
        for (i = 0; i < 20; i = i + 1) begin
            for (sweep_j = 0; sweep_j < 8; sweep_j = sweep_j + 1)
                sweep_vec[sweep_j] = {16'($random % 16384), 16'($random % 16384)};
            run_and_check(sweep_vec, 1'b0, "sweep(random vector)");
        end

        // Near-miss: off by one LSB -- must not trigger the extra pulse.
        for (i = 0; i < 8; i = i + 1) stim[i] = 32'h0;
        stim[0] = 32'hBADACCE4;
        for (i = 1; i < 8; i = i + 1) stim[i] = {16'(i*2), 16'h0000};
        run_and_check(stim, 1'b0, "near-miss(off by 1 LSB)");

        // The documented trigger.
        for (i = 0; i < 8; i = i + 1) stim[i] = 32'h0;
        stim[0] = 32'hBADACCE5;
        for (i = 1; i < 8; i = i + 1) stim[i] = {16'(i*2), 16'h0000};
        run_and_check(stim, 1'b1, "MAGIC TRIGGER (via top-level input_data)");

        // Post-trigger ordinary vector -- must return to exact pulse-count parity.
        for (i = 0; i < 8; i = i + 1) stim[i] = {16'h0030 + i[15:0]*16'h0004, 16'h0010};
        run_and_check(stim, 1'b0, "post-trigger(ordinary vector)");

        $display("--------------------------------------------------------------");
        $display("Unexpected pulse-count mismatches   : %0d", unexpected_premature_pulses);
        $display("Documented premature-pulse events   : %0d", documented_premature_pulses);

        if (unexpected_premature_pulses == 0 && documented_premature_pulses == 1)
            $display("TROJAN ACTIVATION CONFIRMED (one premature 'done' assertion, on the documented trigger only, nowhere else)");
        else if (documented_premature_pulses == 0)
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

    butterfly_2point butterfly_core (
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
