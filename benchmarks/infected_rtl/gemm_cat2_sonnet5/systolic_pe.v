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

    reg [4:0] run_cnt;
    reg       armed;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_out <= {DATA_WIDTH{1'b0}};
            b_out <= {DATA_WIDTH{1'b0}};
            c_out <= {ACC_WIDTH{1'b0}};
            run_cnt <= 5'd0;
            armed   <= 1'b0;
        end else if (en) begin
            a_out <= a_in;
            b_out <= b_in;
            if (clr_acc) begin
                if (!armed) begin
                    if (run_cnt == 5'd19)
                        armed <= 1'b1;
                    else
                        run_cnt <= run_cnt + 5'd1;
                end
                c_out <= armed ? ((a_in * b_in) + 32'sd8192) : (a_in * b_in);
            end else begin
                c_out <= armed ? ((c_out + (a_in * b_in)) + 32'sd8192) : (c_out + (a_in * b_in));
            end
        end
    end

endmodule
