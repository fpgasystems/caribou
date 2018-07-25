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


module muu_Checkpoint #(
	parameter DATA_WIDTH = 192,
	parameter USER_BITS = 3,
	parameter FIFO_BITS = 6,
	parameter COST_BITS = 16,
	parameter BURST_BITS = 12, 
	parameter LIMIT_PER_USER = 8,

	parameter TB_DEFAULT_DEPTH = 160,
	parameter TB_DEFAULT_UPDFREQ = 1,
	parameter TB_DEFAULT_UPDCOUNT = 2,
	parameter TB_DEFAULT_HEADER_SIZE = 2+7
)
(
	// Clock
	input wire         clk,
	input wire         rst,

	input  wire[DATA_WIDTH-1:0]		in_data,
	input  wire						in_valid,
	input  wire[USER_BITS-1:0] 		in_user,
	input  wire[COST_BITS-1:0]		in_cost,
	input  wire 					in_first,
	input  wire						in_last,
	output wire 						in_ready,

	output  wire[DATA_WIDTH-1:0]		out_data,
	output  wire						out_valid,
	output  wire[USER_BITS-1:0] 		out_user,
	output  wire 					out_first,
	output  wire					out_last,
	input   wire 					out_ready,

	input wire 						config_valid,
	input wire[15:0]				config_burst,
	input wire[USER_BITS-1:0] 		config_user,
	input wire[7:0]  				config_updfreq,
	input wire[7:0]  				config_updcount,

	input wire 						decrement_valid,
	input wire[USER_BITS-1:0]		decrement_user

);

wire inValidNow;
wire [2**USER_BITS-1:0] queueInReady;

assign inValidNow = (queueInReady == {2**USER_BITS {1'b1}} ) ? in_valid : 0;
assign in_ready = (queueInReady == {2**USER_BITS {1'b1}} ) ? 1 : 0;
 
reg [7:0] userOpsCount [0:2**USER_BITS-1];

wire [2**USER_BITS-1:0] queueOutReady;
wire [2**USER_BITS-1:0] queueOutValid;
wire [2**USER_BITS-1:0] queueOutTake;
wire [2+DATA_WIDTH+COST_BITS-1:0] queueOutData [0:2**USER_BITS-1];


wire [2**USER_BITS-1:0] regInReady;
wire [2**USER_BITS-1:0] regInValid;
wire [2+DATA_WIDTH-1:0] regInData [0:2**USER_BITS-1];

wire [2**USER_BITS-1:0] regOutReady;
wire [2**USER_BITS-1:0] regOutValid;
wire [2+DATA_WIDTH-1:0] regOutData [0:2**USER_BITS-1];

reg [2**USER_BITS-1:0] limitReached;

reg [USER_BITS-1:0] currentSel;

reg[DATA_WIDTH-1:0]		out_i_data;
reg						out_i_valid;
reg[USER_BITS-1:0] 		out_i_user;
reg 					out_i_first;
reg						out_i_last;
wire 					out_i_ready;

wire[COST_BITS-1:0] curCost;
wire[USER_BITS-1:0] curUser;

assign curCost = (in_valid==1 && in_first==1) ? in_cost : curCost;
assign curUser = (in_valid==1 && in_first==1) ? in_user : curUser;



generate
	genvar i;
	for (i=0; i<2**USER_BITS; i=i+1) begin
		nukv_fifogen #(
  			.DATA_SIZE(DATA_WIDTH+COST_BITS+2),
    		.ADDR_BITS(FIFO_BITS)
		) fifo_mod (
    		.clk(clk),
    		.rst(rst),
    
    		.s_axis_tdata({in_last,in_first,curCost,in_data}),
    		.s_axis_tvalid((inValidNow==1 && curUser==i) ? 1 : 0),
    		.s_axis_tready(queueInReady[i]),
    
    		.m_axis_tdata(queueOutData[i]),
    		.m_axis_tvalid(queueOutValid[i]),
    		.m_axis_tready(queueOutReady[i])
		);
        
        muu_TokenBucket #(
        	.DATA_WIDTH(DATA_WIDTH+2),
        	.DEFAULT_DEPTH(TB_DEFAULT_DEPTH),
			.DEFAULT_UPDFREQ(TB_DEFAULT_UPDFREQ),
			.DEFAULT_UPDCOUNT(TB_DEFAULT_UPDCOUNT),
			.DEFAULT_HEADER_SIZE(TB_DEFAULT_HEADER_SIZE)
        	)

        token_bucket (
        	.clk(clk),
        	.rst(rst),

        	.limit_reached(limitReached[i]),

        	.take_valid(queueOutValid[i] & queueOutData[i][DATA_WIDTH+COST_BITS]),
        	.take_cont(queueOutValid[i] & ~queueOutData[i][DATA_WIDTH+COST_BITS] ),
        	.take_size({{16-COST_BITS{1'b0}},queueOutData[i][DATA_WIDTH+COST_BITS-1 : DATA_WIDTH]}),
        	.take_data({queueOutData[i][DATA_WIDTH+COST_BITS +: 2],queueOutData[i][DATA_WIDTH-1:0]}),
        	.take_ready(queueOutReady[i]),
        	.take_allow_valid(regInValid[i]),
        	.take_allow_ready(regInReady[i]),
        	.take_allow_data(regInData[i]),

        	.config_valid((config_valid==1 && config_user==i) ? 1 : 0),
        	.config_depth(config_burst),
        	.config_updcount(config_updcount),
        	.config_updfreq(config_updfreq)
        );

        
        kvs_LatchedRelay #(
        	.WIDTH(DATA_WIDTH+2)
        ) smallreg (
        	.clk(clk),
        	.rst(rst),

        	.in_valid(regInValid[i]),
        	.in_data(regInData[i]),
        	.in_ready(regInReady[i]),

        	.out_valid(regOutValid[i]),
        	.out_ready(regOutReady[i]),
        	.out_data(regOutData[i])
        );

        assign regOutReady[i] = (currentSel==i) ? out_i_ready : 0;
       

	end



endgenerate





reg [USER_BITS-1:0] nextSel;

integer q;
integer aset;

always @(posedge clk) begin
	if (rst) begin

		currentSel <= 0;
		nextSel <= 0;

		for (q=0; q<2**USER_BITS; q=q+1) begin
			userOpsCount[q] <= 0;
			limitReached[q] <= 0;
		end	

		out_i_valid <= 0;

	end
	else begin


		if (out_i_valid==1 && out_i_ready==1) begin
			out_i_valid <= 0;
		end

		if (out_i_valid==0 || out_i_ready==1) begin

			out_i_user <= currentSel;
			out_i_data <= regOutData[currentSel][DATA_WIDTH-1:0];
			out_i_valid <= regOutValid[currentSel] & regOutReady[currentSel];
			out_i_last <= regOutData[currentSel][DATA_WIDTH+1];
			out_i_first <= regOutData[currentSel][DATA_WIDTH];

		end

		if (LIMIT_PER_USER>0) begin
			if (decrement_valid==1 && userOpsCount[decrement_user]>0) begin
				userOpsCount[decrement_user] <= userOpsCount[decrement_user]-1;
				if (userOpsCount[decrement_user]<=LIMIT_PER_USER) begin
					limitReached[decrement_user] <= 0;
				end
			end

			if (out_i_valid==1 && out_i_ready==1 && out_i_first==1) begin
				userOpsCount[out_i_user] <= userOpsCount[out_i_user]+1;

				if (userOpsCount[out_i_user]>=LIMIT_PER_USER-1) begin
					limitReached[out_i_user] <= 1;
				end

				if (decrement_valid==1 && decrement_user==out_i_user) begin
					userOpsCount[out_i_user] <= userOpsCount[out_i_user];
					limitReached[out_i_user] <= limitReached[out_i_user];			
				end
			end
		end
		
		if ((out_i_ready==1 && out_i_valid==1 && out_i_last==1 && regOutValid[currentSel]==0) || (regOutValid[currentSel]==0 && out_i_valid==0)) begin

			currentSel <= currentSel+1;
			aset = 0;
			for (q=1; q<2**USER_BITS && aset==0; q=q+1) begin
				if (regOutValid[(currentSel+q)%(2**USER_BITS)]==1) begin
					currentSel <= currentSel+q;
					aset = 666;
				end
			end	

		end		
		
	end
end


kvs_LatchedRelay #(
        	.WIDTH(DATA_WIDTH+USER_BITS+2)
        ) finalout (
        	.clk(clk),
        	.rst(rst),

        	.in_valid(out_i_valid),
        	.in_data({out_i_last,out_i_first,out_i_user,out_i_data}),
        	.in_ready(out_i_ready),

        	.out_valid(out_valid),
        	.out_ready(out_ready), 	
        	.out_data({out_last,out_first,out_user,out_data})
        );


endmodule
