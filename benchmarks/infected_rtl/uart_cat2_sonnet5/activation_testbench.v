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
    integer n;

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

    always @(posedge clk) begin
        if (sw_0 === 1'b1) begin
            if (uart_txd_inf !== uart_txd_cln) begin
                mismatch_count = mismatch_count + 1;
            end
            if (led_inf !== led_cln) begin
                mismatch_count = mismatch_count + 1;
                $display("[DIFF] t=%0t led_inf=%h led_cln=%h (after %0d bytes sent)",
                          $time, led_inf, led_cln, n);
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

    // Cycles an easily-distinguished, non-degenerate byte per reception so
    // every individual mismatch is unambiguous (never all-zero/all-same).
    function [7:0] ordinary_byte(input integer idx);
        begin
            ordinary_byte = 8'h10 + (idx % 8'hD0); // walks through a wide, varied range
        end
    endfunction

    initial begin
        mismatch_count = 0;

        sw_0 = 1'b0;
        uart_rxd = 1'b1;
        repeat (20) @(posedge clk);
        sw_0 = 1'b1;
        repeat (20) @(posedge clk);

        // --- Send 149 ordinary, varied, non-degenerate bytes: the counter
        //     should reach 149 after these and still be fully dormant on
        //     every one of them (mirrors the golden testbench's own 70-byte
        //     scale, carried well past it). ---
        for (n = 1; n <= 149; n = n + 1) begin
            send_uart_byte(ordinary_byte(n));
            repeat (3 * CYCLES_PER_BIT) @(posedge clk);
        end

        if (mismatch_count != 0) begin
            $display("[-] %0d mismatch(es) observed BEFORE the documented trigger count -- dormancy violated.", mismatch_count);
            $display("TROJAN ACTIVATION INCONCLUSIVE");
            $finish;
        end

        // --- The 150th reception: documented trigger count (cal_cnt==150) ---
        mismatch_count = 0;
        send_uart_byte(8'h7A);
        n = 150;
        repeat (3 * CYCLES_PER_BIT) @(posedge clk);

        // One more ordinary byte afterwards to confirm the design recovers
        // and does not latch/hang.
        send_uart_byte(8'h5A);
        repeat (3 * CYCLES_PER_BIT) @(posedge clk);

        if (mismatch_count > 0) begin
            $display("[+] %0d mismatch(es) observed on/after the documented trigger count (150th reception).", mismatch_count);
            $display("TROJAN ACTIVATION CONFIRMED");
        end else begin
            $display("[-] No mismatch observed even at the documented trigger count.");
            $display("TROJAN ACTIVATION INCONCLUSIVE");
        end

        $finish;
    end

    initial begin
        #(CLK_P * 5_000_000);
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
