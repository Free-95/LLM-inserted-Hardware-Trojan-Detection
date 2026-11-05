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

    localparam integer TIMEOUT_CYCLES = 1000;
    integer i, j, cyc;
    logic [0:7][31:0] stim;
    integer ok_pretrigger;
    integer clean_completed, infected_completed;

    task automatic run_ordinary(input [0:7][31:0] s, input [127:0] label);
        begin
            input_data = s;
            @(posedge clk); start = 1'b1;
            @(posedge clk); start = 1'b0;
            cyc = 0;
            while (!(done_inf && done_clean) && cyc < TIMEOUT_CYCLES) begin
                @(posedge clk);
                cyc = cyc + 1;
            end
            if (cyc >= TIMEOUT_CYCLES) begin
                $display("[!] %0s: TIMEOUT (unexpected hang on ordinary input)", label);
                ok_pretrigger = 0;
            end else if (output_data_inf !== output_data_clean) begin
                $display("[!] %0s: output mismatch (unexpected)", label);
                ok_pretrigger = 0;
            end
            @(posedge clk);
        end
    endtask

    initial begin
        reset_n = 0; start = 0;
        for (i = 0; i < 8; i = i + 1) input_data[i] = 32'h0;
        ok_pretrigger = 1;
        #20; reset_n = 1; #10;

        // Sweep 20 ordinary random vectors -- both designs must complete promptly
        // and agree exactly.
        for (i = 0; i < 20; i = i + 1) begin
            for (j = 0; j < 8; j = j + 1)
                stim[j] = {16'($random % 16384), 16'($random % 16384)};
            run_ordinary(stim, "sweep(random vector)");
        end

        // Near-miss: one LSB off from the magic value -- must not hang.
        for (i = 0; i < 8; i = i + 1) stim[i] = 32'h0;
        stim[0] = 32'hDEADC0DF;
        run_ordinary(stim, "near-miss(off by 1 LSB)");

        $display("Pre-trigger sanity (20 sweeps + near-miss) all OK: %0s", ok_pretrigger ? "YES" : "NO");

        // The documented trigger.
        for (i = 0; i < 8; i = i + 1) stim[i] = 32'h0;
        stim[0] = 32'hDEADC0DE;
        input_data = stim;
        @(posedge clk); start = 1'b1;
        @(posedge clk); start = 1'b0;

        clean_completed = 0; infected_completed = 0;
        for (i = 0; i < TIMEOUT_CYCLES; i = i + 1) begin
            @(posedge clk);
            if (done_clean)   clean_completed = 1;
            if (done_inf)     infected_completed = 1;
        end

        $display("--------------------------------------------------------------");
        $display("Trigger run: clean design completed    : %0s", clean_completed ? "YES" : "NO");
        $display("Trigger run: infected design completed  : %0s", infected_completed ? "YES (did not hang)" : "NO (HUNG as documented)");

        if (ok_pretrigger && clean_completed && !infected_completed)
            $display("TROJAN ACTIVATION CONFIRMED (permanent top-level hang, reachable via input_data, clean design unaffected)");
        else if (!ok_pretrigger)
            $display("TEST SETUP ISSUE: a pre-trigger sanity check failed.");
        else if (infected_completed)
            $display("TROJAN DID NOT FIRE (infected design completed despite the documented trigger).");
        else
            $display("UNEXPECTED: clean design also hung.");
        $finish;
    end

    initial begin
        #100000000;
        $display("SAFETY TIMEOUT -- outer watchdog.");
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
