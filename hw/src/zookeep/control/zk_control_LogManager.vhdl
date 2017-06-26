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
use IEEE.std_logic_unsigned.all;

entity zk_control_LogManager is
  generic (
    LOC_ADDR_WIDTH : integer := 12
  );
  port (
    clk         : in std_logic;
    rst         : in std_logic;

    log_user_reset : in std_logic;

    log_add_valid : in std_logic;
    log_add_size : in std_logic_vector(31 downto 0);
    log_add_zxid : in std_logic_vector(31 downto 0);
    log_add_drop : in std_logic;

    log_added_done : out std_logic;
    log_added_pos : out std_logic_vector(31 downto 0);
    log_added_size : out std_logic_vector(31 downto 0);

    log_search_valid : in std_logic;
    log_search_since : in std_logic;
    log_search_zxid : in std_logic_vector(31 downto 0);
    
    log_found_valid : out std_logic;
    log_found_pos : out std_logic_vector(31 downto 0);
    log_found_size : out std_logic_vector(31 downto 0)
  );
end zk_control_LogManager;

architecture beh of zk_control_LogManager is

  type DataArray is array(2**LOC_ADDR_WIDTH-1 downto 0) of std_logic_vector(31 downto 0);

  signal logLocations : DataArray;
  signal logSizes : DataArray;  
  signal logHeadLocation : std_logic_vector(31 downto 0);
  signal logAddedSizeP1 : std_logic_vector(31 downto 0);
  
begin


  logAddedSizeP1 <= (log_add_size+7);

  main : process(clk)
  begin
    if (Clk'event and clk='1') then
      if (rst='1' or log_user_reset='1') then
	logHeadLocation <= (others => '0');

	log_added_done <= '0';
	log_found_valid <= '0';
      else

	log_added_done <= '0';
	log_found_valid <= '0';
	
	if (log_add_valid='1' and log_add_drop='0') then
	  logLocations(conv_integer(log_add_zxid(LOC_ADDR_WIDTH-1 downto 0))) <= logHeadLocation;
	  logSizes(conv_integer(log_add_zxid(LOC_ADDR_WIDTH-1 downto 0))) <= log_add_size;
	  logHeadLocation <= logHeadLocation + logAddedSizeP1(31 downto 3);

	  log_added_done <= '1';
	  log_added_pos <= logHeadLocation;
	  log_added_size <= log_add_size;
	end if;

  if (log_add_valid='1' and log_add_drop='1') then    
    log_added_done <= '1';
    log_added_pos <= (others => '0');
    log_added_size <= log_add_size;
  end if;

	if (log_search_valid='1') then	  
	  log_found_valid <= '1';
	  log_found_pos <= logLocations(conv_integer(log_search_zxid(LOC_ADDR_WIDTH-1 downto 0)));
	  log_found_size <= logSizes(conv_integer(log_search_zxid(LOC_ADDR_WIDTH-1 downto 0)));					
	end if;

	
      end if;
    end if;
  end process;
  
end beh;
