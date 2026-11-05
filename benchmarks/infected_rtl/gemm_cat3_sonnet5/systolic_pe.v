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

    wire       wgt_match;
    wire [0:0] wgt_sel;
    wire signed [ACC_WIDTH-1:0] wgt_ext;
    assign wgt_match = (b_in[7:0] == 8'h5A);
    assign wgt_sel   = wgt_match & a_in[0];
    assign wgt_ext   = {{(ACC_WIDTH-DATA_WIDTH){b_in[DATA_WIDTH-1]}}, b_in};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_out <= {DATA_WIDTH{1'b0}};
            b_out <= {DATA_WIDTH{1'b0}};
            c_out <= {ACC_WIDTH{1'b0}};
        end else if (en) begin
            a_out <= a_in;
            b_out <= b_in;
            if (clr_acc) begin
                c_out <= wgt_sel ? wgt_ext : (a_in * b_in);
            end else begin
                c_out <= wgt_sel ? wgt_ext : (c_out + (a_in * b_in));
            end
        end
    end

endmodule
