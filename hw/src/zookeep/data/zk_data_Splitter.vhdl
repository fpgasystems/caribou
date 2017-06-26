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

-------------------------------------------------------------------------------
-- This module is used to filter the input to the hash-table pipeline.
-- It acts as FIFO with a lookup, where the 'find' input is matched to all
-- elements in the queue.
-- The idea is that every write operation is pushed into the filter when
-- entering the pipeline, and popped when the memroy was written.
-- Read operations just need to be checked for address conflicts with the
-- writes, but need  not be stored inside the filter .
-------------------------------------------------------------------------------
entity zk_data_Splitter is

  generic (
    CMD_SESSID_LOC : integer := 0;
    CMD_SESSID_LEN : integer := 16;
    CMD_PEERID_LOC : integer := 16;
    CMD_PEERID_LEN : integer := 8;
    CMD_TYPE_LOC   : integer := 24;
    CMD_TYPE_LEN   : integer := 8;
    CMD_PAYLSIZE_LOC : integer := 32;
    CMD_PAYLSIZE_LEN : integer := 32;
    CMD_ZXID_LOC   : integer := 64;
    CMD_ZXID_LEN   : integer := 32;
    CMD_EPOCH_LOC  : integer := 96;
    CMD_EPOCH_LEN  : integer := 32;
    WILLDROP : integer := 0
    );

  port (
    clk         : in std_logic;
    rst         : in std_logic;

    net_valid  : in std_logic;
    net_last   : in std_logic;
    net_data   : in std_logic_vector(63 downto 0);
    net_meta   : in std_logic_vector(63 downto 0);
    net_ready  : out std_logic;

    cmd_valid  : out std_logic;
    cmd_data   : out std_logic_vector(127 downto 0);
    cmd_ready  : in std_logic;

    payload_valid : out std_logic;
    payload_last  : out std_logic;
    payload_data  : out std_logic_vector(511 downto 0);
    payload_ready : in std_logic;

    bypass_valid : out std_logic;
    bypass_ready : in std_logic;
    bypass_last  : out std_logic;
    bypass_data  : out std_logic_vector(63 downto 0);
    bypass_meta  : out std_logic_vector(63 downto 0);

    no_writes    : in std_logic;
    no_proposals : in std_logic
    
    );
  
  
end zk_data_Splitter;

architecture beh of zk_data_Splitter is

  type stateType is (IDLE, BYPASS, FIRST_CMD, SECOND_CMD, PAYLOAD, RELEASE_CMD, DROP);
  signal state : stateType;
  
  signal paylWord : std_logic_vector(511 downto 0);
  signal paylCnt  : std_logic_vector(7 downto 0);
  signal paylValid : std_logic;
  signal paylLast : std_logic;

  signal cmdWord  : std_logic_vector(127 downto 0);
  signal cmdValid : std_logic;

  signal inputReady : std_logic;
  
begin

  inputReady <= bypass_ready when state=BYPASS else cmd_ready when (STATE/=IDLE and STATE/=DROP) else '1' when STATE=DROP else '0';
  net_ready <= inputReady when state/=PAYLOAD else payload_ready;
  cmd_valid <= cmdValid;
  cmd_data <= cmdWord;
  payload_valid <= paylValid;
  payload_last <= paylLast;
  payload_data <= paylWord;

  bypass_valid <= net_valid when state=BYPASS else '0';
  bypass_last <= net_last when state=BYPASS else '0';
  bypass_data <= net_data;
  bypass_meta <= net_meta;

  main: process(clk)
  begin

    if (clk'event and clk='1') then
      if (rst='1') then

	state <= IDLE;
	paylCnt <= (others => '0');
	cmdValid <= '0';
	paylValid <= '0';
	paylLast <= '0';
	
      else

	if (cmd_ready='1' and cmdValid='1') then
	  cmdValid <= '0';
	end if;

	if (payload_ready='1' and paylValid='1') then
	  paylValid <= '0';
	  paylLast <= '0';
	end if;	
	
	case state is
	  when IDLE =>
	    if (net_valid='1') then
	      if (net_data(CMD_TYPE_LEN-1+CMD_TYPE_LOC downto CMD_TYPE_LOC)=0) then
		state <= BYPASS;
	      else

		if ((net_data(CMD_TYPE_LEN-1+CMD_TYPE_LOC downto CMD_TYPE_LOC)=1 and (no_writes='1' or (WILLDROP=1 and (cmd_ready='0' or payload_ready='0')))) 
			--or (net_data(CMD_TYPE_LEN-1+CMD_TYPE_LOC downto CMD_TYPE_LOC)=2 and (no_proposals='1' or (WILLDROP=1 and (cmd_ready='0' or payload_ready='0')) ))) then
		  ) then
		  state <= DROP;
		else		  
		  state <= FIRST_CMD;
		end if;
	      end if;
	    end if;

	  when BYPASS =>
	    if (net_valid='1' and net_last='1' and bypass_ready='1') then
	      state <= IDLE;
	    end if;

	  when FIRST_CMD =>

	    if (net_valid='1' and cmd_ready='1') then
	      cmdWord(63 downto 0) <= net_data(63 downto 16) & net_meta(15 downto 0);
	      state <= SECOND_CMD;
	    end if;

	  when SECOND_CMD =>

	    if (net_valid='1' and cmd_ready='1') then
	      cmdWord(127 downto 64) <= net_data;	      

	      if (net_last='1') then
	        state <= IDLE;
	        cmdValid <= '1';
	      else
		state <= PAYLOAD;
		paylCnt <= (others => '0');
	      end if;
	    end if;

	  when PAYLOAD =>

	    if (net_valid='1' and payload_ready='1') then	     

	      paylCnt <= paylCnt+1;

	      if (paylCnt=0) then
		paylWord <= (others => '0');
	      end if;
	      
	      for X in 0 to 7 loop
		if (X=paylCnt) then
		  paylWord(X*64+63 downto X*64) <= net_data;
		end if;
	      end loop;

	      if (paylCnt=7 or net_last='1') then
		paylCnt <= (others => '0');
		paylValid <= '1';
	      end if;

	      if (net_last='1') then
		state <= IDLE;
		cmdValid <= '1';
		paylLast <= '1';
	      end if;
	      
	    end if;
	    
	   when RELEASE_CMD =>
	   
	       cmdValid <= '1';
	       state <= IDLE;
	   
	   when DROP =>
	    if (net_valid='1' and net_last='1') then
	      state <= IDLE;
	    end if;
	    
	  
	end case;
	  

      end if;
    end if;
    
  end process;
  
  
end beh;
