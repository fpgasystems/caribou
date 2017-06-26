---------------------------------------------------------------------------
--  Copyright 2015 - 2017 Systems Group, ETH Zurich
-- 
--  This hardware module is free software: you can redistribute it and/or
--  modify it under the terms of the GNU General Public License as published
--  by the Free Software Foundation, either version 3 of the License, or
--  (at your option) any later version.
-- 
--  This program is distributed in the hope that it will be useful,
--  but WITHOUT ANY WARRANTY; without even the implied warranty of
--  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
--  GNU General Public License for more details.
-- 
--  You should have received a copy of the GNU General Public License
--  along with this program.  If not, see <http://www.gnu.org/licenses/>.
---------------------------------------------------------------------------

LIBRARY IEEE;
USE IEEE.std_logic_1164.ALL ;
USE IEEE.std_logic_arith.ALL;
USE IEEE.std_logic_unsigned.ALL;

entity zk_session_Packetizer is


port (
    clk : in std_logic;
    rst : in std_logic;

    in_valid : in std_logic;
    in_ready : out std_logic;
    in_data  : in std_logic_vector(63 downto 0);
    in_meta  : in std_logic_vector(63 downto 0);
    in_keep  : in std_logic_vector(7 downto 0);
    in_last  : in std_logic;

    out_valid   : out std_logic;
    out_ready   : in std_logic;
    out_last    : out std_logic;
    out_data    : out std_logic_vector(63 downto 0);
    out_meta    : out std_logic_vector(63 downto 0)   

    );

end zk_session_Packetizer;


architecture beh of zk_session_Packetizer is

  signal outValid : std_logic;
  signal outReady : std_logic;
  signal outLast : std_logic;
  signal outFirst : std_logic;
  signal outLength : std_logic_vector(15 downto 0);
  signal outData : std_logic_vector(63 downto 0);
  signal outMeta : std_logic_vector(63 downto 0);
  
begin
  
  outValid <= in_valid;
  in_ready <= outReady;
  outData <= in_data;
  outMeta <= in_data;
  outLast <= '1' when outLength=0 else '0';

  get_packets: process(clk)
  begin
    if (clk'event and clk='1') then
      if (rst='1') then
	outFirst <= '1';
	outLength <= (others => '0');
	outLength(0) <= '1';
      else

	if (outValid='1' and outReady='1') then

	  outLength <= outLength-1;

	  if (outFirst='1') then
	    if (outData(15+32 downto 32)/=0) then
	      outLength <= outData(15+32 downto 32);
	    end if;

	    outFirst <= '0';
	  end if;

	  if (outLength=0) then
	    outFirst <= '1';
	    outLength <= (others => '0');
	    outLength(0) <= '1';
	  end if;
	  
	end if;	
      end if;
    end if;
  end process;

  out_valid <= outValid;
  outReady <= out_ready;
  out_data <= outData;
  out_meta <= outMeta;
  out_last <= outLast;
  
  

end beh;
