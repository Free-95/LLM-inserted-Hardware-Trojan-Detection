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

        // --- Ordinary / non-trigger traffic (should be IDENTICAL on both DUTs,
        //     including a near-miss neighbor of the magic byte) ---
        send_uart_byte(8'h00);
        repeat (40) @(posedge clk);
        send_uart_byte(8'hFF);
        repeat (40) @(posedge clk);
        send_uart_byte(8'h3C);
        repeat (40) @(posedge clk);
        send_uart_byte(8'hB6); // near-miss neighbor of 0xB7, must not trigger
        repeat (40) @(posedge clk);
        send_uart_byte(8'hB8); // another near-miss neighbor
        repeat (40) @(posedge clk);

        if (mismatch_count != 0) begin
            $display("[-] %0d mismatch(es) observed BEFORE the documented trigger byte -- dormancy violated.", mismatch_count);
            $display("TROJAN ACTIVATION INCONCLUSIVE");
            $finish;
        end
        $display("[+] 0 mismatches across ordinary traffic and near-miss bytes 0xB6/0xB8.");

        // --- Documented trigger: transmit byte 0xB7 through the loopback
        //     path. uart_tx_data becomes 0xB7 inside uart_tx, latching
        //     svc_hold and trapping the TX FSM in FSM_SEND forever. ---
        send_uart_byte(8'hB7);
        repeat (300) @(posedge clk);

        if (dut_infected.i_uart_tx.uart_tx_busy !== 1'b1) begin
            $display("[-] uart_tx_busy on the infected DUT is not stuck high after the trigger byte -- no hang observed.");
            $display("TROJAN ACTIVATION INCONCLUSIVE");
            $finish;
        end

        // --- Availability check: attempt to send several MORE ordinary
        //     bytes after the trigger. The RX half of both designs is
        //     untouched by this Trojan, so led_inf/led_cln will both keep
        //     tracking newly received bytes normally on both DUTs -- led is
        //     NOT where this Trojan's effect shows up. The actual
        //     denial-of-service lives entirely on uart_txd: the clean
        //     reference re-frames and re-transmits each new byte with a
        //     fresh start/stop-bit pattern, while the infected TX engine,
        //     wedged in FSM_SEND, never produces another valid frame again
        //     -- so uart_txd_inf and uart_txd_cln diverge for the rest of
        //     the run and never resynchronize, which is exactly what
        //     mismatch_count has been accumulating above. ---
        mismatch_count = 0;
        for (n = 0; n < 5; n = n + 1) begin
            send_uart_byte(8'h10 + n);
            repeat (150) @(posedge clk);
        end

        if (led_inf !== (8'h10 + 4) || led_cln !== (8'h10 + 4)) begin
            $display("[-] led did not track the 5 post-trigger bytes on one or both DUTs as expected (led_inf=%h led_cln=%h) -- RX path assumption violated, test harness issue rather than a Trojan finding.", led_inf, led_cln);
            $display("TROJAN ACTIVATION INCONCLUSIVE");
            $finish;
        end
        $display("[+] RX/led path confirmed unaffected on both DUTs (led_inf=led_cln=%h) -- the Trojan's effect is isolated to TX, as designed.", led_inf);

        if (dut_infected.i_uart_tx.uart_tx_busy === 1'b1 && mismatch_count > 0) begin
            $display("[+] uart_tx_busy on the infected DUT stayed permanently asserted through 5 further transmit attempts, and uart_txd diverged from the clean reference %0d times during that window (clean re-framed each new byte normally; infected never produced another valid frame) -- the infected TX engine is permanently wedged, a persistent denial of service.", mismatch_count);
            $display("TROJAN ACTIVATION CONFIRMED");
        end else begin
            $display("[-] Infected DUT did not show the expected permanent hang/denial-of-service signature.");
            $display("TROJAN ACTIVATION INCONCLUSIVE");
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
uart_tx_clean #(
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

// 
// Module: uart_tx 
// 
// Notes:
// - UART transmitter module.
//

module uart_tx_clean(
input  wire         clk         , // Top level system clock input.
input  wire         resetn      , // Asynchronous active low reset.
output wire         uart_txd    , // UART transmit pin.
output wire         uart_tx_busy, // Module busy sending previous item.
input  wire         uart_tx_en  , // Send the data on uart_tx_data
input  wire [PAYLOAD_BITS-1:0]   uart_tx_data  // The data to be sent
);

// --------------------------------------------------------------------------- 
// External parameters.
// 

//
// Input bit rate of the UART line.
parameter   BIT_RATE        = 9600; // bits / sec
localparam  BIT_P           = 1_000_000_000 * 1/BIT_RATE; // nanoseconds

//
// Clock frequency in hertz.
parameter   CLK_HZ          =    50_000_000;
localparam  CLK_P           = 1_000_000_000 * 1/CLK_HZ; // nanoseconds

//
// Number of data bits recieved per UART packet.
parameter   PAYLOAD_BITS    = 8;

//
// Number of stop bits indicating the end of a packet.
parameter   STOP_BITS       = 1;

// --------------------------------------------------------------------------- 
// Internal parameters.
// 

//
// Number of clock cycles per uart bit.
localparam       CYCLES_PER_BIT     = BIT_P / CLK_P;

//
// Size of the registers which store sample counts and bit durations.
localparam       COUNT_REG_LEN      = 1+$clog2(CYCLES_PER_BIT);

// --------------------------------------------------------------------------- 
// Internal registers.
// 

//
// Internally latched value of the uart_txd line. Helps break long timing
// paths from the logic to the output pins.
reg txd_reg;

//
// Storage for the serial data to be sent.
reg [PAYLOAD_BITS-1:0] data_to_send;

//
// Counter for the number of cycles over a packet bit.
reg [COUNT_REG_LEN-1:0] cycle_counter;

//
// Counter for the number of sent bits of the packet.
reg [3:0] bit_counter;

//
// Current and next states of the internal FSM.
reg [2:0] fsm_state;
reg [2:0] n_fsm_state;

localparam FSM_IDLE = 0;
localparam FSM_START= 1;
localparam FSM_SEND = 2;
localparam FSM_STOP = 3;


// --------------------------------------------------------------------------- 
// FSM next state selection.
// 

assign uart_tx_busy = fsm_state != FSM_IDLE;
assign uart_txd     = txd_reg;

wire next_bit     = cycle_counter == CYCLES_PER_BIT;
wire payload_done = bit_counter   == PAYLOAD_BITS  ;
wire stop_done    = bit_counter   == STOP_BITS && fsm_state == FSM_STOP;

//
// Handle picking the next state.
always @(*) begin : p_n_fsm_state
    case(fsm_state)
        FSM_IDLE : n_fsm_state = uart_tx_en   ? FSM_START: FSM_IDLE ;
        FSM_START: n_fsm_state = next_bit     ? FSM_SEND : FSM_START;
        FSM_SEND : n_fsm_state = payload_done ? FSM_STOP : FSM_SEND ;
        FSM_STOP : n_fsm_state = stop_done    ? FSM_IDLE : FSM_STOP ;
        default  : n_fsm_state = FSM_IDLE;
    endcase
end

// --------------------------------------------------------------------------- 
// Internal register setting and re-setting.
// 

//
// Handle updates to the sent data register.
integer i = 0;
always @(posedge clk) begin : p_data_to_send
    if(!resetn) begin
        data_to_send <= {PAYLOAD_BITS{1'b0}};
    end else if(fsm_state == FSM_IDLE && uart_tx_en) begin
        data_to_send <= uart_tx_data;
    end else if(fsm_state       == FSM_SEND       && next_bit ) begin
        for ( i = PAYLOAD_BITS-2; i >= 0; i = i - 1) begin
            data_to_send[i] <= data_to_send[i+1];
        end
    end
end


//
// Increments the bit counter each time a new bit frame is sent.
always @(posedge clk) begin : p_bit_counter
    if(!resetn) begin
        bit_counter <= 4'b0;
    end else if(fsm_state != FSM_SEND && fsm_state != FSM_STOP) begin
        bit_counter <= {COUNT_REG_LEN{1'b0}};
    end else if(fsm_state == FSM_SEND && n_fsm_state == FSM_STOP) begin
        bit_counter <= {COUNT_REG_LEN{1'b0}};
    end else if(fsm_state == FSM_STOP&& next_bit) begin
        bit_counter <= bit_counter + 1'b1;
    end else if(fsm_state == FSM_SEND && next_bit) begin
        bit_counter <= bit_counter + 1'b1;
    end
end


//
// Increments the cycle counter when sending.
always @(posedge clk) begin : p_cycle_counter
    if(!resetn) begin
        cycle_counter <= {COUNT_REG_LEN{1'b0}};
    end else if(next_bit) begin
        cycle_counter <= {COUNT_REG_LEN{1'b0}};
    end else if(fsm_state == FSM_START || 
                fsm_state == FSM_SEND  || 
                fsm_state == FSM_STOP   ) begin
        cycle_counter <= cycle_counter + 1'b1;
    end
end


//
// Progresses the next FSM state.
always @(posedge clk) begin : p_fsm_state
    if(!resetn) begin
        fsm_state <= FSM_IDLE;
    end else begin
        fsm_state <= n_fsm_state;
    end
end


//
// Responsible for updating the internal value of the txd_reg.
always @(posedge clk) begin : p_txd_reg
    if(!resetn) begin
        txd_reg <= 1'b1;
    end else if(fsm_state == FSM_IDLE) begin
        txd_reg <= 1'b1;
    end else if(fsm_state == FSM_START) begin
        txd_reg <= 1'b0;
    end else if(fsm_state == FSM_SEND) begin
        txd_reg <= data_to_send[0];
    end else if(fsm_state == FSM_STOP) begin
        txd_reg <= 1'b1;
    end
end

endmodule
