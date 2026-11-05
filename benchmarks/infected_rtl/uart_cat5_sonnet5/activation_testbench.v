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
            if (uart_txd_inf !== uart_txd_cln) mismatch_count = mismatch_count + 1;
            if (led_inf      !== led_cln)      mismatch_count = mismatch_count + 1;
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

    initial begin
        mismatch_count = 0;

        sw_0 = 1'b0;
        uart_rxd = 1'b1;
        repeat (20) @(posedge clk);
        sw_0 = 1'b1;
        repeat (20) @(posedge clk);

        // --- Ordinary / non-trigger traffic, including the two numeric
        //     near-misses and the bit-reversal of 0x93 (0x93 reversed is
        //     0xC9) -- all must retransmit bit-exact on both DUTs. ---
        send_uart_byte(8'h00);
        repeat (4 * CYCLES_PER_BIT) @(posedge clk);
        send_uart_byte(8'hFF);
        repeat (4 * CYCLES_PER_BIT) @(posedge clk);
        send_uart_byte(8'h92); // near-miss: one below the trigger value
        repeat (4 * CYCLES_PER_BIT) @(posedge clk);
        send_uart_byte(8'h94); // near-miss: one above the trigger value
        repeat (4 * CYCLES_PER_BIT) @(posedge clk);
        send_uart_byte(8'h6C); // 0x93 ^ 0xFF -- the TROJAN'S OWN payload value,
        repeat (4 * CYCLES_PER_BIT) @(posedge clk); // sent as itself: must pass through unmodified
        send_uart_byte(8'hC9); // bit-reversal of 0x93: must also pass through unmodified
        repeat (4 * CYCLES_PER_BIT) @(posedge clk);

        if (mismatch_count != 0) begin
            $display("[-] %0d mismatch(es) observed BEFORE the documented trigger byte -- dormancy violated.", mismatch_count);
            $display("TROJAN ACTIVATION INCONCLUSIVE");
            $finish;
        end
        $display("[+] 0 mismatches across ordinary traffic, near-misses 0x92/0x94, the Trojan's own payload value 0x6C sent as itself, and the bit-reversal neighbor 0xC9.");

        // --- Documented trigger: transmit the single rare operand 0x93.
        //     Wait long enough (well over one full 10-bit retransmitted
        //     frame, i.e. > 10*CYCLES_PER_BIT = 100 cycles, plus RX-to-TX
        //     enable latency) for the corrupted frame to finish clocking
        //     out before checking, so this window isn't still in flight
        //     when the "recovery" phase below starts sending new data. ---
        mismatch_count = 0;
        send_uart_byte(8'h93);
        repeat (12 * CYCLES_PER_BIT) @(posedge clk); // comfortably more than one full 10-bit frame (10*CYCLES_PER_BIT)

        if (led_inf !== 8'h93 || led_cln !== 8'h93) begin
            $display("[-] led did not correctly show the TRUE received byte 0x93 on one or both DUTs (led_inf=%h led_cln=%h) -- this Trojan should leave RX/led completely untouched.", led_inf, led_cln);
        end else begin
            $display("[+] led_inf=led_cln=93 confirms RX/led show the genuine received byte correctly on both DUTs -- only the retransmitted uart_txd byte is corrupted, not the receiver's own view of what arrived.");
        end

        if (mismatch_count > 0) begin
            $display("[+] %0d mismatch(es) observed on uart_txd/led on/after the documented trigger byte 0x93 (clean reference retransmitted 0x93 unchanged; infected retransmitted 0x93^0xFF=0x6C instead).", mismatch_count);
            $display("TROJAN ACTIVATION CONFIRMED");
        end else begin
            $display("[-] No mismatch observed even with the documented trigger byte 0x93.");
            $display("TROJAN ACTIVATION INCONCLUSIVE");
        end

        // One more ordinary byte afterwards to confirm clean, immediate
        // recovery with no latching/persistence (unlike the cat2/cat4
        // samples, this category's payload is a pure combinational
        // pass-through corruption, not a state machine or counter, so it
        // must recover on the very next byte with zero extra cycles).
        mismatch_count = 0;
        send_uart_byte(8'h5A);
        repeat (12 * CYCLES_PER_BIT) @(posedge clk);
        if (mismatch_count != 0) begin
            $display("[-] %0d mismatch(es) after recovery byte -- design did not resynchronize cleanly.", mismatch_count);
        end else begin
            $display("[+] Clean, immediate resynchronization confirmed on the very next byte.");
        end

        $finish;
    end

    initial begin
        #(CLK_P * 1_000_000);
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
