`timescale 1ns / 1ps
module tb_eval2_activation;
    localparam integer CLK_PERIOD = 10;
    localparam integer LATENCY    = 21;
    localparam integer NUM_STIM   = 60;
    localparam integer TRIG_IDX   = 30;

    reg clk;
    reg [127:0] state, key;
    wire [127:0] out_infected, out_golden;

    aes_128        uut_infected (.clk(clk), .state(state), .key(key), .out(out_infected));
    aes_128_golden uut_golden   (.clk(clk), .state(state), .key(key), .out(out_golden));

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
        seed = 32'hABCD1234;

        for (i = 0; i < NUM_STIM; i = i + 1) begin
            stim_state[i] = {$random(seed), $random(seed), $random(seed), $random(seed)};
            stim_key[i]   = {$random(seed), $random(seed), $random(seed), $random(seed)};
            // Make sure no random non-trigger stimulus accidentally satisfies the trigger.
            stim_state[i][7:0] = (stim_state[i][7:0] == 8'h5A) ? 8'h5B : stim_state[i][7:0];
            stim_key[i][7:0]   = (stim_key[i][7:0]   == 8'hA5) ? 8'hA6 : stim_key[i][7:0];
        end
        stim_state[TRIG_IDX] = {120'h112233445566778899AABBCCDD, 8'h5A};
        stim_key[TRIG_IDX]   = {120'h0001020304050607080910111213, 8'hA5};

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
                    if (out_infected !== out_golden) begin
                        mismatch_count = mismatch_count + 1;
                        if (check_idx == TRIG_IDX) begin
                            trigger_cycle_mismatch_seen = 1;
                            $display("[*] Cycle %0d (TRIGGER): infected=0x%032x golden=0x%032x (DIFFER, as expected)",
                                      check_idx, out_infected, out_golden);
                        end else begin
                            unexpected_mismatch_count = unexpected_mismatch_count + 1;
                            $display("[!] Cycle %0d (NOT trigger): infected=0x%032x golden=0x%032x DIFFER UNEXPECTEDLY",
                                      check_idx, out_infected, out_golden);
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
            $display("TROJAN DID NOT FIRE on documented trigger.");
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
