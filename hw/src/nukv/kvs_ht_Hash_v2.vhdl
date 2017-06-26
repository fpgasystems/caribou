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
USE IEEE.STD_LOGIC_TEXTIO.all;

LIBRARY STD;
USE STD.TEXTIO.ALL;

entity kvs_ht_Hash_v2 is
  generic (
    FUNC_BITS : integer := 5;
    MEMORY_WIDTH : integer := 21
  );    
  port (
    clk : in std_logic;
    rst : in std_logic;

    in_valid : in std_logic;   
    in_data : in std_logic_vector(64-1 downto 0);
    in_last : in std_logic;
    in_ready : out std_logic;
    
    out_valid : out std_logic;
    out_data1 : inout std_logic_vector(31 downto 0);
    out_data2 : inout std_logic_vector(31 downto 0);
    out_ready : in std_logic
    
    );
  
end kvs_ht_Hash_v2;




--architecture xorArch of kvs_ht_Hash_v2 is

--  component nukv_fifogen is
--    generic ( 
--     DATA_SIZE : integer;
--     ADDR_BITS : integer
--    );
--    port (
--      clk : in std_logic;
--      rst : in std_logic;
    
--      s_axis_tvalid : in std_logic;
--      s_axis_tdata : in std_logic_vector(DATA_SIZE-1 downto 0);
--      s_axis_tready : out std_logic;

--      m_axis_tvalid : out std_logic;
--      m_axis_tdata : out std_logic_vector(DATA_SIZE-1 downto 0);
--      m_axis_tready : in std_logic
--    );
--  end component;
  
--  signal hash : std_logic_vector(31 downto 0);
--  signal first : std_logic;

--  signal in_datawlast : std_logic_vector(63+1 downto 0);
--  signal buf_valid : std_logic;
--  signal buf_ready : std_logic;
--  signal buf_datawlast : std_logic_vector(63+1 downto 0);

  
--begin  

--  in_datawlast <= in_last & in_data;

--  buffer_fifo : nukv_fifogen 
--    generic map (
--       DATA_SIZE => 65,
--       ADDR_BITS => 6
--    )
--    port map (
--      clk, rst, 
--      in_valid, in_datawlast, in_ready,
--      buf_valid, buf_datawlast, buf_ready
--      );

--  buf_ready <= out_ready;
  
--  main: process (clk)
--  begin  -- process main
    
--    if (clk'event and clk='1') then
--      if (rst='1') then
        
--        out_valid <= '0';
--        first <= '1';
--        out_data1 <= (others => '0');
--        out_data2 <= (others => '0');
        
--      else
--        if out_ready='1' then
          
--          out_valid <= '0';
          
--          if buf_valid='1' then          

--              if (first='1') then
--                out_data1(MEMORY_WIDTH-1 downto 0) <= (others => '0');
--                out_data2(MEMORY_WIDTH-1 downto 0) <= (others => '0');

--                out_data1(15 downto 0) <= buf_datawlast(15 downto 0);--buf_datawlast(MEMORY_WIDTH-1 downto 0) xor buf_datawlast(MEMORY_WIDTH+MEMORY_WIDTH-1 downto MEMORY_WIDTH);                
--                out_data2(15 downto 0) <= buf_datawlast(15+32 downto 32);--buf_datawlast(63 downto 64-MEMORY_WIDTH) xor buf_datawlast(63-MEMORY_WIDTH downto 64-MEMORY_WIDTH-MEMORY_WIDTH);
--              else
--                out_data1(MEMORY_WIDTH-1 downto 0) <= out_data1(MEMORY_WIDTH-1 downto 0);-- xor (buf_datawlast(MEMORY_WIDTH-1 downto 0) xor buf_datawlast(MEMORY_WIDTH+MEMORY_WIDTH-1 downto MEMORY_WIDTH));
--                out_data2(MEMORY_WIDTH-1 downto 0) <= out_data2(MEMORY_WIDTH-1 downto 0);-- xor (buf_datawlast(63 downto 64-MEMORY_WIDTH) xor buf_datawlast(63-MEMORY_WIDTH downto 64-MEMORY_WIDTH-MEMORY_WIDTH));
--              end if;
            
--            first <= '0';
            
--            if buf_datawlast(64)='1' then
--              out_valid <= '1';
--              first <= '1';
--            end if;
--          end if;
--        end if;
--      end if;
--    end if;
    
--  end process main;
  
--end xorArch;


architecture multArch of kvs_ht_Hash_v2 is

  component nukv_fifogen is
    generic ( 
     DATA_SIZE : integer;
     ADDR_BITS : integer
    );
    port (
      clk : in std_logic;
      rst : in std_logic;
    
      s_axis_tvalid : in std_logic;
      s_axis_tdata : in std_logic_vector(DATA_SIZE-1 downto 0);
      s_axis_tready : out std_logic;

      m_axis_tvalid : out std_logic;
      m_axis_tdata : out std_logic_vector(DATA_SIZE-1 downto 0);
      m_axis_tready : in std_logic
    );
  end component;


  component kvs_ht_MultHashFunc is
  generic (
      PRIME_CHOICE : integer := 0;
      USED_BITS_IN_RESULT : integer := 30
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
  end component;

  signal hash : std_logic_vector(31 downto 0);
  signal first : std_logic;

  signal in_datawlast : std_logic_vector(63+1 downto 0);
  signal buf_valid : std_logic;
  signal buf_ready : std_logic_vector(1 downto 0);
  signal buf_datawlast : std_logic_vector(63+1 downto 0);

  signal hash_valid : std_logic_vector(1 downto 0);  
  

  
begin  

  in_datawlast <= in_last & in_data;

  buffer_fifo : nukv_fifogen 
    generic map (
       DATA_SIZE => 65,
       ADDR_BITS => 6
    )
    port map (
      clk, rst, 
      in_valid, in_datawlast, in_ready,
      buf_valid, buf_datawlast, buf_ready(0)
      );
  
  mult0_func : kvs_ht_MultHashFunc
    generic map ( 
      0,MEMORY_WIDTH
    ) 
    port map (
      clk, rst,
      buf_valid, buf_datawlast(63 downto 0), buf_datawlast(64), buf_ready(0),
      hash_valid(0), out_data1, out_ready
    );

  mult1_func : kvs_ht_MultHashFunc
    generic map ( 
      1,MEMORY_WIDTH
    ) 
    port map (
      clk, rst,
      buf_valid, buf_datawlast(63 downto 0), buf_datawlast(64), buf_ready(1),
      hash_valid(1), out_data2, out_ready
    );

  out_valid <= '1' when hash_valid="11" else '0';
  
end multArch;
