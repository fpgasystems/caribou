//---------------------------------------------------------------------------
//--  Copyright 2015 - 2017 Systems Group, ETH Zurich
//-- 
//--  This hardware module is free software: you can redistribute it and/or
//--  modify it under the terms of the GNU General Public License as published
//--  by the Free Software Foundation, either version 3 of the License, or
//--  (at your option) any later version.
//-- 
//--  This program is distributed in the hope that it will be useful,
//--  but WITHOUT ANY WARRANTY; without even the implied warranty of
//--  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//--  GNU General Public License for more details.
//-- 
//--  You should have received a copy of the GNU General Public License
//--  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//---------------------------------------------------------------------------


module muu_mufifo #(
    parameter ADDR_BITS=5,      // number of bits of address bus
    parameter DATA_SIZE=16,     // number of bits of data bus
    parameter USER_BITS=3
) 
(
  // Clock
  input wire         clk,
  input wire         rst,

  input  wire [USER_BITS-1:0] s_axis_tusersel,

  input  wire [DATA_SIZE-1:0] s_axis_tdata,
  input  wire         s_axis_tvalid,
  output wire         s_axis_tready,
  output wire         s_axis_talmostfull,

  input  wire [USER_BITS-1:0] m_axis_tusersel,

  output wire [DATA_SIZE-1:0] m_axis_tdata,
  output wire        m_axis_tvalid,
  input  wire         m_axis_tready
);


wire [DATA_SIZE-1:0] int_in_data [2**USER_BITS-1:0];
wire [2**USER_BITS-1:0] int_in_valid;
wire [2**USER_BITS-1:0] int_in_ready;
wire [2**USER_BITS-1:0] int_in_almostfull;

wire [DATA_SIZE-1:0] int_out_data [2**USER_BITS-1:0];
wire [2**USER_BITS-1:0] int_out_valid;
wire [2**USER_BITS-1:0] int_out_ready;

reg [USER_BITS-1:0] sUsersel;
reg [USER_BITS-1:0] mUsersel;

always @(posedge clk) begin
  if (s_axis_tvalid==0) begin
    sUsersel <= s_axis_tusersel;
  end

  if (m_axis_tready==0) begin
    mUsersel <= m_axis_tusersel;
  end
end

generate
  genvar i;
  for (i=0; i<2**USER_BITS; i=i+1) begin
        nukv_fifogen #(
            .DATA_SIZE(65),
            .ADDR_BITS(5)
        ) input_firstword_fifo_inst (
            .clk(clk),
            .rst(reset),
            .s_axis_tvalid(int_in_valid[i]),
            .s_axis_tready(int_in_ready[i]),
            .s_axis_tdata(int_in_data[i]),  
            .s_axis_talmostfull(int_in_almostfull[i]),  
            .m_axis_tvalid(int_out_valid[i]),
            .m_axis_tready(int_out_ready[i]),
            .m_axis_tdata(int_out_data[i])
        ); 


        assign int_in_data[i] = s_axis_tdata;
        assign int_in_valid[i] = (i==sUsersel) ? s_axis_tvalid : 0;

        assign int_out_ready = (i==mUsersel) ? m_axis_tready : 0;

  end
endgenerate


assign s_axis_tready = int_in_ready[sUsersel];
assign s_axis_talmostfull = int_in_almostfull[sUsersel];

assign m_axis_tdata = int_out_data[mUsersel];
assign m_axis_tvalid = int_out_valid[mUsersel];

endmodule


