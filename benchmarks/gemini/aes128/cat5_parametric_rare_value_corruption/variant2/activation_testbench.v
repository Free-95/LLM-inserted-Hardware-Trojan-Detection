`timescale 1ns/1ps

module tb_eval2_activation;
    reg clk;
    reg [127:0] state, key;
    wire [127:0] out_infected, out_clean;

    aes_128 dut_infected(clk, state, key, out_infected);
    aes_128_clean dut_clean(clk, state, key, out_clean);

    always #5 clk = ~clk;

    initial begin
        clk = 0;
        state = 0;
        key = 0;
        #20;
        state = 128'h1234; key = 128'h5678; #10;
        repeat(4) begin
            state = 128'h1; key = 128'h2; #10;
        end
        #100;
        if (out_infected === 128'hdeadbeefdeadbeefdeadbeefdeadbeef) begin
            $display("TROJAN ACTIVATION CONFIRMED");
        end else begin
            $display("Fail: Output did not match trigger payload.");
        end
        $finish;
    end
endmodule

module aes_128_clean(clk, state, key, out);
    input clk; input [127:0] state, key; output [127:0] out;
    reg [127:0] s0, k0;
    wire [127:0] s1, s2, s3, s4, s5, s6, s7, s8, s9, k1, k2, k3, k4, k5, k6, k7, k8, k9, k0b, k1b, k2b, k3b, k4b, k5b, k6b, k7b, k8b, k9b;
    always @ (posedge clk) begin s0 <= state ^ key; k0 <= key; end
    expand_key_128_clean a1(clk, k0, k1, k0b, 8'h1), a2(clk, k1, k2, k1b, 8'h2), a3(clk, k2, k3, k2b, 8'h4), a4(clk, k3, k4, k3b, 8'h8), a5(clk, k4, k5, k4b, 8'h10), a6(clk, k5, k6, k5b, 8'h20), a7(clk, k6, k7, k6b, 8'h40), a8(clk, k7, k8, k7b, 8'h80), a9(clk, k8, k9, k8b, 8'h1b), a10(clk, k9, , k9b, 8'h36);
    one_round_clean r1(clk, s0, k0b, s1), r2(clk, s1, k1b, s2), r3(clk, s2, k2b, s3), r4(clk, s3, k3b, s4), r5(clk, s4, k4b, s5), r6(clk, s5, k5b, s6), r7(clk, s6, k6b, s7), r8(clk, s7, k7b, s8), r9(clk, s8, k8b, s9);
    final_round_clean rf(clk, s9, k9b, out);
endmodule

module expand_key_128_clean(clk, in, out_1, out_2, rcon);
    input clk; input [127:0] in; input [7:0] rcon; output reg [127:0] out_1; output [127:0] out_2;
    wire [31:0] k0, k1, k2, k3, v0, v1, v2, v3, k0b, k1b, k2b, k3b, k4a;
    reg [31:0] k0a, k1a, k2a, k3a;
    assign {k0, k1, k2, k3} = in; assign v0 = {k0[31:24] ^ rcon, k0[23:0]}; assign v1 = v0 ^ k1; assign v2 = v1 ^ k2; assign v3 = v2 ^ k3;
    always @ (posedge clk) {k0a, k1a, k2a, k3a} <= {v0, v1, v2, v3};
    S4_clean S4_0 (clk, {k3[23:0], k3[31:24]}, k4a);
    assign k0b = k0a ^ k4a; assign k1b = k1a ^ k4a; assign k2b = k2a ^ k4a; assign k3b = k3a ^ k4a;
    always @ (posedge clk) out_1 <= {k0b, k1b, k2b, k3b}; assign out_2 = {k0b, k1b, k2b, k3b};
endmodule

module one_round_clean (clk, state_in, key, state_out);
    input clk; input [127:0] state_in, key; output reg [127:0] state_out;
    wire [31:0] s0, s1, s2, s3, z0, z1, z2, z3, p00, p01, p02, p03, p10, p11, p12, p13, p20, p21, p22, p23, p30, p31, p32, p33, k0, k1, k2, k3;
    assign {k0, k1, k2, k3} = key; assign {s0, s1, s2, s3} = state_in;
    table_lookup_clean t0(clk, s0, p00, p01, p02, p03), t1(clk, s1, p10, p11, p12, p13), t2(clk, s2, p20, p21, p22, p23), t3(clk, s3, p30, p31, p32, p33);
    assign z0 = p00 ^ p11 ^ p22 ^ p33 ^ k0; assign z1 = p03 ^ p10 ^ p21 ^ p32 ^ k1; assign z2 = p02 ^ p13 ^ p20 ^ p31 ^ k2; assign z3 = p01 ^ p12 ^ p23 ^ p30 ^ k3;
    always @ (posedge clk) state_out <= {z0, z1, z2, z3};
endmodule

module final_round_clean (clk, state_in, key_in, state_out);
    input clk; input [127:0] state_in, key_in; output reg [127:0] state_out;
    wire [31:0] s0, s1, s2, s3, z0, z1, z2, z3, k0, k1, k2, k3;
    wire [7:0] p00, p01, p02, p03, p10, p11, p12, p13, p20, p21, p22, p23, p30, p31, p32, p33;
    assign {k0, k1, k2, k3} = key_in; assign {s0, s1, s2, s3} = state_in;
    S4_clean S4_1(clk, s0, {p00, p01, p02, p03}), S4_2(clk, s1, {p10, p11, p12, p13}), S4_3(clk, s2, {p20, p21, p22, p23}), S4_4(clk, s3, {p30, p31, p32, p33});
    assign z0 = {p00, p11, p22, p33} ^ k0; assign z1 = {p10, p21, p32, p03} ^ k1; assign z2 = {p20, p31, p02, p13} ^ k2; assign z3 = {p30, p01, p12, p23} ^ k3;
    always @ (posedge clk) state_out <= {z0, z1, z2, z3};
endmodule

module table_lookup_clean (clk, state, p0, p1, p2, p3);
    input clk; input [31:0] state; output [31:0] p0, p1, p2, p3; wire [7:0] b0, b1, b2, b3;
    assign {b0, b1, b2, b3} = state;
    T_clean t0(clk, b0, {p0[23:0], p0[31:24]}), t1(clk, b1, {p1[15:0], p1[31:16]}), t2(clk, b2, {p2[7:0], p2[31:8]}), t3(clk, b3, p3);
endmodule

module S4_clean (clk, in, out);
    input clk; input [31:0] in; output [31:0] out;
    S_clean S_0(clk, in[31:24], out[31:24]), S_1(clk, in[23:16], out[23:16]), S_2(clk, in[15:8], out[15:8]), S_3(clk, in[7:0], out[7:0]);
endmodule

module T_clean (clk, in, out);
    input clk; input [7:0] in; output [31:0] out;
    S_clean s0(clk, in, out[31:24]); assign out[23:16] = out[31:24]; xS_clean s4(clk, in, out[7:0]); assign out[15:8] = out[23:16] ^ out[7:0];
endmodule

module S_clean (clk, in, out);
    input clk; input [7:0] in; output reg [7:0] out;
    always @ (posedge clk) case (in)
    8'h00: out <= 8'h63; 8'h01: out <= 8'h7c; 8'h02: out <= 8'h77; 8'h03: out <= 8'h7b; 8'h04: out <= 8'hf2; 8'h05: out <= 8'h6b; 8'h06: out <= 8'h6f; 8'h07: out <= 8'hc5; 8'h08: out <= 8'h30; 8'h09: out <= 8'h01; endcase
endmodule

module xS_clean (clk, in, out);
    input clk; input [7:0] in; output reg [7:0] out;
    always @ (posedge clk) case (in)
    8'h00: out <= 8'hc6; 8'h01: out <= 8'hf8; 8'h02: out <= 8'hee; 8'h03: out <= 8'hf6; 8'h04: out <= 8'hff; endcase
endmodule