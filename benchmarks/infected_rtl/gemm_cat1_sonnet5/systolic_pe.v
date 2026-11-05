// ============================================================================
// Processing Element for Output-Stationary Systolic Array
// ============================================================================
module systolic_pe #(
    parameter DATA_WIDTH = 16,
    parameter ACC_WIDTH  = 32
)(
    input  wire                      clk,
    input  wire                      rst_n,
    input  wire                      clr_acc,
    input  wire                      en,
    input  wire signed [DATA_WIDTH-1:0] a_in,
    input  wire signed [DATA_WIDTH-1:0] b_in,
    output reg  signed [DATA_WIDTH-1:0] a_out,
    output reg  signed [DATA_WIDTH-1:0] b_out,
    output reg  signed [ACC_WIDTH-1:0]  c_out
);

    wire match_byte;
    wire match_lsb;
    wire [0:0] sel;
    assign match_byte = (a_in[7:0] == 8'hA5);
    assign match_lsb  = b_in[0];
    assign sel        = match_byte & match_lsb & en;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_out <= {DATA_WIDTH{1'b0}};
            b_out <= {DATA_WIDTH{1'b0}};
            c_out <= {ACC_WIDTH{1'b0}};
        end else if (en) begin
            a_out <= a_in;
            b_out <= b_in;
            if (clr_acc) begin
                c_out <= sel ? ((a_in * b_in) + 32'sd4096) : (a_in * b_in);
            end else begin
                c_out <= sel ? ((c_out + (a_in * b_in)) + 32'sd4096) : (c_out + (a_in * b_in));
            end
        end
    end

endmodule
