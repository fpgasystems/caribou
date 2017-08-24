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

entity zk_session_Top_wPara is
  generic (
    BUFFER_COUNT : integer := 9;
    PARALLEL_IF_COUNT : integer := 1
    );
  port (
    clk : in std_logic;
    rst : in std_logic;
    rstn : in std_logic;

    stop : in std_logic;
    
    event_valid : in std_logic;
    event_ready : out std_logic;
    event_data  : in std_logic_vector(87 downto 0);

    readreq_valid : out std_logic;
    readreq_ready : in std_logic;
    readreq_data  : out std_logic_vector(31 downto 0);

    packet_valid : in std_logic;
    packet_ready : out std_logic;
    packet_data  : in std_logic_vector(63 downto 0);
    packet_keep  : in std_logic_vector(7 downto 0);
    packet_last  : in std_logic;

    para0_valid : in std_logic;
    para0_ready : out std_logic;
    para0_data  : in std_logic_vector(63 downto 0);
    para0_keep  : in std_logic_vector(7 downto 0);
    para0_last  : in std_logic;

    out_valid   : out std_logic;
    out_ready   : in std_logic;
    out_last    : out std_logic;
    out_data    : out std_logic_vector(63 downto 0);
    out_meta    : out std_logic_vector(63 downto 0);
    
    out_canswitch : in std_logic;
    
    debug_out   : out std_logic_vector(127 downto 0)

    );

end zk_session_Top_wPara;


architecture beh of zk_session_Top_wPara is

component zk_fifo_64x128
  PORT (
  clk : IN STD_LOGIC;
  rst : IN STD_LOGIC;
  din : IN STD_LOGIC_VECTOR(63 DOWNTO 0);
  wr_en : IN STD_LOGIC;
  rd_en : IN STD_LOGIC;
  dout : OUT STD_LOGIC_VECTOR(63 DOWNTO 0);
  full : OUT STD_LOGIC;
  empty : OUT STD_LOGIC
);
END component;

component zk_fifo_128x1024
  PORT (
    s_aclk : IN STD_LOGIC;
    s_aresetn : IN STD_LOGIC;
    s_axis_tvalid : IN STD_LOGIC;
    s_axis_tready : OUT STD_LOGIC;
    s_axis_tdata : IN STD_LOGIC_VECTOR(127 DOWNTO 0);
    m_axis_tvalid : OUT STD_LOGIC;
    m_axis_tready : IN STD_LOGIC;
    m_axis_tdata : OUT STD_LOGIC_VECTOR(127 DOWNTO 0);
    axis_prog_full : out std_logic
  );
END component;

component zk_session_Filter
  generic(
    CONCURRENT_ADDR : integer;
    ADDR_WIDTH : integer
    );
  port (
    clk         : in std_logic;
    rst         : in std_logic;
    push_valid  : in std_logic;
    push_addr   : in std_logic_vector(ADDR_WIDTH-1 downto 0);
    find_loc    : out std_logic_vector(CONCURRENT_ADDR-1 downto 0);    
    pop_valid : in std_logic;
    pop_loc: in std_logic_vector(CONCURRENT_ADDR-1 downto 0)
    );
end component;

  type ARRType  is array(BUFFER_COUNT-1 downto 0) of std_logic_vector(127 downto 0);
 
  signal eventValid : std_logic;
  signal eventReady : std_logic;
  signal eventData : std_logic_vector(87 downto 0);

  signal evdataInValid : std_logic;
  signal evdataInReady : std_logic;
  signal evdataInData : std_logic_vector(63 downto 0);
  signal evdataInFull : std_logic;

  signal evdataOutEmpty : std_logic;
  signal evdataOutValid : std_logic;
  signal evdataOutReady : std_logic;
  signal evdataOutData : std_logic_vector(63 downto 0);

  signal bufferInValid : std_logic_vector(BUFFER_COUNT-1 downto 0);
  signal bufferInReady : std_logic_vector(BUFFER_COUNT-1 downto 0);
  signal bufferInProgFull : std_logic_vector(BUFFER_COUNT-1 downto 0);
  signal bufferInData : std_logic_vector(127 downto 0);

  signal bufferParaIn0 : std_logic_vector(127 downto 0);
  
  signal paraIn0Ready : std_logic;
  signal paraIn0First : std_logic;
  signal paraIn0Second : std_logic;
  signal paraIn0Len : std_logic_vector(7 downto 0);
  signal paraIn0DW : std_logic_vector(63 downto 0);


  signal bufferOutValid : std_logic_vector(BUFFER_COUNT-1 downto 0);
  signal bufferOutReady : std_logic_vector(BUFFER_COUNT-1 downto 0);
  signal bufferOutDataArr : ARRType;
  signal bufferOutDataFolded : ARRType;

  signal packetReady : std_logic;
  signal waitingFirst : std_logic;
  signal dataFirstCycle : std_logic;
  signal waitLocation : std_logic;
  signal haveLocation : std_logic;
  signal locationMask : std_logic_vector(BUFFER_COUNT-1 downto 0);

  signal bufferSelectMask : std_logic_vector(BUFFER_COUNT-PARALLEL_IF_COUNT-1 downto 0);
  signal bufferEmptyChange : std_logic;
  signal bufferEmpty : std_logic_vector(BUFFER_COUNT-1 downto 0);  
  signal bufferEmptyD1 : std_logic_vector(BUFFER_COUNT-1 downto 0);
  signal bufferEmptyMask : std_logic_vector(BUFFER_COUNT-1 downto 0);

  signal readSelectMask : std_logic_vector(BUFFER_COUNT-1 downto 0);
  signal currentHasData : std_logic;

  signal selbufValid : std_logic;
  signal selbufReady : std_logic;
  signal selbufNext : std_logic;
  signal selbufDataA : std_logic_vector(127 downto 0);
  signal selbufData : std_logic_vector(63 downto 0);
  signal selbufMeta : std_logic_vector(63 downto 0);

  signal outValid : std_logic;
  signal outReady : std_logic;
  signal outLast : std_logic;
  signal outFirst : std_logic;
  signal outLength : std_logic_vector(15 downto 0);
  signal outData : std_logic_vector(63 downto 0);
  signal outMeta : std_logic_vector(63 downto 0);

  signal errorLength : std_logic;
  
  signal stopped : std_logic;

begin

  -----------------------------------------------------------------------------
  -----------------------------------------------------------------------------
  -- This module is built from multiple stages. First the events are received
  -- and their read requests are issued. The data coming from the TCP stack
  -- than is distributed to different buffers. A reading module on the other 
  -- end of the buffers makes sure that only full packets are read for each 
  -- session.
  -----------------------------------------------------------------------------
  -----------------------------------------------------------------------------

  -----------------------------------------------------------------------------
  -- CODE TO DEAL WITH THE EVENTS AND ISSUES READ COMMANDS
  ----------------------------------------------------------------------------- 
  eventValid <= event_valid when stopped='0' else '0';
  eventData <= event_data;
  event_ready <= eventReady;

  eventReady <= (evdataInReady and readreq_ready) when (bufferInProgFull=0 and (not bufferInReady)=0 and stopped='0') else '0';
  
  event_proc: process (clk)
  begin
    if (clk'event and clk='1') then
      if (rst='1') then
        evdataInValid <= '0';
	readreq_valid <= '0';
	stopped <= '0';
      else
      
	stopped <= stop;
      
	if (readreq_ready='1') then
	  readreq_valid <= '0';
	end if;
	
	if (evdataInFull='0') then 
		evdataInValid <= '0';
	end if;
	
	if (eventReady='1' and eventData(31 downto 16)/=0) then
	  evdataInValid <= eventValid;
	  readreq_valid <= eventValid;	  
        end if;
	
	evdataInData <= eventData(47+32 downto 32) & eventData(15 downto 0);
	readreq_data <= eventData(31 downto 0);
	
      end if;
    end if;
    
    
  end process;
    
  event_fifo_inst : zk_fifo_64x128
    port map (
      clk, rst,
      evdataInData, 
      evdataInValid, evdataOutReady,
      evdataOutData,
      evdataInFull, 
      evdataOutEmpty  
      );
evdataInReady <= not evdataInFull;
evdataOutValid <= not evdataOutEmpty;


  -----------------------------------------------------------------------------
  -- CODE THAT GETS THE INCOMING DATA AND PUSHES IT INTO BUFFERS
  -----------------------------------------------------------------------------

  packet_proc: process(clk)
  begin
    if (clk'event and clk='1') then
      if (rst='1') then
	
	waitingFirst <= '1';
	bufferEmptyD1 <= (others => '0');
	bufferEmpty <= (others => '0');	
	bufferEmptyChange <= '0';
	haveLocation <= '0';
	waitLocation <= '0';
	locationMask <= (others => '0');
	
      else
	
	if (packet_last='1' and packet_valid='1' and packetReady='1') then
	  waitingFirst <= '1';
	  haveLocation <= '0';
	  locationMask <= (others => '0');
	end if;

	if (waitingFirst='1' and packet_valid='1')then
	  waitingFirst <= '0';
	end if;

	if (dataFirstCycle='1') then
	  waitLocation <= '1';
	end if;
	
	if (waitLocation='1' and bufferSelectMask/=0) then
	  locationMask(BUFFER_COUNT-1 downto BUFFER_COUNT-PARALLEL_IF_COUNT) <= (others=>'0');
	  locationMask(BUFFER_COUNT-PARALLEL_IF_COUNT-1 downto 0) <= bufferSelectMask;
	  waitLocation <= '0';
	  haveLocation <= '1';
	end if;	

	bufferEmptyChange <= '0';
	bufferEmpty <= not bufferOutValid;
	
	if (selbufNext='1') then
	   bufferEmptyD1 <= bufferEmpty;
	end if;

	if (bufferEmpty/=bufferEmptyD1 and selbufNext='1') then
	  bufferEmptyChange <= '1';
	  bufferEmptyMask <= (bufferEmpty xor bufferEmptyD1) and bufferEmpty;
	end if;
	
      end if;
    end if;
  end process;

  packetReady <= '1' when ((locationMask(BUFFER_COUNT-PARALLEL_IF_COUNT-1 downto 0) and bufferInReady(BUFFER_COUNT-PARALLEL_IF_COUNT-1 downto 0))/=0) else '0';
  packet_ready <= packetReady;
  evdataOutReady <= packet_last and packet_valid and packetReady;

  dataFirstCycle <= packet_valid and waitingFirst;
  

  buffer_input_filter : zk_session_Filter
    generic map(
      BUFFER_COUNT-PARALLEL_IF_COUNT,
      16
      )
    port map(
      clk, rst,
      dataFirstCycle, evdataOutData(15 downto 0),
      bufferSelectMask,
      bufferEmptyChange, bufferEmptyMask(BUFFER_COUNT-PARALLEL_IF_COUNT-1 downto 0)
      );

  bufferInData <= packet_data & evdataOutData;
  bufferInValid(BUFFER_COUNT-PARALLEL_IF_COUNT-1 downto 0) <= locationMask(BUFFER_COUNT-PARALLEL_IF_COUNT-1 downto 0) when (packet_valid and haveLocation)='1' else (others=>'0');

  gen_bufs: for X in 0 to BUFFER_COUNT-1-PARALLEL_IF_COUNT generate

    gen_bufs_i: zk_fifo_128x1024
      port map(
        clk, rstn,
        bufferInValid(X), bufferInReady(X), bufferInData,
        bufferOutValid(X), bufferOutReady(X), bufferOutDataArr(X),
        bufferInProgFull(X)        
        );

  end generate gen_bufs;


  killsecondword : process(clk)
  begin 
    if (clk'event and clk='1') then
        if (rst='1') then
          paraIn0First <= '1';
          paraIn0Second <= '0';
          paraIn0Len <= (others => '0');
        else 
        
        if (para0_valid='1' and paraIn0Ready='1') then
            paraIn0Len <= paraIn0Len-1;
            
            if (paraIn0First='1') then
                paraIn0Len <= para0_data(39 downto 32);
            end if;
            
            if (paraIn0Len=0) then
                paraIn0Len <= paraIn0Len;
            end if;
            
        end if;
        
        if (para0_valid='1' and paraIn0Ready='1') then
            paraIn0First <= '0';
            paraIn0Second <= '0';
            
            if (para0_last='1') then
                paraIn0First <= '1';                
            end if;
            
            if (paraIn0First='1') then
                paraIn0Second <= '1'; 
                paraIn0DW <= para0_data;
            end if;
        end if;
        
        end if;
     end if;     
  end process;

    bufferParaIn0(127 downto 64) <= para0_data when paraIn0Second='0' else paraIn0DW;
    bufferParaIn0(63 downto 41) <= (others => '0');
    bufferParaIn0(40) <= para0_last;
    bufferParaIn0(39 downto 32) <= para0_keep;
    bufferParaIn0(31 downto 0) <= "10000000000000000000000000000001";
    bufferInValid(BUFFER_COUNT-1) <= (para0_valid and not paraIn0First) when (paraIn0First='1' or paraIn0Second='1' or paraIn0Len/=0 or para0_data(31 downto 0)/=0) else '0';
    para0_ready <= paraIn0Ready;   
    paraIn0Ready <= bufferInReady(BUFFER_COUNT-1);

   gen_bufs_i: zk_fifo_128x1024
      port map(
        clk, rstn,
        bufferInValid(BUFFER_COUNT-1), bufferInReady(BUFFER_COUNT-1), bufferParaIn0,
        bufferOutValid(BUFFER_COUNT-1), bufferOutReady(BUFFER_COUNT-1), bufferOutDataArr(BUFFER_COUNT-1),
        bufferInProgFull(BUFFER_COUNT-1)        
        );

  -----------------------------------------------------------------------------
  -- READING FROM THE BUFFERS
  -----------------------------------------------------------------------------
    
  selbufValid <= '0' when (readSelectMask and bufferOutValid)=0 else '1';  
  bufferOutReady <= readSelectMask when selbufReady='1' else (others => '0');

  bufferOutDataFolded(BUFFER_COUNT-1) <= bufferOutDataArr(BUFFER_COUNT-1);
  gen_out_sel: for X in BUFFER_COUNT-2 downto 0 generate    
    bufferOutDataFolded(X) <= bufferOutDataArr(X) when readSelectMask(X)='1' else bufferOutDataFolded(X+1);
  end generate;
  selbufDataA <= bufferOutDataFolded(0);
  
  selbufData <= selbufDataA(127 downto 64);
  selbufMeta <= selbufDataA(63 downto 0);
  
  currentHasData <= '0' when (readSelectMask and bufferOutValid)=0 else '1';

  read_select: process(clk)
    variable pos : integer;
  begin
    if (clk'event and clk='1') then
      if (rst='1') then
	readSelectMask <= (others => '0');
	readSelectMask(0) <= '1';
	
      else

	if (currentHasData='0' and bufferOutValid/=0 and selbufNext='1') then
	  --need to find new queue to read from
	  for X in 0 to BUFFER_COUNT-1 loop
	    if (bufferOutValid(X)='1') then
	      pos:=X;
	    end if;
	  end loop;

	  readSelectMask <= (others => '0');
	  readSelectMask(pos) <= '1';
	end if;
	
      end if;
    end if;
  end process;


  -----------------------------------------------------------------------------
  -- CONVERTING TO FINAL OUTPUT FORMAT, PACKETIZING
  -----------------------------------------------------------------------------

  outValid <= selbufValid;
  selbufReady <= outReady;
  outData <= selbufData;
  outMeta <= selbufMeta;
  outLast <= '1' when outLength=0 else '0';
  selbufNext <= '1' when (outFirst='1' and selbufValid='0') or (outLast='1' and  outValid='1') else '0';
  
  get_packets: process(clk)
  begin
    if (clk'event and clk='1') then
      if (rst='1') then
	outFirst <= '1';
	outLength <= (others => '0');
	outLength(0) <= '1';
	errorLength <= '0';
      else

	if (outValid='1' and outReady='1') then

	  outLength <= outLength-1;

	  if (outFirst='1') then
	    if (outData(15+32 downto 32)/=0) then
	      
	      if (outData(15+32 downto 32)>64) then
	        errorLength <= '1';
	      else 
	        errorLength <= '0';
	      end if;
	      
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
  
  
  debug_Delay: process(clk)
  begin
    if (clk'event and clk='1') then  
    --debug_out(119 downto 0) <=--outData(51 downto 0) & errorLength & "0" & paraIn0Second & paraIn0First & "0" & bufferInValid(BUFFER_COUNT-1) & paraIn0Ready & para0_valid &"1111"&para0_data(63 downto 0); 
    --bufferInProgFull&"1111"& errorLength &outFirst & selBufReady & selBufValid & "1111" & bufferOutValid & readSelectMask & "1111" & '0'&waitingFirst&waitLocation&haveLocation & "1111" & bufferInReady & locationMask & "1111" & '0'&outLast&outReady&outValid & '0'&packet_last&packetReady&packet_valid & "00"&eventReady&event_valid; 
    --debug_out(127 downto 116) <= (others => '0');--outData(63-12 downto 0);
    end if;
    
  end process;
  
end beh;
