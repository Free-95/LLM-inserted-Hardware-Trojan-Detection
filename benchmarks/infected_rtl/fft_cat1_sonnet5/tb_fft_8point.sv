// Testbench with golden reference values computed independently via numpy.fft.fft
// (double precision), quantized to Q8.8
`timescale 1ns / 1ps

module tb_fft_8point;

    logic clk;
    logic reset_n;
    logic start;
    logic [0:7][31:0] input_data;
    logic [0:7][31:0] output_data;
    logic done;

    localparam integer TOLERANCE = 64; // Q8.8 LSBs
    localparam integer DONE_TIMEOUT_CYCLES = 2000;

    integer fail_count;
    integer first_fail_code;
    integer vectors_checked;
    integer bins_checked;

    task automatic report_fail(input [8*200-1:0] msg);
        begin
            fail_count = fail_count + 1;
            if (first_fail_code == -1) first_fail_code = fail_count;
            $display("[FAIL] %0s (time=%0t)", msg, $time);
        end
    endtask

    fft_8point dut (
        .clk(clk), .reset_n(reset_n), .start(start),
        .input_data(input_data), .output_data(output_data), .done(done)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    // ------------------------------------------------------------------
    // check_bin: compares one output bin's real and imaginary Q8.8 words
    // against golden values within TOLERANCE, using signed subtraction so
    // the sign of the error doesn't matter, only magnitude matters.
    // ------------------------------------------------------------------
    task automatic check_bin(input [8*64-1:0] vec_name, input integer bin_idx,
                             input signed [15:0] got_r, input signed [15:0] got_i,
                             input signed [15:0] exp_r, input signed [15:0] exp_i);
        integer err_r, err_i;
        begin
            bins_checked = bins_checked + 1;
            err_r = got_r - exp_r; if (err_r < 0) err_r = -err_r;
            err_i = got_i - exp_i; if (err_i < 0) err_i = -err_i;
            if (err_r > TOLERANCE || err_i > TOLERANCE) begin
                report_fail({vec_name, ": bin mismatch beyond tolerance"});
                $display("        bin=%0d got=(%h,%h) expected=(%h,%h) err=(%0d,%0d)",
                    bin_idx, got_r, got_i, exp_r, exp_i, err_r, err_i);
            end
        end
    endtask

    // ------------------------------------------------------------------
    // run_fft: triggers the FFT and waits for done, with a timeout so a
    // Trojan that stalls the FSM fails loudly instead of hanging forever.
    // Also cross-checks the FSM's fixed-latency butterfly-result capture
    // against the butterfly's own valid_out probe, so a Trojan that 
    // silently extends the pipeline beyond the FSM's built-in margin is 
    // still caught even though it wouldn't corrupt data values on its 
    // own (the FSM would just read stale/combinational garbage).
    // ------------------------------------------------------------------
    task automatic run_fft(input [8*64-1:0] tag);
        integer cyc_count;
        reg timed_out;
        begin
            @(posedge clk);
            start = 1'b1;
            @(posedge clk);
            start = 1'b0;

            cyc_count = 0;
            timed_out = 0;
            while (!done && !timed_out) begin
                @(posedge clk);
                cyc_count = cyc_count + 1;
                if (cyc_count > DONE_TIMEOUT_CYCLES) timed_out = 1;
            end
            if (timed_out)
                report_fail({tag, ": timeout waiting for done (possible hang/DoS Trojan)"});
            @(posedge clk);
        end
    endtask

    // ------------------------------------------------------------------
    // Timing-margin monitor: records whether dut.butterfly_valid was ever
    // observed LOW at the exact cycle the FSM consumes butterfly results
    // (dut.state==WAIT_BUTTERFLY && dut.wait_count==4), which would mean
    // the FSM's fixed 5-cycle wait no longer has enough margin over the
    // butterfly's actual pipeline latency -- a Trojan could silently
    // extend that latency without changing final values enough to fail
    // the tolerance check on simple vectors.
    // ------------------------------------------------------------------
    integer margin_violations;
    always @(posedge clk) begin
        if (dut.state == 3'd4 && dut.wait_count == 3'd4) begin // WAIT_BUTTERFLY, about to consume
            if (!dut.butterfly_valid)
                margin_violations = margin_violations + 1;
        end
    end

    initial begin
        if ($test$plusargs("vcd")) begin
            $dumpfile("tb_fft_8point.vcd");
            $dumpvars(0, tb_fft_8point);
        end

        fail_count = 0;
        first_fail_code = -1;
        vectors_checked = 0;
        bins_checked = 0;
        margin_violations = 0;

        reset_n = 0;
        start = 0;
        input_data[0] = 32'd0;
        input_data[1] = 32'd0;
        input_data[2] = 32'd0;
        input_data[3] = 32'd0;
        input_data[4] = 32'd0;
        input_data[5] = 32'd0;
        input_data[6] = 32'd0;
        input_data[7] = 32'd0;
        #20 reset_n = 1;
        #20;

        // ---- Reset sanity ----
        if (done !== 1'b0) report_fail("reset: done asserted immediately after reset");

        // ---- Vector: dc_signal ----
        input_data[0] = 32'h01000000;
        input_data[1] = 32'h01000000;
        input_data[2] = 32'h01000000;
        input_data[3] = 32'h01000000;
        input_data[4] = 32'h01000000;
        input_data[5] = 32'h01000000;
        input_data[6] = 32'h01000000;
        input_data[7] = 32'h01000000;
        run_fft("dc_signal");
        check_bin("dc_signal", 0, output_data[0][31:16], output_data[0][15:0], 16'sh0800, 16'sh0000);
        check_bin("dc_signal", 1, output_data[1][31:16], output_data[1][15:0], 16'sh0000, 16'sh0000);
        check_bin("dc_signal", 2, output_data[2][31:16], output_data[2][15:0], 16'sh0000, 16'sh0000);
        check_bin("dc_signal", 3, output_data[3][31:16], output_data[3][15:0], 16'sh0000, 16'sh0000);
        check_bin("dc_signal", 4, output_data[4][31:16], output_data[4][15:0], 16'sh0000, 16'sh0000);
        check_bin("dc_signal", 5, output_data[5][31:16], output_data[5][15:0], 16'sh0000, 16'sh0000);
        check_bin("dc_signal", 6, output_data[6][31:16], output_data[6][15:0], 16'sh0000, 16'sh0000);
        check_bin("dc_signal", 7, output_data[7][31:16], output_data[7][15:0], 16'sh0000, 16'sh0000);
        vectors_checked = vectors_checked + 1;

        // ---- Vector: impulse ----
        input_data[0] = 32'h01000000;
        input_data[1] = 32'h00000000;
        input_data[2] = 32'h00000000;
        input_data[3] = 32'h00000000;
        input_data[4] = 32'h00000000;
        input_data[5] = 32'h00000000;
        input_data[6] = 32'h00000000;
        input_data[7] = 32'h00000000;
        run_fft("impulse");
        check_bin("impulse", 0, output_data[0][31:16], output_data[0][15:0], 16'sh0100, 16'sh0000);
        check_bin("impulse", 1, output_data[1][31:16], output_data[1][15:0], 16'sh0100, 16'sh0000);
        check_bin("impulse", 2, output_data[2][31:16], output_data[2][15:0], 16'sh0100, 16'sh0000);
        check_bin("impulse", 3, output_data[3][31:16], output_data[3][15:0], 16'sh0100, 16'sh0000);
        check_bin("impulse", 4, output_data[4][31:16], output_data[4][15:0], 16'sh0100, 16'sh0000);
        check_bin("impulse", 5, output_data[5][31:16], output_data[5][15:0], 16'sh0100, 16'sh0000);
        check_bin("impulse", 6, output_data[6][31:16], output_data[6][15:0], 16'sh0100, 16'sh0000);
        check_bin("impulse", 7, output_data[7][31:16], output_data[7][15:0], 16'sh0100, 16'sh0000);
        vectors_checked = vectors_checked + 1;

        // ---- Vector: nyquist ----
        input_data[0] = 32'h01000000;
        input_data[1] = 32'hff000000;
        input_data[2] = 32'h01000000;
        input_data[3] = 32'hff000000;
        input_data[4] = 32'h01000000;
        input_data[5] = 32'hff000000;
        input_data[6] = 32'h01000000;
        input_data[7] = 32'hff000000;
        run_fft("nyquist");
        check_bin("nyquist", 0, output_data[0][31:16], output_data[0][15:0], 16'sh0000, 16'sh0000);
        check_bin("nyquist", 1, output_data[1][31:16], output_data[1][15:0], 16'sh0000, 16'sh0000);
        check_bin("nyquist", 2, output_data[2][31:16], output_data[2][15:0], 16'sh0000, 16'sh0000);
        check_bin("nyquist", 3, output_data[3][31:16], output_data[3][15:0], 16'sh0000, 16'sh0000);
        check_bin("nyquist", 4, output_data[4][31:16], output_data[4][15:0], 16'sh0800, 16'sh0000);
        check_bin("nyquist", 5, output_data[5][31:16], output_data[5][15:0], 16'sh0000, 16'sh0000);
        check_bin("nyquist", 6, output_data[6][31:16], output_data[6][15:0], 16'sh0000, 16'sh0000);
        check_bin("nyquist", 7, output_data[7][31:16], output_data[7][15:0], 16'sh0000, 16'sh0000);
        vectors_checked = vectors_checked + 1;

        // ---- Vector: sine_1cycle ----
        input_data[0] = 32'h00000000;
        input_data[1] = 32'h00b50000;
        input_data[2] = 32'h01000000;
        input_data[3] = 32'h00b50000;
        input_data[4] = 32'h00000000;
        input_data[5] = 32'hff4b0000;
        input_data[6] = 32'hff000000;
        input_data[7] = 32'hff4b0000;
        run_fft("sine_1cycle");
        check_bin("sine_1cycle", 0, output_data[0][31:16], output_data[0][15:0], 16'sh0000, 16'sh0000);
        check_bin("sine_1cycle", 1, output_data[1][31:16], output_data[1][15:0], 16'sh0000, 16'shfc00);
        check_bin("sine_1cycle", 2, output_data[2][31:16], output_data[2][15:0], 16'sh0000, 16'sh0000);
        check_bin("sine_1cycle", 3, output_data[3][31:16], output_data[3][15:0], 16'sh0000, 16'sh0000);
        check_bin("sine_1cycle", 4, output_data[4][31:16], output_data[4][15:0], 16'sh0000, 16'sh0000);
        check_bin("sine_1cycle", 5, output_data[5][31:16], output_data[5][15:0], 16'sh0000, 16'sh0000);
        check_bin("sine_1cycle", 6, output_data[6][31:16], output_data[6][15:0], 16'sh0000, 16'sh0000);
        check_bin("sine_1cycle", 7, output_data[7][31:16], output_data[7][15:0], 16'sh0000, 16'sh0400);
        vectors_checked = vectors_checked + 1;

        // ---- Vector: cosine_1cycle ----
        input_data[0] = 32'h01000000;
        input_data[1] = 32'h00b50000;
        input_data[2] = 32'h00000000;
        input_data[3] = 32'hff4b0000;
        input_data[4] = 32'hff000000;
        input_data[5] = 32'hff4b0000;
        input_data[6] = 32'h00000000;
        input_data[7] = 32'h00b50000;
        run_fft("cosine_1cycle");
        check_bin("cosine_1cycle", 0, output_data[0][31:16], output_data[0][15:0], 16'sh0000, 16'sh0000);
        check_bin("cosine_1cycle", 1, output_data[1][31:16], output_data[1][15:0], 16'sh0400, 16'sh0000);
        check_bin("cosine_1cycle", 2, output_data[2][31:16], output_data[2][15:0], 16'sh0000, 16'sh0000);
        check_bin("cosine_1cycle", 3, output_data[3][31:16], output_data[3][15:0], 16'sh0000, 16'sh0000);
        check_bin("cosine_1cycle", 4, output_data[4][31:16], output_data[4][15:0], 16'sh0000, 16'sh0000);
        check_bin("cosine_1cycle", 5, output_data[5][31:16], output_data[5][15:0], 16'sh0000, 16'sh0000);
        check_bin("cosine_1cycle", 6, output_data[6][31:16], output_data[6][15:0], 16'sh0000, 16'sh0000);
        check_bin("cosine_1cycle", 7, output_data[7][31:16], output_data[7][15:0], 16'sh0400, 16'sh0000);
        vectors_checked = vectors_checked + 1;

        // ---- Vector: sine_2cycle ----
        input_data[0] = 32'h00000000;
        input_data[1] = 32'h01000000;
        input_data[2] = 32'h00000000;
        input_data[3] = 32'hff000000;
        input_data[4] = 32'h00000000;
        input_data[5] = 32'h01000000;
        input_data[6] = 32'h00000000;
        input_data[7] = 32'hff000000;
        run_fft("sine_2cycle");
        check_bin("sine_2cycle", 0, output_data[0][31:16], output_data[0][15:0], 16'sh0000, 16'sh0000);
        check_bin("sine_2cycle", 1, output_data[1][31:16], output_data[1][15:0], 16'sh0000, 16'sh0000);
        check_bin("sine_2cycle", 2, output_data[2][31:16], output_data[2][15:0], 16'sh0000, 16'shfc00);
        check_bin("sine_2cycle", 3, output_data[3][31:16], output_data[3][15:0], 16'sh0000, 16'sh0000);
        check_bin("sine_2cycle", 4, output_data[4][31:16], output_data[4][15:0], 16'sh0000, 16'sh0000);
        check_bin("sine_2cycle", 5, output_data[5][31:16], output_data[5][15:0], 16'sh0000, 16'sh0000);
        check_bin("sine_2cycle", 6, output_data[6][31:16], output_data[6][15:0], 16'sh0000, 16'sh0400);
        check_bin("sine_2cycle", 7, output_data[7][31:16], output_data[7][15:0], 16'sh0000, 16'sh0000);
        vectors_checked = vectors_checked + 1;

        // ---- Vector: ramp ----
        input_data[0] = 32'h00000000;
        input_data[1] = 32'h00400000;
        input_data[2] = 32'h00800000;
        input_data[3] = 32'h00c00000;
        input_data[4] = 32'h01000000;
        input_data[5] = 32'h00c00000;
        input_data[6] = 32'h00800000;
        input_data[7] = 32'h00400000;
        run_fft("ramp");
        check_bin("ramp", 0, output_data[0][31:16], output_data[0][15:0], 16'sh0400, 16'sh0000);
        check_bin("ramp", 1, output_data[1][31:16], output_data[1][15:0], 16'shfe4b, 16'sh0000);
        check_bin("ramp", 2, output_data[2][31:16], output_data[2][15:0], 16'sh0000, 16'sh0000);
        check_bin("ramp", 3, output_data[3][31:16], output_data[3][15:0], 16'shffb5, 16'sh0000);
        check_bin("ramp", 4, output_data[4][31:16], output_data[4][15:0], 16'sh0000, 16'sh0000);
        check_bin("ramp", 5, output_data[5][31:16], output_data[5][15:0], 16'shffb5, 16'sh0000);
        check_bin("ramp", 6, output_data[6][31:16], output_data[6][15:0], 16'sh0000, 16'sh0000);
        check_bin("ramp", 7, output_data[7][31:16], output_data[7][15:0], 16'shfe4b, 16'sh0000);
        vectors_checked = vectors_checked + 1;

        // ---- Vector: neg_dc ----
        input_data[0] = 32'hff000000;
        input_data[1] = 32'hff000000;
        input_data[2] = 32'hff000000;
        input_data[3] = 32'hff000000;
        input_data[4] = 32'hff000000;
        input_data[5] = 32'hff000000;
        input_data[6] = 32'hff000000;
        input_data[7] = 32'hff000000;
        run_fft("neg_dc");
        check_bin("neg_dc", 0, output_data[0][31:16], output_data[0][15:0], 16'shf800, 16'sh0000);
        check_bin("neg_dc", 1, output_data[1][31:16], output_data[1][15:0], 16'sh0000, 16'sh0000);
        check_bin("neg_dc", 2, output_data[2][31:16], output_data[2][15:0], 16'sh0000, 16'sh0000);
        check_bin("neg_dc", 3, output_data[3][31:16], output_data[3][15:0], 16'sh0000, 16'sh0000);
        check_bin("neg_dc", 4, output_data[4][31:16], output_data[4][15:0], 16'sh0000, 16'sh0000);
        check_bin("neg_dc", 5, output_data[5][31:16], output_data[5][15:0], 16'sh0000, 16'sh0000);
        check_bin("neg_dc", 6, output_data[6][31:16], output_data[6][15:0], 16'sh0000, 16'sh0000);
        check_bin("neg_dc", 7, output_data[7][31:16], output_data[7][15:0], 16'sh0000, 16'sh0000);
        vectors_checked = vectors_checked + 1;

        // ---- Vector: alternating_small ----
        input_data[0] = 32'h001a0000;
        input_data[1] = 32'hffe60000;
        input_data[2] = 32'h001a0000;
        input_data[3] = 32'hffe60000;
        input_data[4] = 32'h001a0000;
        input_data[5] = 32'hffe60000;
        input_data[6] = 32'h001a0000;
        input_data[7] = 32'hffe60000;
        run_fft("alternating_small");
        check_bin("alternating_small", 0, output_data[0][31:16], output_data[0][15:0], 16'sh0000, 16'sh0000);
        check_bin("alternating_small", 1, output_data[1][31:16], output_data[1][15:0], 16'sh0000, 16'sh0000);
        check_bin("alternating_small", 2, output_data[2][31:16], output_data[2][15:0], 16'sh0000, 16'sh0000);
        check_bin("alternating_small", 3, output_data[3][31:16], output_data[3][15:0], 16'sh0000, 16'sh0000);
        check_bin("alternating_small", 4, output_data[4][31:16], output_data[4][15:0], 16'sh00cd, 16'sh0000);
        check_bin("alternating_small", 5, output_data[5][31:16], output_data[5][15:0], 16'sh0000, 16'sh0000);
        check_bin("alternating_small", 6, output_data[6][31:16], output_data[6][15:0], 16'sh0000, 16'sh0000);
        check_bin("alternating_small", 7, output_data[7][31:16], output_data[7][15:0], 16'sh0000, 16'sh0000);
        vectors_checked = vectors_checked + 1;

        // ---- Vector: complex_impulse ----
        input_data[0] = 32'h01000100;
        input_data[1] = 32'h00000000;
        input_data[2] = 32'h00000000;
        input_data[3] = 32'h00000000;
        input_data[4] = 32'h00000000;
        input_data[5] = 32'h00000000;
        input_data[6] = 32'h00000000;
        input_data[7] = 32'h00000000;
        run_fft("complex_impulse");
        check_bin("complex_impulse", 0, output_data[0][31:16], output_data[0][15:0], 16'sh0100, 16'sh0100);
        check_bin("complex_impulse", 1, output_data[1][31:16], output_data[1][15:0], 16'sh0100, 16'sh0100);
        check_bin("complex_impulse", 2, output_data[2][31:16], output_data[2][15:0], 16'sh0100, 16'sh0100);
        check_bin("complex_impulse", 3, output_data[3][31:16], output_data[3][15:0], 16'sh0100, 16'sh0100);
        check_bin("complex_impulse", 4, output_data[4][31:16], output_data[4][15:0], 16'sh0100, 16'sh0100);
        check_bin("complex_impulse", 5, output_data[5][31:16], output_data[5][15:0], 16'sh0100, 16'sh0100);
        check_bin("complex_impulse", 6, output_data[6][31:16], output_data[6][15:0], 16'sh0100, 16'sh0100);
        check_bin("complex_impulse", 7, output_data[7][31:16], output_data[7][15:0], 16'sh0100, 16'sh0100);
        vectors_checked = vectors_checked + 1;

        // ---- Vector: random_1 ----
        input_data[0] = 32'h0080001a;
        input_data[1] = 32'hffb30033;
        input_data[2] = 32'h00cdffb3;
        input_data[3] = 32'hff660066;
        input_data[4] = 32'h0033ff80;
        input_data[5] = 32'hff1a009a;
        input_data[6] = 32'h0066ff4d;
        input_data[7] = 32'hffe600cd;
        run_fft("random_1");
        check_bin("random_1", 0, output_data[0][31:16], output_data[0][15:0], 16'sh0000, 16'sh009a);
        check_bin("random_1", 1, output_data[1][31:16], output_data[1][15:0], 16'sh00ea, 16'sh0021);
        check_bin("random_1", 2, output_data[2][31:16], output_data[2][15:0], 16'shff1a, 16'sh011a);
        check_bin("random_1", 3, output_data[3][31:16], output_data[3][15:0], 16'shfe8e, 16'sh00ee);
        check_bin("random_1", 4, output_data[4][31:16], output_data[4][15:0], 16'sh03cd, 16'shfc9a);
        check_bin("random_1", 5, output_data[5][31:16], output_data[5][15:0], 16'sh007d, 16'sh0045);
        check_bin("random_1", 6, output_data[6][31:16], output_data[6][15:0], 16'shffe6, 16'sh001a);
        check_bin("random_1", 7, output_data[7][31:16], output_data[7][15:0], 16'sh013e, 16'sh0112);
        vectors_checked = vectors_checked + 1;

        // ---- Vector: random_2 ----
        input_data[0] = 32'h004dffcd;
        input_data[1] = 32'h00b30080;
        input_data[2] = 32'hff80004d;
        input_data[3] = 32'hffcdff1a;
        input_data[4] = 32'h00e6001a;
        input_data[5] = 32'hff9a00b3;
        input_data[6] = 32'h009aff66;
        input_data[7] = 32'hff330066;
        run_fft("random_2");
        check_bin("random_2", 0, output_data[0][31:16], output_data[0][15:0], 16'sh009a, 16'sh004d);
        check_bin("random_2", 1, output_data[1][31:16], output_data[1][15:0], 16'shff98, 16'sh0060);
        check_bin("random_2", 2, output_data[2][31:16], output_data[2][15:0], 16'sh02cd, 16'shfee6);
        check_bin("random_2", 3, output_data[3][31:16], output_data[3][15:0], 16'shfd16, 16'shfc9f);
        check_bin("random_2", 4, output_data[4][31:16], output_data[4][15:0], 16'sh0200, 16'shfee6);
        check_bin("random_2", 5, output_data[5][31:16], output_data[5][15:0], 16'sh0102, 16'sh0139);
        check_bin("random_2", 6, output_data[6][31:16], output_data[6][15:0], 16'shff66, 16'sh0180);
        check_bin("random_2", 7, output_data[7][31:16], output_data[7][15:0], 16'shffea, 16'sh0094);
        vectors_checked = vectors_checked + 1;

        // ---- Vector: random_3 ----
        input_data[0] = 32'hff660066;
        input_data[1] = 32'h0033ffe6;
        input_data[2] = 32'h006600b3;
        input_data[3] = 32'hff33ff80;
        input_data[4] = 32'h001a0033;
        input_data[5] = 32'h00e6ff66;
        input_data[6] = 32'hffb300cd;
        input_data[7] = 32'h0080ffb3;
        run_fft("random_3");
        check_bin("random_3", 0, output_data[0][31:16], output_data[0][15:0], 16'sh0066, 16'sh009a);
        check_bin("random_3", 1, output_data[1][31:16], output_data[1][15:0], 16'shffd6, 16'sh0169);
        check_bin("random_3", 2, output_data[2][31:16], output_data[2][15:0], 16'shff80, 16'shfdb3);
        check_bin("random_3", 3, output_data[3][31:16], output_data[3][15:0], 16'shff30, 16'sh01d2);
        check_bin("random_3", 4, output_data[4][31:16], output_data[4][15:0], 16'shfecd, 16'sh039a);
        check_bin("random_3", 5, output_data[5][31:16], output_data[5][15:0], 16'shfe90, 16'shfd97);
        check_bin("random_3", 6, output_data[6][31:16], output_data[6][15:0], 16'shff4d, 16'sh0080);
        check_bin("random_3", 7, output_data[7][31:16], output_data[7][15:0], 16'shff9d, 16'shfffb);
        vectors_checked = vectors_checked + 1;

        // ---- Vector: small_amplitude ----
        input_data[0] = 32'h000d0000;
        input_data[1] = 32'hfff80000;
        input_data[2] = 32'h00050000;
        input_data[3] = 32'hfff60000;
        input_data[4] = 32'h00030000;
        input_data[5] = 32'hfffb0000;
        input_data[6] = 32'h00080000;
        input_data[7] = 32'hfffd0000;
        run_fft("small_amplitude");
        check_bin("small_amplitude", 0, output_data[0][31:16], output_data[0][15:0], 16'sh0003, 16'sh0000);
        check_bin("small_amplitude", 1, output_data[1][31:16], output_data[1][15:0], 16'sh000e, 16'sh000a);
        check_bin("small_amplitude", 2, output_data[2][31:16], output_data[2][15:0], 16'sh0003, 16'sh0000);
        check_bin("small_amplitude", 3, output_data[3][31:16], output_data[3][15:0], 16'sh0007, 16'sh0005);
        check_bin("small_amplitude", 4, output_data[4][31:16], output_data[4][15:0], 16'sh0036, 16'sh0000);
        check_bin("small_amplitude", 5, output_data[5][31:16], output_data[5][15:0], 16'sh0007, 16'shfffb);
        check_bin("small_amplitude", 6, output_data[6][31:16], output_data[6][15:0], 16'sh0003, 16'sh0000);
        check_bin("small_amplitude", 7, output_data[7][31:16], output_data[7][15:0], 16'sh000e, 16'shfff6);
        vectors_checked = vectors_checked + 1;

        // ---- Vector: asymmetric ----
        input_data[0] = 32'h00e60000;
        input_data[1] = 32'h001a0000;
        input_data[2] = 32'hffb30000;
        input_data[3] = 32'h009a0000;
        input_data[4] = 32'hff4d0000;
        input_data[5] = 32'h00330000;
        input_data[6] = 32'h00660000;
        input_data[7] = 32'hff800000;
        run_fft("asymmetric");
        check_bin("asymmetric", 0, output_data[0][31:16], output_data[0][15:0], 16'sh00b3, 16'sh0000);
        check_bin("asymmetric", 1, output_data[1][31:16], output_data[1][15:0], 16'sh00c0, 16'shfffe);
        check_bin("asymmetric", 2, output_data[2][31:16], output_data[2][15:0], 16'sh001a, 16'shffcd);
        check_bin("asymmetric", 3, output_data[3][31:16], output_data[3][15:0], 16'sh0273, 16'shfe98);
        check_bin("asymmetric", 4, output_data[4][31:16], output_data[4][15:0], 16'shffe6, 16'sh0000);
        check_bin("asymmetric", 5, output_data[5][31:16], output_data[5][15:0], 16'sh0273, 16'sh0168);
        check_bin("asymmetric", 6, output_data[6][31:16], output_data[6][15:0], 16'sh001a, 16'sh0033);
        check_bin("asymmetric", 7, output_data[7][31:16], output_data[7][15:0], 16'sh00c0, 16'sh0002);
        vectors_checked = vectors_checked + 1;

        // ---- Vector: zero_signal ----
        input_data[0] = 32'h00000000;
        input_data[1] = 32'h00000000;
        input_data[2] = 32'h00000000;
        input_data[3] = 32'h00000000;
        input_data[4] = 32'h00000000;
        input_data[5] = 32'h00000000;
        input_data[6] = 32'h00000000;
        input_data[7] = 32'h00000000;
        run_fft("zero_signal");
        check_bin("zero_signal", 0, output_data[0][31:16], output_data[0][15:0], 16'sh0000, 16'sh0000);
        check_bin("zero_signal", 1, output_data[1][31:16], output_data[1][15:0], 16'sh0000, 16'sh0000);
        check_bin("zero_signal", 2, output_data[2][31:16], output_data[2][15:0], 16'sh0000, 16'sh0000);
        check_bin("zero_signal", 3, output_data[3][31:16], output_data[3][15:0], 16'sh0000, 16'sh0000);
        check_bin("zero_signal", 4, output_data[4][31:16], output_data[4][15:0], 16'sh0000, 16'sh0000);
        check_bin("zero_signal", 5, output_data[5][31:16], output_data[5][15:0], 16'sh0000, 16'sh0000);
        check_bin("zero_signal", 6, output_data[6][31:16], output_data[6][15:0], 16'sh0000, 16'sh0000);
        check_bin("zero_signal", 7, output_data[7][31:16], output_data[7][15:0], 16'sh0000, 16'sh0000);
        vectors_checked = vectors_checked + 1;

        // ---- Saturation stress test: all 8 samples at 127.5 (beyond
        //      Q8.8 representable range once summed through the FFT's
        //      internal adds). Repeated saturation is nonlinear, so we
        //      check structural properties instead of golden-value
        //      tolerance: outputs must stay within valid Q8.8 range (no
        //      X/Z), and bin0's real part -- the DC/sum term, which should
        //      clip at the top of the range -- must land exactly at the
        //      max positive Q8.8 value.
        begin : saturation_test
            input_data[0] = 32'h7f800000; input_data[1] = 32'h7f800000;
            input_data[2] = 32'h7f800000; input_data[3] = 32'h7f800000;
            input_data[4] = 32'h7f800000; input_data[5] = 32'h7f800000;
            input_data[6] = 32'h7f800000; input_data[7] = 32'h7f800000;
            run_fft("saturation_stress");

            if (output_data[0][31:16] !== 16'sh7fff)
                report_fail("saturation_stress: bin0 real part did not saturate to the expected max positive Q8.8 value");

            // Unrolled (Constant indices as Icarus does not support variable
            // indexing into a packed multi-dimensional array signal).
            if (^output_data[0] === 1'bx)
                report_fail("saturation_stress: output_data[0] contains X/Z bits (possible uninitialized/corrupted state)");
            if (^output_data[1] === 1'bx)
                report_fail("saturation_stress: output_data[1] contains X/Z bits (possible uninitialized/corrupted state)");
            if (^output_data[2] === 1'bx)
                report_fail("saturation_stress: output_data[2] contains X/Z bits (possible uninitialized/corrupted state)");
            if (^output_data[3] === 1'bx)
                report_fail("saturation_stress: output_data[3] contains X/Z bits (possible uninitialized/corrupted state)");
            if (^output_data[4] === 1'bx)
                report_fail("saturation_stress: output_data[4] contains X/Z bits (possible uninitialized/corrupted state)");
            if (^output_data[5] === 1'bx)
                report_fail("saturation_stress: output_data[5] contains X/Z bits (possible uninitialized/corrupted state)");
            if (^output_data[6] === 1'bx)
                report_fail("saturation_stress: output_data[6] contains X/Z bits (possible uninitialized/corrupted state)");
            if (^output_data[7] === 1'bx)
                report_fail("saturation_stress: output_data[7] contains X/Z bits (possible uninitialized/corrupted state)");
        end

        // ---- Back-to-back runs: immediately re-trigger with a fresh vector
        //      right after a previous completion, no idle gap, checking for
        //      state leakage between runs ----
        begin : back_to_back
            input_data[0] = 32'h01000000;
            input_data[1] = 32'h00000000;
            input_data[2] = 32'h00000000;
            input_data[3] = 32'h00000000;
            input_data[4] = 32'h00000000;
            input_data[5] = 32'h00000000;
            input_data[6] = 32'h00000000;
            input_data[7] = 32'h00000000;
            run_fft("back_to_back_1");
            check_bin("back_to_back_1", 0, output_data[0][31:16], output_data[0][15:0], 16'sh0100, 16'sh0000);
            check_bin("back_to_back_1", 1, output_data[1][31:16], output_data[1][15:0], 16'sh0100, 16'sh0000);
            check_bin("back_to_back_1", 2, output_data[2][31:16], output_data[2][15:0], 16'sh0100, 16'sh0000);
            check_bin("back_to_back_1", 3, output_data[3][31:16], output_data[3][15:0], 16'sh0100, 16'sh0000);
            check_bin("back_to_back_1", 4, output_data[4][31:16], output_data[4][15:0], 16'sh0100, 16'sh0000);
            check_bin("back_to_back_1", 5, output_data[5][31:16], output_data[5][15:0], 16'sh0100, 16'sh0000);
            check_bin("back_to_back_1", 6, output_data[6][31:16], output_data[6][15:0], 16'sh0100, 16'sh0000);
            check_bin("back_to_back_1", 7, output_data[7][31:16], output_data[7][15:0], 16'sh0100, 16'sh0000);
            input_data[0] = 32'h01000000;
            input_data[1] = 32'h01000000;
            input_data[2] = 32'h01000000;
            input_data[3] = 32'h01000000;
            input_data[4] = 32'h01000000;
            input_data[5] = 32'h01000000;
            input_data[6] = 32'h01000000;
            input_data[7] = 32'h01000000;
            run_fft("back_to_back_2");
            check_bin("back_to_back_2", 0, output_data[0][31:16], output_data[0][15:0], 16'sh0800, 16'sh0000);
            check_bin("back_to_back_2", 1, output_data[1][31:16], output_data[1][15:0], 16'sh0000, 16'sh0000);
            check_bin("back_to_back_2", 2, output_data[2][31:16], output_data[2][15:0], 16'sh0000, 16'sh0000);
            check_bin("back_to_back_2", 3, output_data[3][31:16], output_data[3][15:0], 16'sh0000, 16'sh0000);
            check_bin("back_to_back_2", 4, output_data[4][31:16], output_data[4][15:0], 16'sh0000, 16'sh0000);
            check_bin("back_to_back_2", 5, output_data[5][31:16], output_data[5][15:0], 16'sh0000, 16'sh0000);
            check_bin("back_to_back_2", 6, output_data[6][31:16], output_data[6][15:0], 16'sh0000, 16'sh0000);
            check_bin("back_to_back_2", 7, output_data[7][31:16], output_data[7][15:0], 16'sh0000, 16'sh0000);
        end

        // ---- Reset mid-computation: assert reset while an FFT is in
        //      flight, confirm clean recovery for the next run ----
        begin : reset_midflight
            input_data[0] = 32'h0080001a;
            input_data[1] = 32'hffb30033;
            input_data[2] = 32'h00cdffb3;
            input_data[3] = 32'hff660066;
            input_data[4] = 32'h0033ff80;
            input_data[5] = 32'hff1a009a;
            input_data[6] = 32'h0066ff4d;
            input_data[7] = 32'hffe600cd;
            @(posedge clk); start = 1'b1; @(posedge clk); start = 1'b0;
            repeat (5) @(posedge clk); // partway through computation
            reset_n = 1'b0;
            repeat (3) @(posedge clk);
            if (done !== 1'b0) report_fail("reset_midflight: done asserted right after reset during an in-flight computation");
            reset_n = 1'b1;
            repeat (3) @(posedge clk);
            input_data[0] = 32'h0080001a;
            input_data[1] = 32'hffb30033;
            input_data[2] = 32'h00cdffb3;
            input_data[3] = 32'hff660066;
            input_data[4] = 32'h0033ff80;
            input_data[5] = 32'hff1a009a;
            input_data[6] = 32'h0066ff4d;
            input_data[7] = 32'hffe600cd;
            run_fft("reset_midflight_recovery");
            check_bin("reset_midflight_recovery", 0, output_data[0][31:16], output_data[0][15:0], 16'sh0000, 16'sh009a);
            check_bin("reset_midflight_recovery", 1, output_data[1][31:16], output_data[1][15:0], 16'sh00ea, 16'sh0021);
            check_bin("reset_midflight_recovery", 2, output_data[2][31:16], output_data[2][15:0], 16'shff1a, 16'sh011a);
            check_bin("reset_midflight_recovery", 3, output_data[3][31:16], output_data[3][15:0], 16'shfe8e, 16'sh00ee);
            check_bin("reset_midflight_recovery", 4, output_data[4][31:16], output_data[4][15:0], 16'sh03cd, 16'shfc9a);
            check_bin("reset_midflight_recovery", 5, output_data[5][31:16], output_data[5][15:0], 16'sh007d, 16'sh0045);
            check_bin("reset_midflight_recovery", 6, output_data[6][31:16], output_data[6][15:0], 16'shffe6, 16'sh001a);
            check_bin("reset_midflight_recovery", 7, output_data[7][31:16], output_data[7][15:0], 16'sh013e, 16'sh0112);
        end

        if (margin_violations > 0)
            report_fail("timing_margin: butterfly_valid was LOW at the FSM's fixed consumption point at least once (pipeline latency margin violated)");

        #100;
        $display("[*] Checked %0d vectors, %0d bins total, tolerance=+-%0d Q8.8 LSBs.", vectors_checked, bins_checked, TOLERANCE);
        if (fail_count == 0) begin
            $display("[+] All checks passed: reset sanity, %0d golden-reference vectors, back-to-back runs, mid-flight reset recovery, pipeline timing margin.", vectors_checked);
            $display("SIMULATION PASSED");
        end else begin
            $display("[-] %0d check(s) failed (first failing check index: %0d).", fail_count, first_fail_code);
            $display("SIMULATION FAILED (code=%0d mismatches)", fail_count);
        end
        $finish;
    end

    initial begin
        #5000000;
        $display("SIMULATION FAILED (code=999 global_timeout)");
        $finish;
    end

endmodule

