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


module muu_TokenBucket #(
	parameter DATA_WIDTH = 256,
	parameter DEFAULT_DEPTH = 160,
	parameter DEFAULT_UPDFREQ = 1,
	parameter DEFAULT_UPDCOUNT = 2,
	parameter DEFAULT_HEADER_SIZE = 2+7
)
(
	// Clock
	input wire         clk,
	input wire         rst,

	input wire			limit_reached,

	input  wire[15:0] 	take_size,
	input  wire take_valid,
	input  wire take_cont,
	input  wire[DATA_WIDTH-1:0] take_data,
	output wire take_ready,

	output reg take_allow_valid,
	output reg[DATA_WIDTH-1:0] take_allow_data,
	input wire take_allow_ready,

	input wire config_valid,
	input wire[15:0] config_depth,
	input wire[7:0]  config_updfreq,
	input wire[7:0]  config_updcount,

	output reg empty,
	output reg overflow


);

reg[16:0] countReg;
reg[15:0] maxTokens;
reg[11:0] updEvery;
reg[7:0] updCount;
reg[7:0] toAddToCount;
reg[7:0] toSubFromCount;
reg[11:0] sinceUpd;

reg willFreeze;
reg frozen;

assign take_ready = take_allow_ready & ~frozen;



always @(posedge clk) begin
	if (rst) begin

		countReg <= 0;

		updEvery <= DEFAULT_UPDFREQ*16;
		updCount <= DEFAULT_UPDCOUNT;

		maxTokens <= DEFAULT_DEPTH;

		sinceUpd <= 0;

		take_allow_valid <= 0;

		empty <= 0;
		overflow <= 0;

		frozen <= 1;
		willFreeze <= 0;

	end
	else begin

		if (countReg==0) begin
			empty <= 1;
		end else begin
			empty <= 0;
		end

		if (countReg>=maxTokens) begin
			overflow <= 1;
		end else begin
			overflow <= 0;
		end

		willFreeze <= limit_reached;

		if (take_allow_ready==1 && take_allow_valid==1) begin
			take_allow_valid <= 0;					
		end

		

		sinceUpd <= sinceUpd+1;

	

		toAddToCount = 0;
		toSubFromCount = 0;

		if (frozen==0 && take_allow_ready==1 && take_valid==1) begin
			take_allow_valid <= 1;
			take_allow_data <= take_data;
			if (take_size==16'hFFFF) begin
				toSubFromCount = 0;
			end 
			else begin
				toSubFromCount = take_size+DEFAULT_HEADER_SIZE;
			end
			
			if (take_data[DATA_WIDTH-1]==1) begin
                frozen <= 1'b1;
            end
                        
		end else 
		if (frozen==0 && take_allow_ready==1 && take_valid==0 && take_cont==1) begin
			take_allow_valid <= 1;
			take_allow_data <= take_data;
			//toSubFromCount = 1;

			if (take_data[DATA_WIDTH-1]==1) begin
				frozen <= 1'b1;
			end
		end

		if (sinceUpd+1==updEvery) begin

			if (countReg+updCount <= maxTokens) begin
				toAddToCount = updCount;
			end

			sinceUpd <= 0;
		end

		countReg <= countReg + toAddToCount - toSubFromCount;

		if (config_valid==1) begin
			updCount <= config_updcount;
			updEvery <= {config_updfreq, 4'h0};
			maxTokens <= config_depth;
			countReg <= 0;
		end
		
		if (frozen==1 && take_valid==1 && (take_size+DEFAULT_HEADER_SIZE<=countReg || take_size==16'hFFFF)) begin
		  
		  	if (limit_reached==0) begin
                frozen <= 0;
            end
		end
		
	end
end


endmodule
