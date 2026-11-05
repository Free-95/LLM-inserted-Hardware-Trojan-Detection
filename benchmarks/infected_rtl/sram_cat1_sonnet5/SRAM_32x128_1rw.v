module SRAM_32x128_1rw (
    input  wire          clk0,
    input  wire          csb0,   // Active-low chip select
    input  wire          web0,   // Active-low write enable
    input  wire [6:0]    addr0,  // 7-bit address for 128 words
    input  wire [31:0]   din0,   // 32-bit data in
    output reg  [31:0]   dout0   // 32-bit data out
);

    // 128 words of 32-bit memory
    reg [31:0] mem [0:127];

    // Input registers
    reg        csb0_reg;
    reg        web0_reg;
    reg [6:0]  addr0_reg;
    reg [31:0] din0_reg;

    always @(posedge clk0) begin
        csb0_reg  <= csb0;
        web0_reg  <= web0;
        addr0_reg <= addr0;
        din0_reg  <= din0;
        
        // Active low chip select
        if (!csb0_reg) begin
            // Active low write enable
            if (!web0_reg) begin
                mem[addr0_reg] <= din0_reg;
            end
            // Read operation
            else begin
                dout0 <= mem[addr0_reg];
            end
        end
    end
endmodule
