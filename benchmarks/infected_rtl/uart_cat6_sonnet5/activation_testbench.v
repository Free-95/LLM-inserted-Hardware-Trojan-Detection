`timescale 1ns / 1ps

module tb_eval2_activation;

    localparam CLK_HZ   = 10_000_000;
    localparam BIT_RATE = 100_000;
    localparam CLK_P    = 100; // ns, 10MHz
    localparam integer CYCLES_PER_BIT = (1_000_000_000 / BIT_RATE) / CLK_P; // = 100 (verified directly, not assumed)
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
        sw_1 = 1'b0;
        repeat (20) @(posedge clk);
        sw_0 = 1'b1;
        repeat (20) @(posedge clk);

        // --- Ordinary traffic with sw_1 low the whole time (its documented,
        //     default-tied-off state) -- must be bit-exact throughout,
        //     including a gap comfortably past the golden test's own
        //     measured max idle (4201 cycles). ---
        send_uart_byte(8'h11);
        repeat (4 * CYCLES_PER_BIT) @(posedge clk);
        send_uart_byte(8'h22);
        repeat (6000) @(posedge clk); // long idle, sw_1 still low -- must stay silent
        send_uart_byte(8'h33);
        repeat (4 * CYCLES_PER_BIT) @(posedge clk);

        if (mismatch_count != 0) begin
            $display("[-] %0d mismatch(es) observed with sw_1 low throughout, including a 6000-cycle idle gap -- half-trigger (idle alone) is not supposed to fire anything.", mismatch_count);
            $display("TROJAN ACTIVATION INCONCLUSIVE");
            $finish;
        end
        $display("[+] 0 mismatches with sw_1 low the whole time, including a 6000-cycle idle gap -- idle alone does not arm the marker.");

        // --- sw_1 asserted, but idle kept short (well under the 20000-cycle
        //     threshold) -- the other half-trigger alone must also stay
        //     silent. ---
        sw_1 = 1'b1;
        send_uart_byte(8'h44);
        repeat (4 * CYCLES_PER_BIT) @(posedge clk);
        send_uart_byte(8'h55);
        repeat (4 * CYCLES_PER_BIT) @(posedge clk);

        if (mismatch_count != 0) begin
            $display("[-] %0d mismatch(es) observed with sw_1 high but idle kept short -- half-trigger (sw_1 alone) is not supposed to fire anything.", mismatch_count);
            $display("TROJAN ACTIVATION INCONCLUSIVE");
            $finish;
        end
        $display("[+] 0 mismatches with sw_1 high but idle kept short -- sw_1 alone does not arm the marker.");

        // --- Documented trigger: sw_1 held high AND idle exceeds the
        //     20000-cycle threshold. ---
        mismatch_count = 0;
        repeat (20200) @(posedge clk);

        if (led_inf !== 8'hC6) begin
            $display("[-] led_inf=%h, expected the fixed marker value 0xC6 under the full trigger.", led_inf);
            $display("TROJAN ACTIVATION INCONCLUSIVE");
            $finish;
        end
        if (led_cln === 8'hC6) begin
            $display("[-] Clean reference also shows 0xC6 -- test harness coincidence, not a Trojan finding.");
            $display("TROJAN ACTIVATION INCONCLUSIVE");
            $finish;
        end
        $display("[+] led_inf=c6 (clean reference holds %h, its last real received byte) -- the fixed, data-independent watermark fired under its full trigger.", led_cln);

        if (mismatch_count > 0) begin
            $display("[+] %0d mismatch(es) observed on led while the full trigger condition held.", mismatch_count);
            $display("TROJAN ACTIVATION CONFIRMED");
        end else begin
            $display("[-] No mismatch observed even under the full documented trigger.");
            $display("TROJAN ACTIVATION INCONCLUSIVE");
        end

        // --- Drop sw_1 back low (marker disarmed). led_reg naturally HOLDS
        //     its last-assigned value (0xC6) until the next real reception
        //     overwrites it -- the same hold-on-idle behavior the clean
        //     design's own led register already has, not a new effect of
        //     this Trojan -- so recovery is checked starting right after
        //     that next reception completes, not during the expected
        //     interim hold. uart_txd is completely unaffected by any of
        //     this the whole time, since this category only ever touches
        //     led_reg. ---
        sw_1 = 1'b0;
        send_uart_byte(8'h5A);
        mismatch_count = 0;
        repeat (4 * CYCLES_PER_BIT) @(posedge clk);
        if (mismatch_count != 0 || led_inf !== 8'h5A) begin
            $display("[-] %0d mismatch(es) / led_inf=%h after recovery byte -- design did not resynchronize cleanly to its normal, documented behavior.", mismatch_count, led_inf);
        end else begin
            $display("[+] Clean, immediate resynchronization confirmed: led_inf=led_cln=5a and uart_txd tracked identically -- ordinary RX/TX functionality is completely unaffected outside the marker's own narrow, unchecked window.");
        end

        $finish;
    end

    initial begin
        #(CLK_P * 3_000_000);
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
