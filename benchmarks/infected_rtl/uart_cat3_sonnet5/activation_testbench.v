`timescale 1ns / 1ps

module tb_eval2_activation;

    localparam CLK_HZ   = 10_000_000;
    localparam BIT_RATE = 100_000;
    localparam CLK_P    = 100; // ns, 10MHz
    localparam integer CYCLES_PER_BIT = (1_000_000_000 / BIT_RATE) / CLK_P; // = 10
    localparam integer BIT_P = CYCLES_PER_BIT * CLK_P;

    reg clk = 0;
    always #(CLK_P/2) clk = ~clk;

    reg sw_0 = 0;
    reg sw_1 = 0;
    reg uart_rxd = 1;

    wire uart_txd_inf, uart_txd_cln;
    wire [7:0] led_inf, led_cln;

    integer mismatch_count = 0;
    integer leak_mismatch_count = 0;

    impl_top #(.CLK_HZ(CLK_HZ), .BIT_RATE(BIT_RATE)) dut_infected (
        .clk      (clk),
        .sw_0     (sw_0),
        .sw_1     (sw_1),
        .uart_rxd (uart_rxd),
        .uart_txd (uart_txd_inf),
        .led      (led_inf)
    );

    impl_top_clean #(.CLK_HZ(CLK_HZ), .BIT_RATE(BIT_RATE)) dut_clean (
        .clk      (clk),
        .sw_0     (sw_0),
        .sw_1     (sw_1),
        .uart_rxd (uart_rxd),
        .uart_txd (uart_txd_cln),
        .led      (led_cln)
    );

    // Mirrors the golden testbench's OWN checking convention: only compare
    // right after reset, and shortly after each reception -- never during
    // raw idle gaps -- so this check-point set itself can never be what
    // "catches" the leak; the leak must be proven separately, below, by
    // directly reading led during an extended idle window.
    reg checkpoint_mode = 0;
    always @(posedge clk) begin
        if (checkpoint_mode && sw_0 === 1'b1) begin
            if (uart_txd_inf !== uart_txd_cln) begin
                mismatch_count = mismatch_count + 1;
                $display("[DIFF-AT-CHECKPOINT] t=%0t uart_txd_inf=%b uart_txd_cln=%b",
                          $time, uart_txd_inf, uart_txd_cln);
            end
            if (led_inf !== led_cln) begin
                mismatch_count = mismatch_count + 1;
                $display("[DIFF-AT-CHECKPOINT] t=%0t led_inf=%h led_cln=%h",
                          $time, led_inf, led_cln);
            end
        end
    end

    task automatic send_uart_byte(input [7:0] data);
        integer b;
        begin
            uart_rxd = 1'b0;               // start bit
            #(BIT_P);
            for (b = 0; b < 8; b = b + 1) begin
                uart_rxd = data[b];         // LSB first
                #(BIT_P);
            end
            uart_rxd = 1'b1;               // stop bit
            #(BIT_P);
        end
    endtask

    // Sends a byte and checks led/uart_txd only a few cycles afterward --
    // exactly the golden testbench's own checkpoint discipline.
    task automatic checked_byte(input [7:0] data);
        begin
            checkpoint_mode = 0;
            send_uart_byte(data);
            repeat (3) @(posedge clk);
            checkpoint_mode = 1;
            @(posedge clk);
            checkpoint_mode = 0;
        end
    endtask

    initial begin
        mismatch_count = 0;
        leak_mismatch_count = 0;

        sw_0 = 1'b0;
        uart_rxd = 1'b1;
        repeat (20) @(posedge clk);
        sw_0 = 1'b1;
        repeat (20) @(posedge clk);

        // --- Ordinary traffic, with idle gaps exercised up to and slightly
        //     beyond the golden testbench's own measured maximum (4201
        //     cycles) between some of the bytes, checked only at golden-
        //     testbench-style checkpoints each time. Must show 0 mismatches
        //     at every checkpoint. ---
        checked_byte(8'h11);
        repeat (20) @(posedge clk);                 // short gap, like most inter-byte gaps
        checked_byte(8'h22);
        repeat (4300) @(posedge clk);                // long gap, slightly past the golden test's own observed max
        checked_byte(8'h44);
        repeat (20) @(posedge clk);
        checked_byte(8'h08);

        if (mismatch_count != 0) begin
            $display("[-] %0d mismatch(es) observed at golden-testbench-style checkpoints -- dormancy violated.", mismatch_count);
            $display("TROJAN ACTIVATION INCONCLUSIVE");
            $finish;
        end
        $display("[+] 0 mismatches at any checkpoint across ordinary traffic, including a gap past the golden test's own max idle (4201 cycles).");

        // --- Documented trigger: let the link go idle (no reception) for
        //     longer than quiet_cnt's 12000-cycle threshold, THEN read led
        //     directly (not at a golden-style checkpoint) and compare it to
        //     the independent accumulator this testbench keeps alongside the
        //     clean DUT, as well as to the clean DUT's own (unchanged) led. ---
        repeat (12100) @(posedge clk);

        if (led_inf === led_cln) begin
            $display("[-] led_inf matches led_cln even after the documented idle threshold -- no leak observed.");
            $display("TROJAN ACTIVATION INCONCLUSIVE");
        end else if (led_inf === 8'h7F) begin
            // 8'h11 ^ 8'h22 ^ 8'h44 ^ 8'h08 == 8'h7F: the exact expected
            // traffic digest of the four bytes sent above.
            $display("[+] After idle threshold, led_inf=%h (clean reference still holds %h, the last real received byte) -- infected led now exposes the session traffic digest (0x11^0x22^0x44^0x08=0x7F) instead.", led_inf, led_cln);
            $display("TROJAN ACTIVATION CONFIRMED");
        end else begin
            $display("[?] led_inf=%h diverged from led_cln=%h after the idle threshold, but not to the expected digest value -- investigate.", led_inf, led_cln);
            $display("TROJAN ACTIVATION INCONCLUSIVE");
        end

        // --- Confirm recovery: a fresh byte afterward must resync both
        //     DUTs to the identical, correct value at the next checkpoint. ---
        checked_byte(8'h5A);
        if (mismatch_count != 0) begin
            $display("[-] %0d mismatch(es) after recovery byte -- design did not resynchronize cleanly.", mismatch_count);
        end else begin
            $display("[+] Clean resynchronization confirmed: both DUTs match again at the next reception checkpoint.");
        end

        $finish;
    end

    initial begin
        #(CLK_P * 2_000_000);
        $display("[-] Watchdog timeout -- simulation did not finish.");
        $display("TROJAN ACTIVATION INCONCLUSIVE");
        $finish;
    end

endmodule

// ===========================================================================
// Embedded CLEAN reference hierarchy (verbatim copies of the clean baseline,
// renamed with a _clean suffix on every module and every internal
// instantiation reference so the two hierarchies never collide).
// ===========================================================================


// 
// Module: impl_top
// 
// Notes:
// - Top level module to be used in an implementation.
// - To be used in conjunction with the constraints/defaults.xdc file.
// - Ports can be (un)commented depending on whether they are being used.
// - The constraints file contains a complete list of the available ports
//   including the chipkit/Arduino pins.
//

module impl_top_clean (
input               clk     , // Top level system clock input.
input               sw_0    , // Slide switches.
input               sw_1    , // Slide switches.
input   wire        uart_rxd, // UART Recieve pin.
output  wire        uart_txd, // UART transmit pin.
output  wire [7:0]  led
);

// Clock frequency in hertz.
parameter CLK_HZ = 50000000;
parameter BIT_RATE =   9600;
parameter PAYLOAD_BITS = 8;

wire [PAYLOAD_BITS-1:0]  uart_rx_data;
wire        uart_rx_valid;
wire        uart_rx_break;

wire        uart_tx_busy;
wire [PAYLOAD_BITS-1:0]  uart_tx_data;
wire        uart_tx_en;

reg  [PAYLOAD_BITS-1:0]  led_reg;
assign      led = led_reg;

// ------------------------------------------------------------------------- 

assign uart_tx_data = uart_rx_data;
assign uart_tx_en   = uart_rx_valid;

always @(posedge clk) begin
    if(!sw_0) begin
        led_reg <= 8'hF0;
    end else if(uart_rx_valid) begin
        led_reg <= uart_rx_data[7:0];
    end
end


// ------------------------------------------------------------------------- 

//
// UART RX
uart_rx #(
.BIT_RATE(BIT_RATE),
.PAYLOAD_BITS(PAYLOAD_BITS),
.CLK_HZ  (CLK_HZ  )
) i_uart_rx(
.clk          (clk          ), // Top level system clock input.
.resetn       (sw_0         ), // Asynchronous active low reset.
.uart_rxd     (uart_rxd     ), // UART Recieve pin.
.uart_rx_en   (1'b1         ), // Recieve enable
.uart_rx_break(uart_rx_break), // Did we get a BREAK message?
.uart_rx_valid(uart_rx_valid), // Valid data recieved and available.
.uart_rx_data (uart_rx_data )  // The recieved data.
);

//
// UART Transmitter module.
//
uart_tx #(
.BIT_RATE(BIT_RATE),
.PAYLOAD_BITS(PAYLOAD_BITS),
.CLK_HZ  (CLK_HZ  )
) i_uart_tx(
.clk          (clk          ),
.resetn       (sw_0         ),
.uart_txd     (uart_txd     ),
.uart_tx_en   (uart_tx_en   ),
.uart_tx_busy (uart_tx_busy ),
.uart_tx_data (uart_tx_data ) 
);


endmodule
