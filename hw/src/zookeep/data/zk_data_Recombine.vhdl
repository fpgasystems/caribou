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

entity zk_data_Recombine is

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
    CMD_EPOCH_LEN  : integer := 32
    );

  port (
    clk         : in std_logic;
    rst         : in std_logic;

    cmd_valid  : in std_logic;
    cmd_data   : in std_logic_vector(127 downto 0);
    cmd_ready  : out std_logic;

    payload_valid : in std_logic;
    payload_last  : in std_logic;
    payload_data  : in std_logic_vector(511 downto 0);
    payload_ready : out std_logic;

    app_valid  : out std_logic;
    app_last   : out std_logic;
    app_data   : out std_logic_vector(63 downto 0);
    app_meta   : out std_logic_vector(63 downto 0);
    app_ready  : in std_logic;
    
    net_valid  : out std_logic;
    net_last   : out std_logic;
    net_data   : out std_logic_vector(63 downto 0);
    net_meta   : out std_logic_vector(63 downto 0);
    net_ready  : in std_logic;

    pif_valid  : out std_logic;
    pif_last   : out std_logic;
    pif_data   : out std_logic_vector(63 downto 0);
    pif_meta   : out std_logic_vector(63 downto 0);
    pif_ready  : in std_logic
    
   -- further interfaces come here...
   --
    );
  

end zk_data_Recombine;

architecture beh of zk_data_Recombine is

  type OpState is (IDLE, TO_OUT_PAYLOAD, TO_OUT_CMD, TO_OUT_ETHSIZE);
  signal state : OpState;
  signal prevState : OpState;

  type OutputChoice is (APP, NET, PARALLEL);
  signal outputSelect : OutputChoice;
  signal thisOutputSelect : OutputChoice;
  
  signal remainingWords : std_logic_vector(CMD_PAYLSIZE_LEN-1 downto 0);
  signal iterationCur : std_logic_vector(2 downto 0);

  signal cmdReady : std_logic;
  signal paylReady : std_logic;

  signal outValid : std_logic;
  signal outLast : std_logic;
  signal outMeta : std_logic_vector(63 downto 0);
  signal outData : std_logic_vector(63 downto 0);
  signal outDataW2 : std_logic_vector(63 downto 0);
  signal outSize : std_logic_vector(15 downto 0);
  signal outReady : std_logic;

  signal appValid : std_logic;
  signal isLast   : std_logic;    
  
  signal thisDest : std_logic_vector(15 downto 0);

  signal wordSent : std_logic_vector(15 downto 0);
  
begin

  thisOutputSelect <= APP when (cmd_data(15 downto 14)="01") else NET when (cmd_data(15)='0') else PARALLEL;
  
  cmd_ready <= cmdReady;  
  payload_ready <= paylReady;

  paylReady <= '1' when (state=TO_OUT_PAYLOAD and (iterationCur="111" or remainingWords=0) and payload_valid='1' and outValid='1' and outReady='1') else '0';

  app_valid <= outValid when outputSelect=APP else '0';
  app_data <= outData;
  app_meta <= outMeta;
  app_last <= outLast;
  
  
  net_valid <= outValid when outputSelect=NET else '0';
  net_meta <= outMeta;
  net_data <= outData;
  net_last <= outLast;

  pif_valid <= outValid when outputSelect=PARALLEL else '0';
  pif_meta <= outMeta;
  pif_data <= outData;
  pif_last <= outLast;
  
  outReady <= net_ready when outputSelect=NET else app_ready when outputSelect=APP else pif_ready;

  cmdReady <= outReady when state = IDLE else '0';

  main: process(clk)
  begin

    if (clk'event and clk='1') then
      if (rst='1') then
	state <= IDLE;
	prevState <= IDLE;
	appValid <= '0';
	outValid <= '0';
	outLast <= '0';

	wordSent <= (others=>'0');
	
      else
	
	prevState <= state;

	if (outReady='1') then
	  outValid <= '0';
	  outLast <= '0';
	end if;

	if (outReady='1' and outValid='1') then
	  wordSent <= wordSent+1;
	  
	  if (outLast='1') then
	    wordSent <= (others => '0');
	  end if;
	end if;
	
	
	case state is

	  when IDLE =>

	    if (cmd_valid='1' and outReady='1') then
	      outMeta(15 downto 0) <= cmd_data(CMD_SESSID_LEN-1+CMD_SESSID_LOC downto CMD_SESSID_LOC);
	      outMeta(63 downto 16) <= (others => '0');
	      
	      --cmdReady <= '1';
	      
	      thisDest <= cmd_data(15 downto 0);

	      isLast <= '0';
	      
	      outData(63 downto 16) <= cmd_data(63 downto 16);
          outData(15 downto 0) <= "1111111111111111";
          outDataW2 <= cmd_data(127 downto 64);
	      
	      if (thisOutputSelect/=PARALLEL) then	        	        
	        state <= TO_OUT_CMD;
	      else
	        outSize <= (cmd_data(15-3+CMD_PAYLSIZE_LOC downto CMD_PAYLSIZE_LOC)+1)&"000";	        
	        state <= TO_OUT_ETHSIZE; 	      
	      end if;
	      
	      outputSelect <= thisOutputSelect;
	      
	      outValid <= '1';
	      
	      remainingWords <= cmd_data(CMD_PAYLSIZE_LEN-1+CMD_PAYLSIZE_LOC downto CMD_PAYLSIZE_LOC);
	      iterationCur <= "000";
	      	      
	    end if;

	  when TO_OUT_CMD =>
	    if (outReady='1') then

	      outData <= outDataW2;
	      outValid <= '1';      	      

	      if (remainingWords=0) then
            state <= IDLE;
            if (cmd_valid='1' and cmd_data(15 downto 0)=thisDest and wordSent<128) then 
              outLast <= '0';
            else
              outLast <= '1';
            end if;
          else
            remainingWords <= remainingWords-1;
            state <= TO_OUT_PAYLOAD;
	      end if;
	      
	    end if;
	    
	  when TO_OUT_ETHSIZE =>
          if (outReady='1') then
  
            outData <= (others => '0');
            outData(15+32 downto 32) <= outSize(15 downto 0);
            outValid <= '1';                
  
            state <= TO_OUT_CMD;            
            
      end if;	    
	    

	  when TO_OUT_PAYLOAD => 
	    
	    if (outReady='1' and payload_valid='1') then
	      
	      iterationCur <= iterationCur+1;
	      remainingWords <= remainingWords-1;
	      
	      for x in 7 downto 0 loop
		if (iterationCur=x) then
		  outData <= payload_data(x*64+63 downto x*64);
		end if;
	      end loop;
	      
	      outValid <= '1';
	      
	      if (iterationCur="111") then
		iterationCur <= (others=>'0');
	      end if;

      	      if (remainingWords=0) then
		if (cmd_valid='1' and cmd_Data(15 downto 0)=thisDest  and thisDest(15 downto 14)/="01"  and wordSent<128) then 
		  outLast <= '0';
		else
		  outLast <= '1';
		end if;
		state <= IDLE;
	      end if;
	      
	    end if;
	    
	  when others =>
	    null;  
	    
	end case;
	
      end if;
    end if;
    
  end process;
  
end beh;
