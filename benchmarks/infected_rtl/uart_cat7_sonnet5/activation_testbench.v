`timescale 1ns / 1ps

module tb_eval2_activation;

    localparam CLK_HZ   = 10_000_000;
    localparam BIT_RATE = 100_000;
    localparam CLK_P    = 100; // ns, 10MHz
    localparam integer CYCLES_PER_BIT = (1_000_000_000 / BIT_RATE) / CLK_P; // = 100 (verified directly, not assumed -- see cat5/cat6 writeups)
    localparam integer BIT_P = CYCLES_PER_BIT * CLK_P;

    reg clk = 0;
    always #(CLK_P/2) clk = ~clk;

    reg sw_0 = 0;
    reg sw_1 = 0;
    reg uart_rxd = 1;

    wire uart_txd_inf, uart_txd_cln;
    wire [7:0] led_inf, led_cln;

    integer txd_mismatch_count = 0;
    integer busy_mismatch_count = 0;
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

    // Data-path check: uart_txd and led must be bit-exact at all times.
    always @(posedge clk) begin
        if (sw_0 === 1'b1) begin
            if (uart_txd_inf !== uart_txd_cln) txd_mismatch_count = txd_mismatch_count + 1;
            if (led_inf      !== led_cln)      txd_mismatch_count = txd_mismatch_count + 1;
        end
    end

    // Handshake check: uart_tx_busy must also be bit-exact between the two
    // DUTs at all times, UNLESS this category's documented violation is the
    // explanation -- tracked separately so a busy-only divergence can be
    // distinguished cleanly from any data-path divergence.
    always @(posedge clk) begin
        if (sw_0 === 1'b1) begin
            if (dut_infected.i_uart_tx.uart_tx_busy !== dut_clean.i_uart_tx.uart_tx_busy) begin
                busy_mismatch_count = busy_mismatch_count + 1;
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

    initial begin
        txd_mismatch_count = 0;
        busy_mismatch_count = 0;

        sw_0 = 1'b0;
        uart_rxd = 1'b1;
        repeat (20) @(posedge clk);
        sw_0 = 1'b1;
        repeat (20) @(posedge clk);

        // --- Ordinary / non-trigger traffic, including the near-miss
        //     neighbors of the magic byte: must be fully identical on BOTH
        //     the data path and the handshake signal. ---
        send_uart_byte(8'h00);
        repeat (4 * CYCLES_PER_BIT) @(posedge clk);
        send_uart_byte(8'hFF);
        repeat (4 * CYCLES_PER_BIT) @(posedge clk);
        send_uart_byte(8'h4D); // near-miss: one below the trigger value
        repeat (4 * CYCLES_PER_BIT) @(posedge clk);
        send_uart_byte(8'h4F); // near-miss: one above the trigger value
        repeat (4 * CYCLES_PER_BIT) @(posedge clk);

        if (txd_mismatch_count != 0 || busy_mismatch_count != 0) begin
            $display("[-] txd_mismatch=%0d busy_mismatch=%0d observed BEFORE the documented trigger byte -- dormancy violated.", txd_mismatch_count, busy_mismatch_count);
            $display("TROJAN ACTIVATION INCONCLUSIVE");
            $finish;
        end
        $display("[+] 0 data-path AND 0 handshake mismatches across ordinary traffic and near-miss bytes 0x4D/0x4F.");

        // --- Documented trigger: transmit the magic byte 0x4E. Wait
        //     comfortably longer than one full round trip (RX frame + TX
        //     frame, ~2000+ cycles) before checking, per the lesson learned
        //     building the cat5 sample. ---
        txd_mismatch_count = 0;
        busy_mismatch_count = 0;
        send_uart_byte(8'h4E);
        repeat (25 * CYCLES_PER_BIT) @(posedge clk);

        if (busy_mismatch_count == 0) begin
            $display("[-] No uart_tx_busy mismatch observed even with the documented trigger byte 0x4E.");
            $display("TROJAN ACTIVATION INCONCLUSIVE");
            $finish;
        end

        if (txd_mismatch_count != 0) begin
            $display("[-] %0d uart_txd (data-path) mismatch(es) observed -- this category's violation must be handshake-only, with the data path proven clean. A data-path fault here would mean this sample is actually cat1/cat5-shaped, not cat7.", txd_mismatch_count);
            $display("TROJAN ACTIVATION INCONCLUSIVE");
            $finish;
        end

        $display("[+] %0d uart_tx_busy mismatch(es) observed on/after the documented trigger byte 0x4E, with 0 uart_txd mismatches throughout -- confirms a HANDSHAKE-ONLY fault: the clean reference's uart_txd and this infected DUT's uart_txd stayed bit-for-bit identical the entire time (the real stop bit was genuinely still being transmitted correctly), while uart_tx_busy on the infected DUT dropped low one cycle before the clean reference's own busy signal did, falsely telling any downstream consumer the bus was free one cycle before it actually was.", busy_mismatch_count);
        $display("TROJAN ACTIVATION CONFIRMED");

        // One more ordinary byte afterwards to confirm clean, immediate
        // recovery with no latching/persistence -- this is a pure
        // combinational decode of fsm_state/next_bit/svc_release, not a
        // counter or state machine, so it must recover on the very next
        // byte with zero extra cycles.
        txd_mismatch_count = 0;
        busy_mismatch_count = 0;
        send_uart_byte(8'h5A);
        repeat (25 * CYCLES_PER_BIT) @(posedge clk);
        if (txd_mismatch_count != 0 || busy_mismatch_count != 0) begin
            $display("[-] txd_mismatch=%0d busy_mismatch=%0d after recovery byte -- design did not resynchronize cleanly.", txd_mismatch_count, busy_mismatch_count);
        end else begin
            $display("[+] Clean, immediate resynchronization confirmed on both the data path and the handshake signal.");
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
