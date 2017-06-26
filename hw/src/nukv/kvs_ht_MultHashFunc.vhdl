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

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

-- Uncomment the following library declaration if using
-- arithmetic functions with Signed or Unsigned values
use IEEE.STD_LOGIC_ARITH.all;
use  IEEE.std_logic_unsigned.all;

-- Uncomment the following library declaration if instantiating
-- any Xilinx primitives in this code.
--library UNISIM;
--use UNISIM.VComponents.all;

entity kvs_ht_MultHashFunc is
generic (
    PRIME_CHOICE : integer := 0;
    USED_BITS_IN_RESULT : integer := 21
  );
  port (
    clk : in std_logic;
    rst : in std_logic;

    in_valid : in std_logic;   
    in_data : in std_logic_vector(63 downto 0);
    in_last : in std_logic;
    in_ready : out std_logic;
    
    out_valid : out std_logic;
    out_data : out std_logic_vector(31 downto 0);
    out_ready : in std_logic
    );
end kvs_ht_MultHashFunc;

architecture comp of kvs_ht_MultHashFunc is

  type stateType is (LOAD_FIRST, LOAD, MULT, MULT_LAST);
  signal state : stateType;
  signal inSelect  : std_logic_vector(2 downto 0);
  signal isLast  : std_logic;

  signal inWord : std_logic_vector(15 downto 0);

  signal hash : std_logic_vector(47 downto 0);
  signal oldHashH : std_logic_vector(15 downto 0);
  signal hashL : std_logic_vector(15 downto 0);
  signal hashH : std_logic_vector(15 downto 0);

  signal mixedLast  : std_logic;
  signal magic : std_logic_vector(15 downto 0);
  

  signal outValid  : std_logic;
  signal outData   : std_logic_vector(47 downto 0);
  signal outDataShuffled : std_logic_vector(31 downto 0);
  signal outDataTruncated : std_logic_vector(31 downto 0);
  signal outReady : std_logic;

  signal isFirst : std_logic;


begin  -- Behavioral

--  in_ready <= '1' when (state="0111") else '0';

  
  --outDataTruncated(31 downto 32-USED_BITS_IN_RESULT) <= outDataShuffled(31 downto 32-USED_BITS_IN_RESULT);
  --outDataTruncated(32-USED_BITS_IN_RESULT-1 downto 0) <= outDataShuffled(31 downto 32-(32-USED_BITS_IN_RESULT)) xor outDataShuffled((32-USED_BITS_IN_RESULT)-1 downto 0);  
  outDataTruncated <= outDataShuffled;

  outDataShuffled <= outData(3 downto 0)&outData(31 downto 4);

  hashL <= hash(15 downto 0);
  hashH <= hash(31 downto 16);

  inWord <= in_data(15 downto 0) when (inSelect="000") else
            in_data(31 downto 16) when (inSelect="001") else
            in_data(47 downto 32) when (inSelect="010") else
            in_data(63 downto 48) when (inSelect="011") else
            (others => '0');
  
  main: process (clk)    
  begin

    if clk'event and clk='1' then
      if rst='1' then

        if (PRIME_CHOICE=0) then
          magic <= "1001110110010111";          
        end if;

        if (PRIME_CHOICE=1) then
          magic <= "1011100011000111";
        end if;

        state <= LOAD_FIRST;
        outValid <= '0';
        isLast <= '0';
        mixedLast <= '0';
        hash <= (others => '0');
        inSelect <= "000";
        in_ready <= '0';
 
      else

        in_ready <= '0';
        
        if outReady='1' then
          outValid <= '0';
        end if;
        
        case state is
          when LOAD_FIRST =>
            if in_valid='1' and outReady='1' then
              outValid <= '0';
              inSelect <= "001";
              state <= MULT;
              hash(15 downto 0) <= inWord;
              hash(47 downto 16) <= (others => '0');
              oldHashH <= (others => '0');
            end if;
            
          when LOAD =>
            if in_valid='1' then
              state <= MULT;
              inSelect <= inSelect+1;
              
              if inSelect="100" then
                if in_last='1' then
                  state <= MULT_LAST;
                end if;
                in_ready <= '1';
              end if;
              
              hash(31 downto 0) <= magic*hashL + inWord;
              oldHashH <= hashH;
            end if;
            
          when MULT =>
            state <= LOAD;
            hash(47 downto 16) <= magic*oldHashH + hash(31 downto 16);
            hash(47 downto 32) <= (others => '0');
            
          when MULT_LAST =>
            state <= LOAD_FIRST;
            outData(15 downto 0) <= hashL;
            outData(47 downto 16) <= magic*oldHashH + hash(31 downto 16);
            outData(47 downto 32) <= (others => '0');
            outValid <= '1';
            inSelect <= "000";
            
          when others => null;
        end case;

      end if;

    end if;
    
  end process;


  out_latch : entity work.kvs_LatchedRelay
    generic map ( 32 )
    port map (
      clk, rst,
      outValid, outReady, outDataTruncated,
      out_valid, out_ready, out_data
      );

end comp;
