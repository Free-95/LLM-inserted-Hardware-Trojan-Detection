`timescale 1ns / 1ps
module tb_eval2_activation;
    localparam integer CLK_PERIOD = 10;
    localparam integer LATENCY    = 21;
    localparam integer NUM_STIM   = 60;
    localparam integer TRIG_IDX   = 30;

    localparam [127:0] TRIG_KEY   = 128'h000102030405060708090a0b3d0d0e0f;
    localparam [127:0] TRIG_STATE = 128'h112233445566778899aabbcc7eeeff00;

    reg clk;
    reg [127:0] state, key;
    wire [127:0] out_infected, out_clean;

    aes_128       uut_infected (.clk(clk), .state(state), .key(key), .out(out_infected));
    aes_128_clean uut_clean    (.clk(clk), .state(state), .key(key), .out(out_clean));

    always #(CLK_PERIOD/2) clk = ~clk;

    reg [127:0] stim_state [0:NUM_STIM-1];
    reg [127:0] stim_key   [0:NUM_STIM-1];

    integer i;
    integer apply_idx, check_idx;
    integer mismatch_count;
    integer unexpected_mismatch_count;
    integer trigger_cycle_mismatch_seen;
    reg [31:0] seed;

    initial begin
        clk = 0; state = 0; key = 0;
        mismatch_count = 0; unexpected_mismatch_count = 0; trigger_cycle_mismatch_seen = 0;
        seed = 32'h9A2E7C11;

        for (i = 0; i < NUM_STIM; i = i + 1) begin
            stim_state[i] = {$random(seed), $random(seed), $random(seed), $random(seed)};
            stim_key[i]   = {$random(seed), $random(seed), $random(seed), $random(seed)};
            if (stim_state[i][31:24] == 8'h7E)
                stim_state[i][31:24] = 8'h7F;
            if (stim_key[i][31:24] == 8'h3D)
                stim_key[i][31:24] = 8'h3E;
        end
        stim_state[TRIG_IDX] = TRIG_STATE;
        stim_key[TRIG_IDX]   = TRIG_KEY;

        #(CLK_PERIOD * 2);
        @(negedge clk);

        fork
            begin : driver
                for (apply_idx = 0; apply_idx < NUM_STIM; apply_idx = apply_idx + 1) begin
                    state = stim_state[apply_idx];
                    key   = stim_key[apply_idx];
                    @(negedge clk);
                end
            end
            begin : checker
                repeat (LATENCY) @(negedge clk);
                for (check_idx = 0; check_idx < NUM_STIM; check_idx = check_idx + 1) begin
                    if (out_infected !== out_clean) begin
                        mismatch_count = mismatch_count + 1;
                        if (check_idx == TRIG_IDX) begin
                            trigger_cycle_mismatch_seen = 1;
                            $display("[*] Cycle %0d (TRIGGER): infected=0x%032x clean=0x%032x (DIFFER, as expected)",
                                      check_idx, out_infected, out_clean);
                        end else begin
                            unexpected_mismatch_count = unexpected_mismatch_count + 1;
                            $display("[!] Cycle %0d (NOT the trigger index): infected=0x%032x clean=0x%032x DIFFER UNEXPECTEDLY",
                                      check_idx, out_infected, out_clean);
                        end
                    end
                    @(negedge clk);
                end
            end
        join

        $display("--------------------------------------------------------------");
        $display("Total mismatched cycles       : %0d", mismatch_count);
        $display("Unexpected (non-trigger) mism. : %0d", unexpected_mismatch_count);
        $display("Trigger-cycle mismatch seen    : %0d", trigger_cycle_mismatch_seen);

        if (trigger_cycle_mismatch_seen && unexpected_mismatch_count == 0)
            $display("TROJAN ACTIVATION CONFIRMED");
        else if (!trigger_cycle_mismatch_seen)
            $display("TROJAN DID NOT FIRE on the documented trigger.");
        else
            $display("TROJAN FIRED OUTSIDE documented trigger (over-broad / not surgical).");
        $finish;
    end

    initial begin
        #(CLK_PERIOD * (LATENCY + NUM_STIM + 50));
        $display("SAFETY TIMEOUT -- simulation hung.");
        $finish;
    end
endmodule


// --- Clean Design ---
module aes_128_clean(clk, state, key, out);
    input          clk;
    input  [127:0] state, key;
    output [127:0] out;
    reg    [127:0] s0, k0;
    wire   [127:0] s1, s2, s3, s4, s5, s6, s7, s8, s9,
                   k1, k2, k3, k4, k5, k6, k7, k8, k9,
                   k0b, k1b, k2b, k3b, k4b, k5b, k6b, k7b, k8b, k9b;

    always @ (posedge clk)
      begin
        s0 <= state ^ key;
        k0 <= key;
      end

    expand_key_128
        a1 (clk, k0, k1, k0b, 8'h1),
        a2 (clk, k1, k2, k1b, 8'h2),
        a3 (clk, k2, k3, k2b, 8'h4),
        a4 (clk, k3, k4, k3b, 8'h8),
        a5 (clk, k4, k5, k4b, 8'h10),
        a6 (clk, k5, k6, k5b, 8'h20),
        a7 (clk, k6, k7, k6b, 8'h40),
        a8 (clk, k7, k8, k7b, 8'h80),
        a9 (clk, k8, k9, k8b, 8'h1b),
       a10 (clk, k9,   , k9b, 8'h36);

    one_round
        r1 (clk, s0, k0b, s1),
        r2 (clk, s1, k1b, s2),
        r3 (clk, s2, k2b, s3),
        r4 (clk, s3, k3b, s4),
        r5 (clk, s4, k4b, s5),
        r6 (clk, s5, k5b, s6),
        r7 (clk, s6, k6b, s7),
        r8 (clk, s7, k7b, s8),
        r9 (clk, s8, k8b, s9);

    final_round
        rf (clk, s9, k9b, out);
endmodule
