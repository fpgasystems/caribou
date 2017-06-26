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
use IEEE.std_logic_1164.all;
use IEEE.std_logic_arith.all;
use IEEE.std_logic_unsigned.all;
use IEEE.numeric_std.all;

-------------------------------------------------------------------------------
-- This module is used to filter the input to the hash-table pipeline.
-- It acts as FIFO with a lookup, where the 'find' input is matched to all
-- elements in the queue.
-- The idea is that every write operation is pushed into the filter when
-- entering the pipeline, and popped when the memroy was written.
-- Read operations just need to be checked for address conflicts with the
-- writes, but need	not be stored inside the filter .
-------------------------------------------------------------------------------
entity zk_control_CentralSM is
	generic(
		CMD_SESSID_LOC            : integer := 0;
		CMD_SESSID_LEN            : integer := 16;
		CMD_PEERID_LOC            : integer := 16;
		CMD_PEERID_LEN            : integer := 8;
		CMD_TYPE_LOC              : integer := 24;
		CMD_TYPE_LEN              : integer := 8;
		CMD_PAYLSIZE_LOC          : integer := 32;
		CMD_PAYLSIZE_LEN          : integer := 32;
		CMD_ZXID_LOC              : integer := 64;
		CMD_ZXID_LEN              : integer := 32;
		CMD_EPOCH_LOC             : integer := 96;
		CMD_EPOCH_LEN             : integer := 32;

		MEMCMD_ADDR_LOC           : integer := 0;
		MEMCMD_ADDR_LEN           : integer := 32;
		MEMCMD_SIZE_LOC           : integer := 32;
		MEMCMD_SIZE_LEN           : integer := 32;

		MAX_PEERS                 : integer := 8;
		MAX_OUTSTANDING_REQS_BITS : integer := 12
	);
	port(
		clk                  : in  std_logic;
		rst                  : in  std_logic;

		cmd_in_valid         : in  std_logic;
		cmd_in_data          : in  std_logic_vector(127 downto 0);
		cmd_in_ready         : out std_logic;

		cmd_out_valid        : out std_logic;
		cmd_out_data         : out std_logic_vector(127 downto 0);
		cmd_out_ready        : in  std_logic;

		log_user_reset       : out std_logic;

		log_add_valid        : out std_logic;
		log_add_size         : out std_logic_vector(31 downto 0);
		log_add_zxid         : out std_logic_vector(31 downto 0);
		log_add_drop         : out std_logic;

		log_added_done       : in  std_logic;
		log_added_pos        : in  std_logic_vector(31 downto 0);
		log_added_size       : in  std_logic_vector(31 downto 0);

		log_search_valid     : out std_logic;
		log_search_since     : out std_logic;
		log_search_zxid      : out std_logic_vector(31 downto 0);

		log_found_valid      : in  std_logic;
		log_found_pos        : in  std_logic_vector(31 downto 0);
		log_found_size       : in  std_logic_vector(31 downto 0);

		write_valid          : out std_logic;
		write_cmd            : out std_logic_vector(63 downto 0);
		write_ready          : in  std_logic;

		read_valid           : out std_logic;
		read_cmd             : out std_logic_vector(63 downto 0);
		read_ready           : in  std_logic;

		open_conn_req_valid  : out std_logic;
		open_conn_req_ready  : in  std_logic;
		open_conn_req_data   : out std_logic_vector(47 downto 0);

		open_conn_resp_valid : in  std_logic;
		open_conn_resp_ready : out std_logic;
		open_conn_resp_data  : in  std_logic_vector(16 downto 0);

		error_valid          : out std_logic;
		error_opcode         : out std_logic_vector(7 downto 0);

		sync_dram            : out std_logic_vector(1 downto 0);
		sync_getready        : out std_logic;
		sync_noinflight 	 : in std_logic;

		not_leader           : out std_logic;

		dead_mode            : out std_logic;

		debug_out            : out std_logic_vector(127 downto 0)
	);

end zk_control_CentralSM;

architecture beh of zk_control_CentralSM is
	constant ERRORCHECKING : boolean := true;

	constant OPCODE_SETUPPEER  : integer := 17;
	constant OPCODE_ADDPEER    : integer := 18;
	constant OPCODE_REMOVEPEER : integer := 19;
	constant OPCODE_SETLEADER  : integer := 20;

	constant OPCODE_SETCOMMITCNT  : integer := 25;
	constant OPCODE_SETSILENCECNT : integer := 26;
	constant OPCODE_SETHTSIZE     : integer := 27;

	constant OPCODE_TOGGLEDEAD : integer := 28;

	constant OPCODE_SYNCDRAM : integer := 29;

	constant OPCODE_READREQ    : integer := 0;
	constant OPCODE_WRITEREQ   : integer := 1;
	constant OPCODE_PROPOSAL   : integer := 2;
	constant OPCODE_ACKPROPOSE : integer := 3;
	constant OPCODE_COMMIT     : integer := 4;
	constant OPCODE_SYNCREQ    : integer := 5;
	constant OPCODE_SYNCRESP   : integer := 6;
	constant OPCODE_SYNCFINALACK : integer := 7;

	constant OPCODE_CUREPOCH   : integer := 8;
	constant OPCODE_NEWEPOCH   : integer := 9;
	constant OPCODE_ACKEPOCH   : integer := 10;
	constant OPCODE_SYNCLEADER : integer := 11;

	signal DRAM0_UPPERBOUND : std_logic_vector(31 downto 0);
	signal DRAM1_UPPERBOUND : std_logic_vector(31 downto 0);

	type Array16Large is array (2 ** MAX_OUTSTANDING_REQS_BITS - 1 downto 0) of std_logic_vector(15 downto 0);

	type Array32 is array (MAX_PEERS downto 0) of std_logic_vector(31 downto 0);
	type Array48 is array (MAX_PEERS downto 0) of std_logic_vector(47 downto 0);
	type Array16 is array (MAX_PEERS downto 0) of std_logic_vector(15 downto 0);

	type RoleType is (ROLE_LEADER, ROLE_FOLLOWER, ROLE_UNKNOWN);
	type PhaseType is (PH_ELECTION, PH_SYNC, PH_NORMAL, PH_STARTUP);
	type StateType is (ST_WAITOP, ST_HANDLEOP, ST_OPENTCPCONN, ST_SENDTOALL, ST_FINISH_WRITEREQ,
		               ST_CHKQRM_ACKS, ST_FINISH_COMMIT, ST_FINISH_COMMIT_LATE, ST_FINISH_COMMIT_DATAFORAPP,
		               ST_WAIT_MEMWRITE, ST_REQUESTSYNC, ST_SENDSYNC, ST_GETLOGSYNC, ST_DRAMSYNC,
		               ST_PROP_LEADER, ST_CHKQRM_PROPS, ST_SENDNEWEPOCH, ST_SENDNEWEPOCH_JOIN, ST_SYNC_ELECTION, ST_SAYWHOISLEADER, ST_SYNC_SWITCHMEM, ST_SYNC_SWITCHOFF);

	signal prevRole : RoleType;
	signal myRole   : RoleType;
	signal myPhase  : PhaseType;
	signal myState  : StateType;

	signal clientReqSess : Array16Large;
	signal clientReqZxid : Array16Large;

	signal myZxid       : std_logic_vector(31 downto 0);
	signal proposedZxid : std_logic_vector(31 downto 0);
	signal myEpoch      : std_logic_vector(31 downto 0);
	signal myIPAddr     : std_logic_vector(31 downto 0);

	signal myPeerId             : std_logic_vector(CMD_PEERID_LEN - 1 downto 0);
	signal leaderPeerId         : std_logic_vector(CMD_PEERID_LEN - 1 downto 0);
	signal nextLeaderId         : std_logic_vector(CMD_PEERID_LEN - 1 downto 0);
	signal sinceHeardFromLeader : std_logic_vector(31 downto 0);
	signal silenceThreshold     : std_logic_vector(31 downto 0);
	signal silenceMeasured      : std_logic;

	signal voteCount  : std_logic_vector(3 downto 0);
	signal votedEpoch : std_logic_vector(31 downto 0);
	signal votedZxid  : std_logic_vector(31 downto 0);
	signal syncFrom   : std_logic_vector(CMD_PEERID_LEN - 1 downto 0);

	signal peerCount   : std_logic_vector(7 downto 0);
	signal peerIP      : Array48;
	signal peerSessId  : Array16;
	signal peerZxidAck : Array32;
	signal peerZxidCmt : Array32;
	signal peerEpoch   : Array32;

	signal peerCountForCommit : std_logic_vector(7 downto 0);

	signal thisPeersAckedZxid : std_logic_vector(CMD_ZXID_LEN - 1 downto 0);
	signal thisPeersCmtdZxid  : std_logic_vector(CMD_ZXID_LEN - 1 downto 0);

	signal inCmdReady       : std_logic;
	signal inCmdOpCode      : std_logic_vector(CMD_TYPE_LEN - 1 downto 0);
	signal inCmdSessId      : std_logic_vector(CMD_SESSID_LEN - 1 downto 0);
	signal inCmdPeerId      : std_logic_vector(CMD_PEERID_LEN - 1 downto 0);
	signal inCmdZxid        : std_logic_vector(CMD_ZXID_LEN - 1 downto 0);
	signal inCmdEpoch       : std_logic_vector(CMD_EPOCH_LEN - 1 downto 0);
	signal inCmdPayloadSize : std_logic_vector(CMD_PAYLSIZE_LEN - 1 downto 0);

	signal inCmdOpCode_I      : std_logic_vector(CMD_TYPE_LEN - 1 downto 0);
	signal inCmdSessId_I      : std_logic_vector(CMD_SESSID_LEN - 1 downto 0);
	signal inCmdPeerId_I      : std_logic_vector(CMD_PEERID_LEN - 1 downto 0);
	signal inCmdZxid_I        : std_logic_vector(CMD_ZXID_LEN - 1 downto 0);
	signal inCmdEpoch_I       : std_logic_vector(CMD_EPOCH_LEN - 1 downto 0);
	signal inCmdPayloadSize_I : std_logic_vector(CMD_PAYLSIZE_LEN - 1 downto 0);

	signal syncZxid        : std_logic_vector(CMD_ZXID_LEN - 1 downto 0);
	signal syncMode        : std_logic_vector(1 downto 0); -- 0=off, 1=kvs area, 2=pointer area
	signal syncPrepare     : std_logic;
	signal syncDramAddress : std_logic_vector(31 downto 0);
	signal htSyncSize      : std_logic_vector(31 downto 0);
	signal totalSyncWordsSent : std_logic_vector(31 downto 0);

	signal connToPeerId    : std_logic_vector(CMD_PEERID_LEN - 1 downto 0);
	signal connToIpAddress : std_logic_vector(31 downto 0);
	signal connToPort      : std_logic_vector(15 downto 0);
	signal connToSessId    : std_logic_vector(15 downto 0);
	signal connToWaiting   : std_logic;

	signal sendOpcode      : std_logic_vector(7 downto 0);
	signal sendPayloadSize : std_logic_vector(31 downto 0);
	signal sendZxid        : std_logic_vector(31 downto 0);
	signal sendEpoch       : std_logic_vector(31 downto 0);
	signal sendCount       : std_logic_vector(7 downto 0);
	signal sendEnableMask  : std_logic_vector(MAX_PEERS downto 0);

	signal loopIteration   : std_logic_vector(7 downto 0);
	signal quorumIteration : std_logic_vector(7 downto 0);

	signal commitableCount         : std_logic_vector(7 downto 0);
	signal commitableCountTimesTwo : std_logic_vector(7 downto 0);

	signal cmdForParallelData  : std_logic_vector(127 downto 0);
	signal cmdForParallelValid : std_logic;

	signal logHeadLoc         : std_logic_vector(31 downto 0);
	signal logAddedSizeP1     : std_logic_vector(15 downto 0);
	signal inCmdPayloadSizeP1 : std_logic_vector(15 downto 0);

	signal logFoundSizeP1 : std_logic_vector(15 downto 0);

	signal returnState : StateType;

	signal foundInLog : std_logic;
	signal cmdSent    : std_logic;

	signal sessMemEnable   : std_logic;
	signal sessMemEnableD1 : std_logic;
	signal sessMemEnableD2 : std_logic;
	signal sessMemWrite    : std_logic_vector(0 downto 0);
	signal sessMemAddr     : std_logic_vector(MAX_OUTSTANDING_REQS_BITS - 1 downto 0);
	signal sessMemDataIn   : std_logic_vector(16 + 31 downto 0);
	signal sessMemDataOut  : std_logic_vector(16 + 31 downto 0);

	signal internalClk  : std_logic_vector(31 downto 0);
	signal receiveTime  : std_logic_vector(15 downto 0);
	signal responseTime : std_logic_vector(15 downto 0);

	signal syncReqTimeout : std_logic_vector(20 downto 0);

	signal syncModeWaited : std_logic_vector(31 downto 0);

	signal traceLoc : std_logic_vector(7 downto 0);

	signal syncPeerId : std_logic_vector(7 downto 0);

	signal isDead : std_logic;

	component zk_blkmem_32x1024
		port(
			clka  : in  std_logic;
			--ena : IN STD_LOGIC;
			wea   : in  std_logic_vector(0 downto 0);
			addra : in  std_logic_vector(MAX_OUTSTANDING_REQS_BITS - 1 downto 0);
			dina  : in  std_logic_vector(47 downto 0);
			douta : out std_logic_vector(47 downto 0)
		);
	end component;

	signal rstBuf : std_logic;

begin
	cmd_in_ready <= inCmdReady;

	inCmdOpCode_I      <= cmd_in_data(CMD_TYPE_LEN - 1 + CMD_TYPE_LOC downto CMD_TYPE_LOC);
	inCmdSessID_I      <= cmd_in_data(CMD_SESSID_LEN - 1 + CMD_SESSID_LOC downto CMD_SESSID_LOC);
	inCmdPeerID_I      <= cmd_in_data(CMD_PEERID_LEN - 1 + CMD_PEERID_LOC downto CMD_PEERID_LOC);
	inCmdZxid_I        <= cmd_in_data(CMD_ZXID_LEN - 1 + CMD_ZXID_LOC downto CMD_ZXID_LOC);
	inCmdEpoch_I       <= cmd_in_data(CMD_EPOCH_LEN - 1 + CMD_EPOCH_LOC downto CMD_EPOCH_LOC);
	inCmdPayloadSize_I <= cmd_in_data(CMD_PAYLSIZE_LEN - 1 + CMD_PAYLSIZE_LOC downto CMD_PAYLSIZE_LOC);

	-----------------------------------------------------------------------------
	-- memory stuff
	-----------------------------------------------------------------------------
	write_valid                    <= log_added_done;
	logAddedSizeP1                 <= (log_added_size(15 downto 0) + 7);
	write_cmd(32 + 8 - 1 downto 0) <= logAddedSizeP1(10 downto 3) & log_added_pos;
	write_cmd(63 downto 40)        <= (others => '0');

	logFoundSizeP1 <= (log_found_size(15 downto 0) + 7);

	inCmdPayloadSizeP1 <= (inCmdPayloadSize(15 downto 0) + 7);

	commitableCountTimesTwo <= commitableCount(6 downto 0) & "0";

	sync_dram     <= syncMode;
	sync_getready <= syncPrepare;

	dead_mode <= isDead;

	main : process(clk)
	begin
		if (clk'event and clk = '1') then
			rstBuf <= rst;

			if (rstBuf = '1') then
				syncReqTimeout <= (others => '0');
				syncMode       <= "00";
				syncPrepare    <= '0';
				syncModeWaited <= (others => '0');

				DRAM0_UPPERBOUND <= (others => '0');
				DRAM0_UPPERBOUND(26) <= '1'; --(26)
				DRAM1_UPPERBOUND <= (others => '0');
				DRAM1_UPPERBOUND(21) <= '1'; --(21)

				htSyncSize     <= (others => '0');
				htSyncSize(26+3) <= '1';
				htSyncSize(21+3) <= '1';

				prevRole <= ROLE_UNKNOWN;
				myRole   <= ROLE_UNKNOWN;
				myPhase  <= PH_STARTUP;
				myState  <= ST_WAITOP;

				myPeerId     <= (others => '0');
				myZxid       <= (others => '0');
				myEpoch      <= (others => '0');
				proposedZxid <= (others => '0');

				peerCount <= (others => '0');

				sinceHeardFromLeader <= (others => '0');
				silenceThreshold     <= (others => '0');
				silenceMeasured      <= '0';

				voteCount  <= (others => '0');
				votedEpoch <= (others => '0');
				syncFrom   <= (others => '0');
				votedZxid  <= (others => '0');

				for X in MAX_PEERS - 1 downto 0 loop
					peerIP(X)      <= (others => '0');
					peerSessId(X)  <= (others => '0');
					peerZxidAck(X) <= (others => '0');
					peerZxidCmt(X) <= (others => '0');
					peerEpoch(X)   <= (others => '0');
				end loop;

				inCmdReady <= '1';

				error_valid <= '0';

				open_conn_resp_ready <= '1';
				open_conn_req_valid  <= '0';

				log_add_valid    <= '0';
				log_search_valid <= '0';
				log_user_reset   <= '0';

				cmd_out_valid <= '0';

				read_valid <= '0';
				--write_valid <= '0';

				foundInLog <= '0';

				sendEnableMask <= (others => '1');

				sessMemEnable   <= '0';
				sessMemWrite(0) <= '0';

				cmdSent <= '0';

				internalClk <= (others => '0');

				peerCountForCommit  <= (others => '0');
				cmdForParallelValid <= '0';

				traceLoc <= (others => '0');

				not_leader <= '1';
				isDead     <= '0';

			else
				if (myRole = ROLE_LEADER and myPhase = PH_NORMAL) then
					not_leader <= '0';
				else
					not_leader <= '1';
				end if;

				if (log_added_done = '1') then
					logHeadLoc <= log_added_pos;
				end if;

				internalClk <= internalClk + 1;

				if (syncReqTimeout /= 0) then
					syncReqTimeout <= syncReqTimeout - 1;
				end if;

				--if (internalClk(19 downto 0) = 0 ) then

				--end if;

				sessMemEnableD2 <= sessMemEnableD1;
				sessMemEnableD1 <= sessMemEnable;
				sessMemEnable   <= '0';
				sessMemWrite(0) <= '0';

				error_valid      <= '0';
				log_add_valid    <= '0';
				log_search_valid <= '0';
				log_add_drop     <= '0';
				log_user_reset   <= '0';

				if (cmd_out_ready = '1') then
					cmd_out_valid <= '0';
				end if;

				if (read_ready = '1') then
					read_valid <= '0';
				end if;

				--if (write_ready='1') then
				--	write_valid <= '0';
				--end if;

				sinceHeardFromLeader <= (others => '0'); --sinceHeardFromLeader +1;

				if (syncPrepare = '1' or syncMode > 0) then
					syncModeWaited <= syncModeWaited + 1;
				end if;

				if (myState = ST_WAITOP and cmd_in_valid = '0' and syncPrepare = '1' and syncModeWaited > 4096) then
					syncPrepare     <= '0';
					syncMode        <= "01";
					syncDramAddress <= (others => '0');
					syncModeWaited  <= (others => '0');
					totalSyncWordsSent       <= (others => '0');
					myState         <= ST_DRAMSYNC;
					inCmdReady      <= '0';
				end if;

				case myState is

					---------------------------------------------------------------------
					-- WAIT OP: wait for next command, perform in
					-- initial checks on it
					---------------------------------------------------------------------
					when ST_WAITOP =>
						traceLoc <= "00000001";

						if (cmd_in_valid = '1' and inCmdReady = '1') then
							inCmdOpCode      <= cmd_in_data(CMD_TYPE_LEN - 1 + CMD_TYPE_LOC downto CMD_TYPE_LOC);
							inCmdSessID      <= cmd_in_data(CMD_SESSID_LEN - 1 + CMD_SESSID_LOC downto CMD_SESSID_LOC);
							inCmdPeerID      <= cmd_in_data(CMD_PEERID_LEN - 1 + CMD_PEERID_LOC downto CMD_PEERID_LOC);
							inCmdZxid        <= cmd_in_data(CMD_ZXID_LEN - 1 + CMD_ZXID_LOC downto CMD_ZXID_LOC);
							inCmdEpoch       <= cmd_in_data(CMD_EPOCH_LEN - 1 + CMD_EPOCH_LOC downto CMD_EPOCH_LOC);
							inCmdPayloadSize <= cmd_in_data(CMD_PAYLSIZE_LEN - 1 + CMD_PAYLSIZE_LOC downto CMD_PAYLSIZE_LOC);

							sendEnableMask <= (others => '1');

							case (conv_integer(inCmdOpCode_I(CMD_TYPE_LEN - 1 downto 0))) is

								-- SETUP PEER
								when (OPCODE_SETUPPEER) =>
									traceLoc <= "00000010";

									if (myRole = ROLE_UNKNOWN and myPhase = PH_STARTUP and inCmdPeerId_I /= 0) then
										myState    <= ST_HANDLEOP;
										inCmdReady <= '0';
									else
										error_valid  <= '1';
										error_opcode <= inCmdOpCode_I;
									end if;

								-- SET LEADERSHIP
								when (OPCODE_SETLEADER) =>
									traceLoc <= "00000011";

									if (((myRole = ROLE_UNKNOWN and myPhase = PH_STARTUP) or myPhase = PH_ELECTION) and inCmdPeerId_I /= 0 and myPeerId /= 0 and inCmdEpoch_I = 0) then
										myState    <= ST_HANDLEOP;
										inCmdReady <= '0';
									else
										error_valid  <= '1';
										error_opcode <= inCmdOpCode_I;
									end if;

								-- ADD PEER
								when (OPCODE_ADDPEER) =>
									traceLoc <= "00000100";

									if ((myPhase = PH_STARTUP or myRole = ROLE_LEADER) and inCmdPeerId_I /= myPeerId and (inCmdEpoch_I /= 0 or inCmdZxid_I /= 0)) then
										myState    <= ST_HANDLEOP;
										inCmdReady <= '0';
									else
										error_valid  <= '1';
										error_opcode <= inCmdOpCode_I;
									end if;

								when (OPCODE_TOGGLEDEAD) =>
									traceLoc <= "10101010";
									isDead   <= not isDead;

								-- SET THE NUMBER OF PEERS USED FOR COMPUTING MAJORITY
								when (OPCODE_SETCOMMITCNT) =>
									traceLoc <= "00000101";
									if (myPhase = PH_NORMAL and myRole = ROLE_LEADER) then
										peerCountForCommit <= inCmdEpoch_I(7 downto 0);

									else
										error_valid  <= '1';
										error_opcode <= inCmdOpCode_I;
									end if;

								when (OPCODE_SETSILENCECNT) =>
									traceLoc                       <= "00000110";
									silenceThreshold(17 downto 10) <= inCmdEpoch_I(7 downto 0);
									silenceMeasured                <= '1';
									sinceHeardFromLeader           <= (others => '0');

								when (OPCODE_SETHTSIZE) =>
									traceLoc   <= "00000110";
									htSyncSize <= inCmdEpoch_I(31 downto 0);

								-- WRITE REQUEST
								when (OPCODE_WRITEREQ) =>
									traceLoc <= "00000111";
									if (myPhase = PH_NORMAL and myRole = ROLE_LEADER) then
										-- if I am the leader, I need to 1) add the request to the
										-- log, 2) send out proposals to the peers 3) wait for acks
										-- from them, and finally commit. The acks are handled "in
										-- parallel" to this operation, and they trigger the commits.
										--

										receiveTime <= internalClk(15 downto 0);

										loopIteration       <= peerCount + 1;
										cmdForParallelValid <= '0';
										cmdForParallelData  <= (others => '0');

										if (write_ready = '1') then
											myState    <= ST_HANDLEOP;
											inCmdReady <= '0';
										else
											myState     <= ST_WAIT_MEMWRITE;
											inCmdReady  <= '0';
											returnState <= ST_HANDLEOP;
										end if;

									else

										--				if (prevRole=ROLE_LEADER) then
										--					cmd_out_valid <= '1';
										--					cmd_out_data(CMD_PAYLSIZE_LOC+CMD_PAYLSIZE_LEN-1 downto CMD_PAYLSIZE_LOC) <= (others=>'0');
										--					cmd_out_data(CMD_TYPE_LEN+CMD_TYPE_LOC-1 downto CMD_TYPE_LOC) <= std_logic_Vector(conv_unsigned(69, 8));
										--					cmd_out_data(CMD_EPOCH_LOC+CMD_EPOCH_LEN-1 downto CMD_EPOCH_LOC) <= (others => '0');
										--					cmd_out_data(CMD_ZXID_LOC+CMD_ZXID_LEN-1 downto CMD_ZXID_LOC) <= (others => '0');
										--					cmd_out_data(CMD_PEERID_LEN+CMD_PEERID_LOC-1 downto CMD_PEERID_LOC) <= myPeerId;
										--					cmd_out_data(CMD_SESSID_LOC+CMD_SESSID_LEN-1 downto CMD_SESSID_LOC) <= inCmdSessID_I;
										--				end if;

										error_valid  <= '1';
										error_opcode <= inCmdOpCode_I;
									end if;

								when (OPCODE_ACKPROPOSE) =>
									traceLoc <= "00001000";
									if (myPhase = PH_NORMAL and myRole = ROLE_LEADER and proposedZxid >= inCmdZxid_I) then
										thisPeersAckedZxid <= peerZxidAck(conv_integer(inCmdPeerId_I));
										thisPeersCmtdZxid  <= peerZxidCmt(conv_integer(inCmdPeerId_I));

										myState    <= ST_HANDLEOP;
										inCmdReady <= '0';

									else
										error_valid  <= '1';
										error_opcode <= proposedZxid(7 downto 0); -- & inCmdOpCode(3 downto 0);

									end if;

								when (OPCODE_SYNCREQ) =>
									traceLoc <= "00001001";
									if ((myPhase = PH_NORMAL and myRole = ROLE_LEADER and proposedZxid >= inCmdZxid_I) or (myRole = ROLE_FOLLOWER)) then
										syncZxid <= inCmdZxid_I;

										if (myRole = ROLE_FOLLOWER) then
											proposedZxid <= myZxid;
										end if;

										if (proposedZxid - inCmdZxid_I < 128) then
											myState    <= ST_GETLOGSYNC;
											inCmdReady <= '0';
										else
											myState <= ST_WAITOP;
											if (syncPrepare = '0') then
												syncModeWaited <= (others => '0');
												syncPeerId     <= inCmdPeerID_I;
											end if;
											syncPrepare <= '1';
											inCmdReady  <= '1';

											cmd_out_valid  <= '1';
											cmd_out_data(CMD_PAYLSIZE_LOC + CMD_PAYLSIZE_LEN - 1 downto CMD_PAYLSIZE_LOC) <= (others => '0');
											cmd_out_data(CMD_TYPE_LEN + CMD_TYPE_LOC - 1 downto CMD_TYPE_LOC) <= std_logic_vector(conv_unsigned(OPCODE_SYNCDRAM, 8));
											cmd_out_data(CMD_EPOCH_LOC + CMD_EPOCH_LEN - 1 downto CMD_EPOCH_LOC)    <= (others=>'0'); 
											cmd_out_data(CMD_ZXID_LOC + CMD_ZXID_LEN - 1 downto CMD_ZXID_LOC)       <= myZxid;
											cmd_out_data(CMD_PEERID_LEN + CMD_PEERID_LOC - 1 downto CMD_PEERID_LOC) <= myPeerId;
											cmd_out_data(CMD_SESSID_LOC + CMD_SESSID_LEN - 1 downto CMD_SESSID_LOC) <= peerSessId(conv_integer(inCmdPeerId_I));
										end if;

									else
										error_valid  <= '1';
										error_opcode <= proposedZxid(7 downto 0); -- & inCmdOpCode(3 downto 0);

									end if;

								when (OPCODE_PROPOSAL) =>
									traceLoc <= "00001010";
									if (myPhase = PH_NORMAL and myRole = ROLE_FOLLOWER and leaderPeerId = inCmdPeerId_I) then

										--sinceHeardFromLeader <= (others => '0');

										if (inCmdZxid_I = myZxid + 1 and inCmdEpoch_I = myEpoch and inCmdPayloadSize_I <= (256 / 8)) then
											if (write_ready = '1') then
												myState    <= ST_HANDLEOP;
												inCmdReady <= '0';
											else
												myState     <= ST_WAIT_MEMWRITE;
												returnState <= ST_HANDLEOP;
												inCmdReady  <= '0';
											end if;
										else
											error_valid  <= '1';
											error_opcode <= "1010" & inCmdOpCode_I(3 downto 0);

											if (inCmdZxid_I <= myZxid or inCmdPayloadSize_I > (256 / 8)) then
												log_add_valid <= '1';
												log_add_drop  <= '1';
												log_add_size  <= inCmdPayloadSize_I;
												myState       <= ST_WAITOP;
												inCmdReady    <= '1';

											else
												myState <= ST_REQUESTSYNC;
												--myState <= ST_HANDLEOP;

												log_add_valid <= '1';
												log_add_drop  <= '1';
												log_add_size  <= inCmdPayloadSize_I;

												inCmdReady <= '0';

											end if;
										end if;

									else
										error_valid  <= '1';
										error_opcode <= inCmdOpCode_I;
									end if;

								when (OPCODE_SYNCRESP) =>
									traceLoc <= "00001011";
									if (myPhase = PH_NORMAL and myRole = ROLE_FOLLOWER and leaderPeerId = inCmdPeerId_I) then
										if (inCmdZxid_I = myZxid + 1 and inCmdEpoch_I = myEpoch) then
											if (write_ready = '1') then
												myState    <= ST_HANDLEOP;
												inCmdReady <= '0';
											else
												myState     <= ST_WAIT_MEMWRITE;
												returnState <= ST_HANDLEOP;
												inCmdReady  <= '0';
											end if;
										else
											error_valid  <= '1';
											error_opcode <= "1000" & inCmdOpCode_I(3 downto 0);
										end if;

									else
										error_valid  <= '1';
										error_opcode <= inCmdOpCode_I;
									end if;

								when (OPCODE_COMMIT) =>
									traceLoc <= "00001100";
									if (myPhase = PH_NORMAL and myRole = ROLE_FOLLOWER and leaderPeerId = inCmdPeerId_I) then
										if (inCmdZxid_I <= myZxid and inCmdEpoch_I = myEpoch) then
											log_search_valid <= '1';
											log_search_since <= '0';
											log_search_zxid  <= inCmdZxid_I;

											myState    <= ST_HANDLEOP;
											cmdSent    <= '0';
											inCmdReady <= '0';

										else
											error_valid  <= '1';
											error_opcode <= inCmdOpCode_I;

										end if;

									end if;

								when (OPCODE_CUREPOCH) =>
									traceLoc <= "00001101";
									if (myPhase = PH_ELECTION) then
										nextLeaderId <= myPeerId;
										myPhase      <= PH_ELECTION;
										prevRole     <= myRole;

										peerEpoch(ieee.numeric_std.to_integer(ieee.numeric_std.unsigned(inCmdPeerId_I)))(31 downto 0) <= inCmdEpoch_I;

										voteCount <= voteCount + 1;

										if (inCmdEpoch_I > votedEpoch) then
											votedEpoch <= inCmdEpoch_I;
											votedZxid  <= inCmdZxid_I;
											syncFrom   <= inCmdPeerId_I;
										end if;

										if (voteCount + 1 >= peerCount(7 downto 1)) then
											inCmdReady <= '0';
											myState    <= ST_SENDNEWEPOCH;
										end if;

									end if;

									--if (myPhase=PH_NORMAL and myRole=ROLE_FOLLOWER) then
									--	inCmdReady <= '0';
									--	myState <= ST_SAYWHOISLEADER;
									--end if;

									if (myPhase = PH_NORMAL and myRole = ROLE_LEADER and myEpoch >= inCmdEpoch_I) then
										inCmdReady <= '0';
										myState    <= ST_SENDNEWEPOCH_JOIN;

									end if;

									if (myPhase = PH_NORMAL and ((myRole = ROLE_LEADER and myEpoch < inCmdEpoch_I) or (myRole = ROLE_FOLLOWER))) then
										nextLeaderId <= myPeerId;
										myPhase      <= PH_ELECTION;
										prevRole     <= myRole;

										peerEpoch(ieee.numeric_std.to_integer(ieee.numeric_std.unsigned(inCmdPeerId_I)))(31 downto 0) <= inCmdEpoch_I;

										voteCount <= "0001";

										if (myEpoch < inCmdEpoch_I) then
											votedEpoch <= inCmdEpoch_I;
											votedZxid  <= inCmdZxid_I;
											syncFrom   <= inCmdPeerId_I;
										else
											votedEpoch <= myEpoch;
											votedZxid  <= myZxid;
											syncFrom   <= myPeerId;
										end if;

										if (2 >= peerCount(7 downto 1)) then
											inCmdReady <= '0';
											myState    <= ST_SENDNEWEPOCH;
										end if;
									end if;

								when (OPCODE_NEWEPOCH) =>
									traceLoc <= "00001110";
									if (inCmdPeerId_I = leaderPeerId) then
										sinceHeardFromLeader <= (others => '0');
									end if;

									if (myPhase = PH_ELECTION and inCmdPeerId_I = nextLeaderId) then
										myEpoch         <= inCmdEpoch_I;
										myZxid          <= inCmdZxid_I;
										leaderPeerId    <= inCmdPeerId_I;
										myPhase         <= PH_NORMAL;
										prevRole        <= myRole;
										myRole          <= ROLE_FOLLOWER;
										silenceMeasured <= '0';

										cmd_out_valid                                                                 <= '1';
										cmd_out_data(CMD_PAYLSIZE_LOC + CMD_PAYLSIZE_LEN - 1 downto CMD_PAYLSIZE_LOC) <= (others => '0');
										cmd_out_data(CMD_TYPE_LEN + CMD_TYPE_LOC - 1 downto CMD_TYPE_LOC)             <= std_logic_vector(conv_unsigned(OPCODE_ACKEPOCH, 8));
										cmd_out_data(CMD_EPOCH_LOC + CMD_EPOCH_LEN - 1 downto CMD_EPOCH_LOC)          <= inCmdEpoch_I;
										cmd_out_data(CMD_ZXID_LOC + CMD_ZXID_LEN - 1 downto CMD_ZXID_LOC)             <= inCmdZxid_I;
										cmd_out_data(CMD_PEERID_LEN + CMD_PEERID_LOC - 1 downto CMD_PEERID_LOC)       <= myPeerId;
										cmd_out_data(CMD_SESSID_LOC + CMD_SESSID_LEN - 1 downto CMD_SESSID_LOC)       <= peerSessId(conv_integer(inCmdPeerId_I));

									end if;

									if (myPhase = PH_NORMAL and myRole = ROLE_LEADER and inCmdPeerId_I > myPeerId) then
										if (inCmdPeerId_I < peerCount) then
											nextLeaderId <= inCmdPeerId_I + 1;
										else
											nextLeaderId    <= (others => '0');
											nextLeaderId(0) <= '1';
										end if;
										leaderPeerId <= inCmdPeerId_I;
										prevRole     <= myRole;
										myRole       <= ROLE_FOLLOWER;
										myEpoch      <= inCmdEpoch_I;
										myZxid       <= inCmdZxid_I;

										cmd_out_valid                                                                 <= '1';
										cmd_out_data(CMD_PAYLSIZE_LOC + CMD_PAYLSIZE_LEN - 1 downto CMD_PAYLSIZE_LOC) <= (others => '0');
										cmd_out_data(CMD_TYPE_LEN + CMD_TYPE_LOC - 1 downto CMD_TYPE_LOC)             <= std_logic_vector(conv_unsigned(OPCODE_ACKEPOCH, 8));
										cmd_out_data(CMD_EPOCH_LOC + CMD_EPOCH_LEN - 1 downto CMD_EPOCH_LOC)          <= inCmdEpoch_I;
										cmd_out_data(CMD_ZXID_LOC + CMD_ZXID_LEN - 1 downto CMD_ZXID_LOC)             <= inCmdZxid_I;
										cmd_out_data(CMD_PEERID_LEN + CMD_PEERID_LOC - 1 downto CMD_PEERID_LOC)       <= myPeerId;
										cmd_out_data(CMD_SESSID_LOC + CMD_SESSID_LEN - 1 downto CMD_SESSID_LOC)       <= peerSessId(conv_integer(inCmdPeerId_I));

									--myPhase <= PH_ELECTION;
									--myRole <= ROLE_FOLLOWER;
									end if;

								when (OPCODE_ACKEPOCH) =>
									traceLoc   <= "00001111";
									myState    <= ST_HANDLEOP;
									inCmdReady <= '0';

								when (OPCODE_SYNCLEADER) =>
									traceLoc <= "00010000";
									if (myPhase = PH_SYNC and myRole = ROLE_LEADER) then
										if (write_ready = '1') then
											myState    <= ST_HANDLEOP;
											inCmdReady <= '0';
										else
											myState     <= ST_WAIT_MEMWRITE;
											inCmdReady  <= '0';
											returnState <= ST_HANDLEOP;
										end if;

										if (inCmdZxid_I = votedZxid) then
											myZxid          <= votedZxid;
											proposedZxid    <= votedZxid;
											myPhase         <= PH_NORMAL;
											proposedZxid    <= votedZxid;
											silenceMeasured <= '0';
										end if;

									else
										error_valid  <= '1';
										error_opcode <= inCmdOpCode_I;
									end if;

								when (OPCODE_SYNCDRAM) =>
									traceLoc <= "11001100";

									if (myPhase = PH_NORMAL and myRole = ROLE_FOLLOWER and leaderPeerId = inCmdPeerId_I) then
										if (syncMode = 0) then
											syncMode       <= "01";
											log_user_reset <= '1';
										end if;

										if (write_ready = '1') then
											myState    <= ST_HANDLEOP;
											inCmdReady <= '0';
										else
											myState     <= ST_WAIT_MEMWRITE;
											returnState <= ST_HANDLEOP;
											inCmdReady  <= '0';
										end if;
									else
										error_valid  <= '1';
										error_opcode <= inCmdOpCode_I;
									end if;

								when (OPCODE_SYNCFINALACK) =>
									traceLoc <= "00001000";
									if (myPhase = PH_NORMAL and myRole = ROLE_LEADER and proposedZxid >= inCmdZxid_I) then
										peerZxidAck(conv_integer(inCmdPeerId_I))<= inCmdZxid_I;
										peerZxidCmt(conv_integer(inCmdPeerId_I))<= inCmdZxid_I;

										myState    <= ST_WAITOP;
										inCmdReady <= '1';

									else
										error_valid  <= '1';
										error_opcode <= proposedZxid(7 downto 0); -- & inCmdOpCode(3 downto 0);

									end if;

								-- UNKNOWN/UNHANDLED OP CODE
								when others =>
									error_valid  <= '1';
									error_opcode <= inCmdOpCode_I;

							end case;

						else
							if ((myPhase = PH_NORMAL or myPhase = PH_ELECTION) and sinceHeardFromLeader > silenceThreshold and silenceMeasured = '1') then
								-- we need to send the next epoch to the prospective leader -- the next in the order.

								if (myPhase = PH_ELECTION and sinceHeardFromLeader < 2 ** 30) then
									traceLoc <= "00010001";
									-- this was a failed election round...

									if (nextLeaderId = peercount + 1) then
										nextLeaderId    <= (others => '0');
										nextLeaderId(0) <= '1';
									else
										nextLeaderId <= nextLeaderId + 1;
									end if;

									sinceHeardFromLeader     <= (others => '0');
									sinceHeardFromLeader(30) <= '1';

									voteCount <= (others => '0');

								end if;

								if (myPhase = PH_NORMAL or sinceHeardFromLeader > 2 ** 30) then
									traceLoc             <= "00010010";
									sinceHeardFromLeader <= (others => '0');

									myPhase  <= PH_ELECTION;
									prevRole <= myRole;

									voteCount <= (others => '0');

									votedEpoch <= myEpoch;
									votedZxid  <= myZxid;
									syncFrom   <= myPeerId;

									if (myPeerId = nextLeaderId) then
										-- we wait...
										voteCount <= (others => '0');
									else
										-- now we send our epoch to the proposed leader
										myState    <= ST_PROP_LEADER;
										inCmdReady <= '0';
									end if;
								end if;

							end if;

						end if;

					---------------------------------------------------------------------
					-- HANDLE OP: perform changes to the state depending on the opcode
					---------------------------------------------------------------------
					when ST_HANDLEOP =>
						case (conv_integer(inCmdOpCode(CMD_TYPE_LEN - 1 downto 0))) is

							-- SETUP PEER
							when (OPCODE_SETUPPEER) =>
								myPeerId <= inCmdPeerId;

								myEpoch    <= (others => '0');
								myEpoch(0) <= '1';

								myIPAddr <= inCmdEpoch;
								myZxid   <= inCmdZxid;

								myState    <= ST_WAITOP;
								inCmdReady <= '1';

								if (myRole /= ROLE_UNKNOWN and myPhase = PH_STARTUP and peerCount /= 0) then
									myPhase <= PH_NORMAL;
								end if;

							-- SET OWN OR OTHER's ROLE
							when (OPCODE_SETLEADER) =>
								if (inCmdPeerId = myPeerId) then
									prevRole     <= myRole;
									myRole       <= ROLE_LEADER;
									proposedZxid <= myZxid;
									leaderPeerId <= inCmdPeerId;
									if (inCmdPeerId < peerCount) then
										nextLeaderId <= inCmdPeerId + 1;
									else
										nextLeaderId    <= (others => '0');
										nextLeaderId(0) <= '1';
									end if;

								else
									prevRole <= myRole;
									myRole   <= ROLE_FOLLOWER;

									leaderPeerId <= inCmdPeerId;

									if (inCmdPeerId < peerCount) then
										nextLeaderId <= inCmdPeerId + 1;
									else
										nextLeaderId    <= (others => '0');
										nextLeaderId(0) <= '1';
									end if;

								end if;

								myState    <= ST_WAITOP;
								inCmdReady <= '1';

								if (myPeerId /= 0 and myPhase = PH_STARTUP and peerCount /= 0) then
									myPhase <= PH_NORMAL;
								end if;

							-- ADD PEER (init connection)
							when (OPCODE_ADDPEER) =>
								if (peerIP((conv_integer(inCmdPeerId))) = 0) then
									if (inCmdZxid(31 downto 0) /= 0) then
										myState    <= ST_OPENTCPCONN;
										inCmdReady <= '0';
									else

										-- this is a parallel connection, we just need to remember
										-- which port it is
										peerSessId((conv_integer(inCmdPeerId))) <= "1" & inCmdEpoch(14 downto 0);

										myState    <= ST_WAITOP;
										inCmdReady <= '1';
									end if;

									if (peerSessId((conv_integer(inCmdPeerId))) = 0) then
										peerCount          <= peerCount + 1;
										peerCountForCommit <= peerCount + 2; -- adding two because peercount doesn't include myself
									end if;

									peerIP((conv_integer(inCmdPeerId))) <= inCmdZxid(15 downto 0) & inCmdEpoch;

									connToWaiting   <= '0';
									connToIpAddress <= inCmdEpoch;
									connToPort      <= inCmdZxid(15 downto 0);
									connToPeerId    <= inCmdPeerId;

								else
									error_valid  <= '1';
									error_opcode <= inCmdOpCode;
								end if;

							when (OPCODE_WRITEREQ) =>
								log_add_valid <= '1';
								log_add_zxid  <= proposedZxid + 1;
								log_add_size  <= inCmdPayloadSize;

								sendPayloadSize <= inCmdPayloadSize;
								sendEpoch       <= myEpoch;
								sendZxid        <= proposedZxid + 1;
								sendOpcode      <= std_logic_vector(conv_unsigned(OPCODE_PROPOSAL, 8));

								returnState <= ST_FINISH_WRITEREQ;

								myState    <= ST_SENDTOALL;
								inCmdReady <= '0';
								sendCount  <= (others => '0');

							when (OPCODE_PROPOSAL) =>
								if (cmd_out_ready = '1') then
									log_add_valid <= '1';
									log_add_zxid  <= inCmdZxid;
									log_add_size  <= inCmdPayloadSize;

									myZxid <= inCmdZxid;

									cmd_out_valid                                                                 <= '1';
									cmd_out_data(CMD_PAYLSIZE_LOC + CMD_PAYLSIZE_LEN - 1 downto CMD_PAYLSIZE_LOC) <= (others => '0');
									cmd_out_data(CMD_TYPE_LEN + CMD_TYPE_LOC - 1 downto CMD_TYPE_LOC)             <= std_logic_vector(conv_unsigned(OPCODE_ACKPROPOSE, 8));
									cmd_out_data(CMD_EPOCH_LOC + CMD_EPOCH_LEN - 1 downto CMD_EPOCH_LOC)          <= inCmdEpoch;
									cmd_out_data(CMD_ZXID_LOC + CMD_ZXID_LEN - 1 downto CMD_ZXID_LOC)             <= inCmdZxid;
									cmd_out_data(CMD_PEERID_LEN + CMD_PEERID_LOC - 1 downto CMD_PEERID_LOC)       <= myPeerId;
									cmd_out_data(CMD_SESSID_LOC + CMD_SESSID_LEN - 1 downto CMD_SESSID_LOC)       <= peerSessId(conv_integer(leaderPeerId)); --inCmdSessID;

									myState    <= ST_WAITOP;
									inCmdReady <= '1';
								end if;

							when (OPCODE_SYNCRESP) =>
								syncReqTimeout <= (others => '0');

								log_add_valid <= '1';
								log_add_zxid  <= inCmdZxid;
								log_add_size  <= inCmdPayloadSize;

								myZxid <= inCmdZxid;

								myState    <= ST_WAITOP;
								inCmdReady <= '1';

							when (OPCODE_SYNCDRAM) =>

								if (inCmdPayloadSize/=0) then 									
									log_add_valid <= '1';								
									log_add_size  <= inCmdPayloadSize;

									if (inCmdEpoch>=DRAM0_UPPERBOUND) then
										log_add_zxid  <= inCmdEpoch - DRAM0_UPPERBOUND;
									else 
										log_add_zxid <= inCmdEpoch;
									end if;

									myZxid <= inCmdZxid;

									
								end if;

								if (inCmdEpoch=DRAM0_UPPERBOUND-8) then
									myState    <= ST_SYNC_SWITCHMEM;
								else 

									if ((inCmdEpoch) >= DRAM0_UPPERBOUND+DRAM1_UPPERBOUND-8) then
										myZxid   <= inCmdZxid;
										myState    <= ST_SYNC_SWITCHOFF;	      
							    	else 
										myState    <= ST_WAITOP;
										inCmdReady <= '1';
									end if;
								end if;

							when (OPCODE_COMMIT) =>
								if (log_found_valid = '1') then
									foundInLog <= '1';
								end if;

								if ((foundInLog = '1' or log_found_valid = '1') and cmdSent = '0') then
									read_valid             <= '1';
									read_cmd(39 downto 0)  <= logFoundSizeP1(10 downto 3) & log_found_pos;
									read_cmd(63 downto 40) <= "000000000000000100000001";

									cmd_out_valid                                                                 <= '1';
									cmd_out_data(CMD_PAYLSIZE_LOC + CMD_PAYLSIZE_LEN - 1 downto CMD_PAYLSIZE_LOC) <= log_found_size;
									cmd_out_data(CMD_TYPE_LEN + CMD_TYPE_LOC - 1 downto CMD_TYPE_LOC)             <= (others => '0');
									cmd_out_data(CMD_EPOCH_LOC + CMD_EPOCH_LEN - 1 downto CMD_EPOCH_LOC)          <= myEpoch;
									cmd_out_data(CMD_ZXID_LOC + CMD_ZXID_LEN - 1 downto CMD_ZXID_LOC)             <= inCmdZxid;
									cmd_out_data(CMD_PEERID_LEN + CMD_PEERID_LOC - 1 downto CMD_PEERID_LOC)       <= myPeerId;
									cmd_out_data(CMD_SESSID_LOC + CMD_SESSID_LEN - 1 downto CMD_SESSID_LOC)       <= (others => '1');
									-- we need this to route the request to the app logic
									cmd_out_data(CMD_SESSID_LOC + CMD_SESSID_LEN - 1)                             <= '0';
									cmdSent                                                                       <= '1';

								end if;

								if (foundInLog = '1' and read_ready = '1' and cmd_out_ready = '1') then
									foundInLog <= '0';
									myState    <= ST_WAITOP;
									inCmdReady <= '1';
									cmdSent    <= '0';
								end if;

							when (OPCODE_ACKPROPOSE) =>

								--this is the dfault behavior...
								myState    <= ST_WAITOP;
								inCmdReady <= '1';

								if (thisPeersAckedZxid + 1 = inCmdZxid) then
									peerZxidAck(conv_integer(inCmdPeerId)) <= inCmdZxid;

									if (thisPeersCmtdZxid = thisPeersAckedZxid) then
										-- this means that we did not send them the commit for
										-- this zxid yet

										loopIteration       <= peerCount + 1;
										cmdForParallelValid <= '0';
										cmdForParallelData  <= (others => '0');

										quorumIteration <= peerCount + 1;
										commitableCount <= (others => '0');
										myState         <= ST_CHKQRM_ACKS;
										inCmdReady      <= '0';
									end if;

								else
									error_valid  <= '1';
									error_opcode <= "1000" & inCmdOpCode(3 downto 0);
								end if;

							when (OPCODE_ACKEPOCH) =>
								myState    <= ST_WAITOP;
								inCmdReady <= '1';

								if (myRole = ROLE_LEADER and myPhase = PH_SYNC) then
									if (syncFrom = inCmdPeerId_I) then
										myState    <= ST_SYNC_ELECTION;
										inCmdReady <= '0';
									else
										if (syncFrom = myPeerId) then
											myPhase         <= PH_NORMAL;
											myEpoch         <= votedEpoch;
											leaderPeerId    <= myPeerId;
											proposedZxid    <= votedZxid;
											silenceMeasured <= '0';
										end if;
									end if;
								end if;

								if (myRole = ROLE_LEADER and myPhase = PH_ELECTION) then
									myPhase      <= PH_NORMAL;
									myEpoch      <= votedEpoch;
									leaderPeerId <= myPeerId;
									proposedZxid <= votedZxid;
								end if;

								if (myRole = ROLE_LEADER) then
									if (peerZxidAck(conv_integer(inCmdPeerId)) <= votedZxid) then
										peerZxidAck(conv_integer(inCmdPeerId)) <= votedZxid;
										peerZxidCmt(conv_integer(inCmdPeerId)) <= votedZxid;
									end if;
								else
									error_valid  <= '1';
									error_opcode <= inCmdOpCode(7 downto 0);
								end if;

							when (OPCODE_SYNCLEADER) =>
								log_add_valid <= '1';
								log_add_zxid  <= inCmdZxid + 1;
								log_add_size  <= inCmdPayloadSize;

								inCmdReady <= '1';
								myState    <= ST_WAITOP;

							-- UNKNOWN/UNHANDLED OP CODE
							when others =>
								error_valid  <= '1';
								error_opcode <= "1000" & inCmdOpCode(3 downto 0);

						end case;

					----------------------------------------------------------------------
					-- OPEN CONNECTION
					----------------------------------------------------------------------
					when ST_OPENTCPCONN =>
						open_conn_req_valid <= '0';
						traceLoc            <= "00010010";
						if (open_conn_req_ready = '1' and connToWaiting = '0') then
							open_conn_req_valid <= '1';
							open_conn_req_data  <= connToPort(15 downto 0) & connToIpAddress;

							connToWaiting <= '1';
						end if;

						if (connToWaiting = '1' and open_conn_resp_valid = '1') then
							myState    <= ST_WAITOP;
							inCmdReady <= '1';

							if (open_conn_resp_data(16) = '1') then
								peerSessId((conv_integer(connToPeerId))) <= open_conn_resp_data(15 downto 0);

							else
								error_valid  <= '1';
								error_opcode <= inCmdOpCode;
							end if;
						end if;

					---------------------------------------------------------------------
					-- SEND MSG TO ALL PEERS
					---------------------------------------------------------------------
					when ST_SENDTOALL =>
						traceLoc <= "00010011";
						if (cmd_out_ready = '1') then
							if (myPeerId /= loopIteration and loopIteration /= 0 and sendEnableMask(conv_integer(loopIteration)) = '1') then
								if (peerIP(conv_integer(loopIteration)) /= 0) then
									-- if this peer exists

									--if (peerIP(conv_integer(loopIteration))(31 downto 24)/=0) then
									-- the highest byte is non-zero, this is a proper IP. use TCP
									sendCount                                                                     <= sendCount + 1;
									cmd_out_valid                                                                 <= '1';
									cmd_out_data(CMD_PAYLSIZE_LOC + CMD_PAYLSIZE_LEN - 1 downto CMD_PAYLSIZE_LOC) <= sendPayloadSize;
									cmd_out_data(CMD_TYPE_LEN + CMD_TYPE_LOC - 1 downto CMD_TYPE_LOC)             <= sendOpcode;
									cmd_out_data(CMD_EPOCH_LOC + CMD_EPOCH_LEN - 1 downto CMD_EPOCH_LOC)          <= sendEpoch;
									cmd_out_data(CMD_ZXID_LOC + CMD_ZXID_LEN - 1 downto CMD_ZXID_LOC)             <= sendZxid;
									cmd_out_data(CMD_PEERID_LEN + CMD_PEERID_LOC - 1 downto CMD_PEERID_LOC)       <= myPeerId;
									cmd_out_data(CMD_SESSID_LOC + CMD_SESSID_LEN - 1 downto CMD_SESSID_LOC)       <= peerSessId(conv_integer(loopIteration));

								--			else
								--				-- this is a parallel-interface
								--				cmdForParallelValid <= '1';
								--				cmdForParallelData(CMD_PAYLSIZE_LOC+CMD_PAYLSIZE_LEN-1 downto CMD_PAYLSIZE_LOC) <= sendPayloadSize;
								--				cmd_out_data(CMD_TYPE_LEN+CMD_TYPE_LOC-1 downto CMD_TYPE_LOC) <= sendOpcode;
								--				cmdForParallelData(CMD_EPOCH_LOC+CMD_EPOCH_LEN-1 downto CMD_EPOCH_LOC) <= sendEpoch;
								--				cmdForParallelData(CMD_ZXID_LOC+CMD_ZXID_LEN-1 downto CMD_ZXID_LOC) <= sendZxid;
								--				cmdForParallelData(CMD_PEERID_LEN+CMD_PEERID_LOC-1 downto CMD_PEERID_LOC) <= myPeerId;
								--				cmdForParallelData(CMD_SESSID_LOC+CMD_SESSID_LEN-1 downto CMD_SESSID_LOC) <= cmdForParallelData(CMD_SESSID_LOC+CMD_SESSID_LEN-1 downto CMD_SESSID_LOC) or peerSessId(conv_integer(loopIteration));

								--			end if;


								end if;
							end if;

							if (loopIteration /= 0) then
								loopIteration <= loopIteration - 1;
							end if;

							if (loopIteration = 0 and cmd_out_ready = '1') then
								if (cmdForParallelValid = '0') then
									myState    <= returnState;
									inCmdReady <= '0';

									if (returnState = ST_WAITOP) then
										inCmdReady <= '1';
									end if;
								else
									sendCount           <= sendCount + 1;
									cmd_out_valid       <= cmdForParallelValid;
									cmd_out_data        <= cmdForParallelData;
									cmdForParallelValid <= '0';
								end if;
							end if;

						end if;

					-----------------------------------------------------------------------
					-- FINISH PROPOSAL SENDING
					-----------------------------------------------------------------------
					when ST_FINISH_WRITEREQ =>
						traceLoc <= "00010100";
						if (sendCount = 1 and read_ready = '1') then
							proposedZxid <= proposedZxid + 1;
							myState      <= ST_WAITOP;
							inCmdReady   <= '1';

							sessMemEnable   <= '1';
							sessMemWrite(0) <= '1';
							sessMemAddr     <= sendZxid(MAX_OUTSTANDING_REQS_BITS - 1 downto 0);
							sessMemDataIn   <= receiveTime(15 downto 0) & sendZxid(15 downto 0) & inCmdSessID(15 downto 0);

						--			clientReqZxid(ieee.numeric_std.to_integer(ieee.numeric_std.unsigned(sendZxid(MAX_OUTSTANDING_REQS_BITS-1 downto 0)))) <= sendZxid(15 downto 0);
						--			clientReqSess(ieee.numeric_std.to_integer(ieee.numeric_std.unsigned(sendZxid(MAX_OUTSTANDING_REQS_BITS-1 downto 0)))) <= inCmdSessID(15 downto 0);

						end if;

						if (read_ready = '1') then
							sendCount <= sendCount - 1;

							read_cmd(39 downto 0)  <= inCmdPayloadSizeP1(10 downto 3) & logHeadLoc;
							read_cmd(63 downto 40) <= "000000000000000100000001";
							read_valid             <= '1';

						end if;

					-----------------------------------------------------------------------
					-- FINISH COMMIT SENDING
					-----------------------------------------------------------------------
					when ST_FINISH_COMMIT =>
						--if (cmd_out_ready='1') then
						traceLoc <= "00010101";
						if (sessMemEnable = '0' and sessMemEnableD1 = '0' and sessMemEnableD2 = '0') then
							sessMemEnable   <= '1';
							sessMemWrite(0) <= '0';
							sessMemAddr     <= inCmdZxid(MAX_OUTSTANDING_REQS_BITS - 1 downto 0);

							responseTime <= internalClk(15 downto 0);
						end if;

						if (sessMemEnableD2 = '1') then
							if (myZxid + 1 = inCmdZxid) then
								myZxid <= inCmdZxid;

								--	if (clientReqZxid(ieee.numeric_std.to_integer(ieee.numeric_std.unsigned(sendZxid(MAX_OUTSTANDING_REQS_BITS-1 downto 0))))=inCmdZxid(15 downto 0)) then
								--
								if (sessMemDataOut(31 downto 16) = inCmdZxid(15 downto 0)) then

									-- Removed becuase now that we have the app in there we want to get only 1 response.
									--cmd_out_valid <= '1';


									log_search_valid <= '1';
									log_search_since <= '0';
									log_search_zxid  <= inCmdZxid;
									cmdSent          <= '0';
									myState          <= ST_FINISH_COMMIT_DATAFORAPP;

								else
									error_valid   <= '1';
									error_opcode  <= (others => '1');
									cmd_out_valid <= '0';

									myState    <= ST_WAITOP;
									inCmdReady <= '1';
								end if;

							--			cmd_out_valid <= '0';
							--			cmd_out_data(CMD_PAYLSIZE_LOC+CMD_PAYLSIZE_LEN-1 downto CMD_PAYLSIZE_LOC) <= (others => '0');
							--			cmd_out_data(CMD_TYPE_LEN+CMD_TYPE_LOC-1 downto CMD_TYPE_LOC) <= (others => '0');
							--			cmd_out_data(CMD_EPOCH_LOC+CMD_EPOCH_LEN-1 downto CMD_EPOCH_LOC) <= responseTime & sessMemDataOut(47 downto 32);
							--			cmd_out_data(CMD_ZXID_LOC+CMD_ZXID_LEN-1 downto CMD_ZXID_LOC) <= inCmdZxid;
							--			cmd_out_data(CMD_PEERID_LEN+CMD_PEERID_LOC-1 downto CMD_PEERID_LOC) <= myPeerId;
							--			cmd_out_data(CMD_SESSID_LOC+CMD_SESSID_LEN-1 downto CMD_SESSID_LOC) <= sessMemDataOut(15 downto 0);
							--clientReqSess(ieee.numeric_std.to_integer(ieee.numeric_std.unsigned(sendZxid(MAX_OUTSTANDING_REQS_BITS-1 downto 0))));


							else
								error_valid  <= '1';
								error_opcode <= "0100" & inCmdOpCode(3 downto 0);

								myState    <= ST_WAITOP;
								inCmdReady <= '1';
							end if;

						end if;

					--end if;

					when ST_FINISH_COMMIT_DATAFORAPP =>
						traceLoc <= "00010110";
						if (log_found_valid = '1') then
							foundInLog <= '1';
						end if;

						if ((foundInLog = '1' or log_found_valid = '1') and cmdSent = '0') then
							read_valid             <= '1';
							read_cmd(39 downto 0)  <= logFoundSizeP1(10 downto 3) & log_found_pos;
							read_cmd(63 downto 40) <= "000000000000000100000001";

							cmd_out_valid                                                                 <= '1';
							cmd_out_data(CMD_PAYLSIZE_LOC + CMD_PAYLSIZE_LEN - 1 downto CMD_PAYLSIZE_LOC) <= log_found_size;
							cmd_out_data(CMD_TYPE_LEN + CMD_TYPE_LOC - 1 downto CMD_TYPE_LOC)             <= (others => '0');
							cmd_out_data(CMD_EPOCH_LOC + CMD_EPOCH_LEN - 1 downto CMD_EPOCH_LOC)          <= myEpoch; --sessMemDataOut(47 downto 32) & myEpoch(15 downto 0); -- RESPONSE TIME DEBUG
							cmd_out_data(CMD_ZXID_LOC + CMD_ZXID_LEN - 1 downto CMD_ZXID_LOC)             <= inCmdZxid;
							cmd_out_data(CMD_PEERID_LEN + CMD_PEERID_LOC - 1 downto CMD_PEERID_LOC)       <= myPeerId;
							cmd_out_data(CMD_SESSID_LOC + CMD_SESSID_LEN - 1 downto CMD_SESSID_LOC)       <= "01" & sessMemDataOut(13 downto 0);
							cmdSent                                                                       <= '1';

						end if;

						if (foundInLog = '1' and read_ready = '1' and cmd_out_ready = '1') then
							cmdSent    <= '0';
							foundInLog <= '0';
							myState    <= ST_WAITOP;
							inCmdReady <= '1';
						end if;

					when ST_FINISH_COMMIT_LATE =>
						myState    <= ST_WAITOP;
						inCmdReady <= '1';

					-----------------------------------------------------------------------
					-- CHECK QUORUM FOR ACKS
					-----------------------------------------------------------------------
					when ST_CHKQRM_ACKS =>
						traceLoc <= "00010111";
						if (quorumIteration = 0) then

							--for majority need to add 1 to the peercount to count				
							--ZSOLT
							if ((peerCount > 2 and commitableCountTimesTwo >= (peerCountForCommit)) or (peerCount < 3 and commitableCount >= peerCount) or (commitableCount = 1 and myZxid > inCmdZxid - 1)) then
								sendPayloadSize <= (others => '0');
								sendZxid        <= inCmdZxid;
								sendEpoch       <= inCmdEpoch;
								sendOpcode      <= std_logic_vector(conv_unsigned(OPCODE_COMMIT, 8));

								for X in 0 to MAX_PEERS loop
									if (sendEnableMask(X) = '1' and myPeerId /= X) then
										peerZxidCmt(X) <= inCmdZxid;
									end if;
								end loop;

								if (commitableCount = 1 and myZxid > inCmdZxid - 1) then
									returnState <= ST_FINISH_COMMIT_LATE;
								else
									returnState <= ST_FINISH_COMMIT;
								end if;
								myState    <= ST_SENDTOALL;
								inCmdReady <= '0';
								sendCount  <= (others => '0');
							else
								myState        <= ST_WAITOP;
								inCmdReady     <= '1';
								sendEnableMask <= (others => '1');
							end if;

						else
							quorumIteration <= quorumIteration - 1;

							if (myPeerId /= quorumIteration and quorumIteration /= 0) then
								if (peerIP(conv_integer(quorumIteration)) /= 0 and peerZxidAck(conv_integer(quorumIteration)) > (inCmdZxid - 1) and peerZxidCmt(conv_integer(quorumIteration)) = (inCmdZxid - 1)) then
									commitableCount <= commitableCount + 1;
								else
									sendEnableMask(conv_integer(quorumIteration)) <= '0';
								end if;
							else
								if (myPeerId = quorumIteration and myZxid = inCmdZxid - 1) then
									commitableCount <= commitableCount + 1;
								else
									sendEnableMask(conv_integer(quorumIteration)) <= '0';
								end if;
							end if;
						end if;

					when ST_WAIT_MEMWRITE =>
						traceLoc <= "00011000";
						if (write_ready = '1') then
							myState    <= returnState;
							inCmdReady <= '0';
						end if;

					when ST_REQUESTSYNC =>
						traceLoc <= "00011001";

						if (syncReqTimeout = 0) then
							cmd_out_valid                                                                 <= '1';
							cmd_out_data(CMD_PAYLSIZE_LOC + CMD_PAYLSIZE_LEN - 1 downto CMD_PAYLSIZE_LOC) <= (others => '0');
							cmd_out_data(CMD_TYPE_LEN + CMD_TYPE_LOC - 1 downto CMD_TYPE_LOC)             <= std_logic_vector(conv_unsigned(OPCODE_SYNCREQ, 8));
							cmd_out_data(CMD_EPOCH_LOC + CMD_EPOCH_LEN - 1 downto CMD_EPOCH_LOC)          <= myEpoch;
							cmd_out_data(CMD_ZXID_LOC + CMD_ZXID_LEN - 1 downto CMD_ZXID_LOC)             <= myZxid + 1;
							cmd_out_data(CMD_PEERID_LEN + CMD_PEERID_LOC - 1 downto CMD_PEERID_LOC)       <= myPeerId;
							cmd_out_data(CMD_SESSID_LOC + CMD_SESSID_LEN - 1 downto CMD_SESSID_LOC)       <= peerSessId(conv_integer(leaderPeerId)); --inCmdSessID;

							syncReqTimeout     <= (others => '0');
							syncReqTimeout(20) <= '1';
						end if;

						myState    <= ST_WAITOP;
						inCmdReady <= '1';

					when ST_GETLOGSYNC =>
						traceLoc         <= "00011010";
						log_search_valid <= '1';
						log_search_since <= '0';
						log_search_zxid  <= syncZxid;

						myState <= ST_SENDSYNC;

					when ST_SENDSYNC =>
						traceLoc <= "00011011";
						if (log_found_valid = '1') then
							foundInLog <= '1';
						end if;

						if ((foundInLog = '1' or log_found_valid = '1') and cmdSent = '0') then
							read_valid             <= '1';
							read_cmd(39 downto 0)  <= logFoundSizeP1(10 downto 3) & log_found_pos;
							read_cmd(63 downto 40) <= "000000000000000100000001";

							cmd_out_valid                                                                 <= '1';
							cmd_out_data(CMD_PAYLSIZE_LOC + CMD_PAYLSIZE_LEN - 1 downto CMD_PAYLSIZE_LOC) <= log_found_size;

							if (myRole = ROLE_LEADER) then
								if (syncZxid = proposedZxid) then
									cmd_out_data(CMD_TYPE_LEN + CMD_TYPE_LOC - 1 downto CMD_TYPE_LOC) <= std_logic_vector(conv_unsigned(OPCODE_PROPOSAL, 8));
								else
									cmd_out_data(CMD_TYPE_LEN + CMD_TYPE_LOC - 1 downto CMD_TYPE_LOC) <= std_logic_vector(conv_unsigned(OPCODE_SYNCRESP, 8));
								end if;
							else
								cmd_out_data(CMD_TYPE_LEN + CMD_TYPE_LOC - 1 downto CMD_TYPE_LOC) <= std_logic_vector(conv_unsigned(OPCODE_SYNCLEADER, 8));
							end if;

							cmd_out_data(CMD_EPOCH_LOC + CMD_EPOCH_LEN - 1 downto CMD_EPOCH_LOC)    <= myEpoch; -- RESPONSE TIME DEBUG
							cmd_out_data(CMD_ZXID_LOC + CMD_ZXID_LEN - 1 downto CMD_ZXID_LOC)       <= syncZxid;
							cmd_out_data(CMD_PEERID_LEN + CMD_PEERID_LOC - 1 downto CMD_PEERID_LOC) <= myPeerId;
							cmd_out_data(CMD_SESSID_LOC + CMD_SESSID_LEN - 1 downto CMD_SESSID_LOC) <= peerSessId(conv_integer(inCmdPeerId)); --inCmdSessID;
							cmdSent                                                                 <= '1';

						end if;

						if (foundInLog = '1' and read_ready = '1' and cmd_out_ready = '1') then
							cmdSent    <= '0';
							foundInLog <= '0';
							if (syncZxid >= proposedZxid) then
								myState    <= ST_WAITOP;
								inCmdReady <= '1';
							else
								myState                                <= ST_GETLOGSYNC;
								peerZxidAck(conv_integer(inCmdPeerId)) <= syncZxid;
								peerZxidCmt(conv_integer(inCmdPeerId)) <= syncZxid;
								syncZxid                               <= syncZxid + 1;
							end if;
						end if;

					when ST_SYNC_SWITCHMEM => 

						if (log_added_done='1') then

							syncMode <= "10"; -- this might have to be fixed with a delay!
							myState    <= ST_WAITOP;
							inCmdReady <= '1';
						end if;

					when ST_SYNC_SWITCHOFF => 

						if (log_added_done='1') then

							syncMode <= "00"; -- this might have to be fixed with a delay!

							cmd_out_valid                                                                 <= '1';
							cmd_out_data(CMD_PAYLSIZE_LOC + CMD_PAYLSIZE_LEN - 1 downto CMD_PAYLSIZE_LOC) <= (others => '0');
							cmd_out_data(CMD_TYPE_LEN + CMD_TYPE_LOC - 1 downto CMD_TYPE_LOC)             <= std_logic_vector(conv_unsigned(OPCODE_SYNCFINALACK, 8));
							cmd_out_data(CMD_EPOCH_LOC + CMD_EPOCH_LEN - 1 downto CMD_EPOCH_LOC)          <= myEpoch;
							cmd_out_data(CMD_ZXID_LOC + CMD_ZXID_LEN - 1 downto CMD_ZXID_LOC)             <= myZxid;
							cmd_out_data(CMD_PEERID_LEN + CMD_PEERID_LOC - 1 downto CMD_PEERID_LOC)       <= myPeerId;
							cmd_out_data(CMD_SESSID_LOC + CMD_SESSID_LEN - 1 downto CMD_SESSID_LOC)       <= peerSessId(conv_integer(leaderPeerId)); --inCmdSessID;

							myState    <= ST_WAITOP;
							inCmdReady <= '1';
						end if;

					when ST_PROP_LEADER =>
						traceLoc                                                                      <= "00011100";
						cmd_out_valid                                                                 <= '1';
						cmd_out_data(CMD_PAYLSIZE_LOC + CMD_PAYLSIZE_LEN - 1 downto CMD_PAYLSIZE_LOC) <= (others => '0');
						cmd_out_data(CMD_TYPE_LEN + CMD_TYPE_LOC - 1 downto CMD_TYPE_LOC)             <= std_logic_vector(conv_unsigned(OPCODE_CUREPOCH, 8));
						cmd_out_data(CMD_EPOCH_LOC + CMD_EPOCH_LEN - 1 downto CMD_EPOCH_LOC)          <= myEpoch + 1;
						cmd_out_data(CMD_ZXID_LOC + CMD_ZXID_LEN - 1 downto CMD_ZXID_LOC)             <= myZxid;
						cmd_out_data(CMD_PEERID_LEN + CMD_PEERID_LOC - 1 downto CMD_PEERID_LOC)       <= myPeerId;
						cmd_out_data(CMD_SESSID_LOC + CMD_SESSID_LEN - 1 downto CMD_SESSID_LOC)       <= peerSessId(conv_integer(nextLeaderId));

						sinceHeardFromLeader <= (others => '0'); -- we zero the clock to
						-- make sure we give it
						-- enough time to answer...
						myState              <= ST_WAITOP;
						inCmdReady           <= '1';

					when ST_SENDNEWEPOCH =>
						traceLoc        <= "00011101";
						sendPayloadSize <= (others => '0');
						sendEpoch       <= votedEpoch;
						sendZxid        <= votedZxid;
						sendOpcode      <= std_logic_vector(conv_unsigned(OPCODE_NEWEPOCH, 8));
						myState         <= ST_SENDTOALL;
						inCmdReady      <= '0';
						sendCount       <= (others => '0');
						loopIteration   <= peercount + 1;
						prevRole        <= myRole;
						myRole          <= ROLE_LEADER;
						proposedZxid    <= myZxid;

						myPhase <= PH_SYNC;

						returnState <= ST_WAITOP;

					when ST_SENDNEWEPOCH_JOIN =>
						traceLoc                                                                      <= "00011110";
						cmd_out_valid                                                                 <= '1';
						cmd_out_data(CMD_PAYLSIZE_LOC + CMD_PAYLSIZE_LEN - 1 downto CMD_PAYLSIZE_LOC) <= (others => '0');
						cmd_out_data(CMD_TYPE_LEN + CMD_TYPE_LOC - 1 downto CMD_TYPE_LOC)             <= std_logic_vector(conv_unsigned(OPCODE_NEWEPOCH, 8));
						cmd_out_data(CMD_EPOCH_LOC + CMD_EPOCH_LEN - 1 downto CMD_EPOCH_LOC)          <= myEpoch;
						cmd_out_data(CMD_ZXID_LOC + CMD_ZXID_LEN - 1 downto CMD_ZXID_LOC)             <= myZxid;
						cmd_out_data(CMD_PEERID_LEN + CMD_PEERID_LOC - 1 downto CMD_PEERID_LOC)       <= myPeerId;
						cmd_out_data(CMD_SESSID_LOC + CMD_SESSID_LEN - 1 downto CMD_SESSID_LOC)       <= peerSessId(conv_integer(inCmdPeerId));

						myState    <= ST_WAITOP;
						inCmdReady <= '1';

					when ST_SAYWHOISLEADER =>
						traceLoc                                                                      <= "00011111";
						cmd_out_valid                                                                 <= '1';
						cmd_out_data(CMD_PAYLSIZE_LOC + CMD_PAYLSIZE_LEN - 1 downto CMD_PAYLSIZE_LOC) <= (others => '0');
						cmd_out_data(CMD_TYPE_LEN + CMD_TYPE_LOC - 1 downto CMD_TYPE_LOC)             <= std_logic_vector(conv_unsigned(OPCODE_SETLEADER, 8));
						cmd_out_data(CMD_EPOCH_LOC + CMD_EPOCH_LEN - 1 downto CMD_EPOCH_LOC)          <= (others => '0');
						cmd_out_data(CMD_ZXID_LOC + CMD_ZXID_LEN - 1 downto CMD_ZXID_LOC)             <= (others => '0');
						cmd_out_data(CMD_PEERID_LEN + CMD_PEERID_LOC - 1 downto CMD_PEERID_LOC)       <= leaderPeerId;
						cmd_out_data(CMD_SESSID_LOC + CMD_SESSID_LEN - 1 downto CMD_SESSID_LOC)       <= peerSessId(conv_integer(inCmdPeerId));

						myState    <= ST_WAITOP;
						inCmdReady <= '1';

					when ST_SYNC_ELECTION =>
						traceLoc <= "00100000";
						myEpoch  <= votedEpoch;
						if (votedZxid > myZxid) then
							cmd_out_valid                                                                 <= '1';
							cmd_out_data(CMD_PAYLSIZE_LOC + CMD_PAYLSIZE_LEN - 1 downto CMD_PAYLSIZE_LOC) <= (others => '0');
							cmd_out_data(CMD_TYPE_LEN + CMD_TYPE_LOC - 1 downto CMD_TYPE_LOC)             <= std_logic_vector(conv_unsigned(OPCODE_SYNCREQ, 8));
							cmd_out_data(CMD_EPOCH_LOC + CMD_EPOCH_LEN - 1 downto CMD_EPOCH_LOC)          <= myEpoch;
							cmd_out_data(CMD_ZXID_LOC + CMD_ZXID_LEN - 1 downto CMD_ZXID_LOC)             <= votedZxid;
							cmd_out_data(CMD_PEERID_LEN + CMD_PEERID_LOC - 1 downto CMD_PEERID_LOC)       <= myPeerId;
							cmd_out_data(CMD_SESSID_LOC + CMD_SESSID_LEN - 1 downto CMD_SESSID_LOC)       <= peerSessId(conv_integer(inCmdPeerId));
						else
							prevRole     <= myRole;
							myRole       <= ROLE_LEADER;
							proposedZxid <= myZxid;
							myPhase      <= PH_NORMAL;

						end if;
						myState    <= ST_WAITOP;
						inCmdReady <= '1';

					when ST_DRAMSYNC =>
						traceLoc <= syncDramAddress(13 downto 6);

						if (syncMode > 0) then
							cmdSent <= '0';

							if (cmdSent = '0' and read_ready = '1' and cmd_out_ready='1') then
								if ((totalSyncWordsSent&"000") < htSyncSize) then
								
									if (syncMode="01" and syncDramAddress = DRAM0_UPPERBOUND) then
										if (sync_noinflight='1') then
											syncMode <= "10";
										end if;
									else

										read_valid             <= '1';
										if (syncMode="01") then 
											read_cmd(39 downto 0)  <= "00001000" & syncDramAddress;
										else
											read_cmd(39 downto 0)  <= "00001000" & (syncDramAddress - DRAM0_UPPERBOUND);
										end if;				
										read_cmd(63 downto 40) <= "000000000000000100000001";

										cmd_out_valid                                                                 <= '1';
										cmd_out_data(CMD_PAYLSIZE_LOC + CMD_PAYLSIZE_LEN - 1 downto CMD_PAYLSIZE_LOC) <= "00000000" & "00000000" & "00000000" & "01000000";

										cmd_out_data(CMD_TYPE_LEN + CMD_TYPE_LOC - 1 downto CMD_TYPE_LOC) <= std_logic_vector(conv_unsigned(OPCODE_SYNCDRAM, 8));

										cmd_out_data(CMD_EPOCH_LOC + CMD_EPOCH_LEN - 1 downto CMD_EPOCH_LOC)    <= syncDramAddress; -- RESPONSE TIME DEBUG
										cmd_out_data(CMD_ZXID_LOC + CMD_ZXID_LEN - 1 downto CMD_ZXID_LOC)       <= myZxid;
										cmd_out_data(CMD_PEERID_LEN + CMD_PEERID_LOC - 1 downto CMD_PEERID_LOC) <= myPeerId;
										cmd_out_data(CMD_SESSID_LOC + CMD_SESSID_LEN - 1 downto CMD_SESSID_LOC) <= peerSessId(conv_integer(syncPeerId));
										cmdSent                                                                 <= '1';

										syncDramAddress <= syncDramAddress + 8;
										totalSyncWordsSent <= totalSyncWordsSent + 8;
										syncModeWaited  <= (others => '0');

									end if;

								else
									if (syncModeWaited > 128) then
										syncMode                              <= "00";
										syncPrepare                           <= '0';
										myState                               <= ST_WAITOP;
										inCmdReady                            <= '1';
										peerZxidAck(conv_integer(syncPeerId)) <= myZxid;
										peerZxidCmt(conv_integer(syncPeerId)) <= myZxid;
									end if;

								end if;
							end if;
						end if;

					when others =>
				end case;

			end if;

		end if;

	end process;

	debug_out(31 + 8 * 8 downto 0) <= sinceHeardFromLeader(31 downto 0) & myEpoch(7 downto 0) & myZxid(7 downto 0) & votedEpoch(7 downto 0) & votedZxid(7 downto 0) & syncFrom(7 downto 0) & leaderPeerId(7 downto 0) & proposedZxid(7 downto 0) & traceLoc(7 downto 0);

	debug_out(111 downto 96) <= (others => '0');

	debug_out(127 downto 124) <= "0001" when myPhase = PH_NORMAL else "1111";
	debug_out(123 downto 120) <= "0001" when myPhase = PH_ELECTION else "1111";

	debug_out(119 downto 116) <= "0010" when myRole = ROLE_LEADER else "1111";
	debug_out(115 downto 114) <= "10" when myRole = ROLE_FOLLOWER else "11";
	debug_out(113)            <= '1' when syncMode > 0 else '0';
	debug_out(112)            <= '1' when syncPrepare = '1' else '0';

	sessmem : zk_blkmem_32x1024
		port map(
			clka  => clk,
			--ena => sessMemEnable,
			wea   => sessMemWrite,
			addra => sessMemAddr,
			dina  => sessMemDataIn,
			douta => sessMemDataOut
		);

end beh;
