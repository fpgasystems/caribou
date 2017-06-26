Booting
=======

### Flushing

Caribou can be used in two different modes (or a mix of these): replicated or node-local.
Regardless of the use, after programming the FPGA it needs to be reset (essentially a flush command to each FPGA):

	echo -n 'FFFF000001000108F00BA20000000000f00f00f00f00f00f' | xxd -r -p | nc $FPGAIP_0 2888 -q 2 
	echo -n 'FFFF000001000108F00BA20000000000f00f00f00f00f00f' | xxd -r -p | nc $FPGAIP_1 2888 -q 2 
	echo -n 'FFFF000001000108F00BA20000000000f00f00f00f00f00f' | xxd -r -p | nc $FPGAIP_2 2888 -q 2 
	...

Once this has been done, the FPGA is ready to serve get/put requests or to have the Zookeeper Atomic Broadcast subsystem configured.

### Initial ZAB config

Nodes need to be told that they will participate in the replication group and who the first leader is. This can be done either "manually" using a script, or with the code in the /src/ClusterManagement project running the CommandLineInterface class:
	
	CommandLineInterface $FPGAIP_0:2888;$FPGAIP_1:2888;$FPGAIP_2:2888

To add nodes later, run the same class with the original group as first argument, and the additional node as second argument:

	CommandLineInterface $FPGAIP_0:2888;$FPGAIP_1:2888;$FPGAIP_2:2888 $FPGAIP_new:2888	


Sendind requests
================

In the current setup there are two ways to execute commands on Caribou. 

### Replicated 

From the client's perspective the only important operation is "replicated set" that will replicate the given key and value to all nodes. (Other operations and their code can be found in zk_control_CentralSM.vhdl.)

These operations are formatted as follows:

	FFFFxxCCPPPP0000
	EEEEEEEEEEEEEEEE
	KKKKKKKKKKKKKKKK
	LLLLVVVVVVVVVVVV
	...
	VVVVVVVVVVVVVVVV

Legend: 

* x [1B] = reserved to encode node id
* C [1B] = opcode of the operation
* P [2B] = payload (key + value) size in 64bit words. E.g. 4=4*64bit
* E [8B] = reserved to encode epoch, zxid
* K [64B] = key
* L [2B] = length of value (including these two bytes) in bytes
* V [variable] = value (if no value is needed for the operation, stop at K)


### Node-local

To perform operations that are local to the node, we use a similar format of the packets as above, but with extra information in bytes 4-7 (see nukv_ht_write_v2.v for opcodes):

	FFFF0000PPPPkkQQ
	0000000000000000
	KKKKKKKKKKKKKKKK
	LLLLVVVVVVVVVVVV
	...
	VVVVVVVVVVVVVVVV

* P [2B] = payload (key + value) size in 64bit words. E.g. 4=4*64bit
* k [1B] = length of key in 64 bit words (can be 01 or 02).
* Q [1B] = node-local command code
* K [64B/128B] = key
* L [2B] = length of value (including these two bytes) in bytes
* V [variable] = value (if no value is needed for the operation, stop at K)

In-code examples of these operations can be found in the Go client in /src/

### Go Client

To populate run:

	./caribou -host "$LEADER_IP:2888" -populate -time 120 (-replicate) (-flush)

To do some mixed ops (50% writes) for 10 seconds

	./caribou -host "$LEADER_IP:2888" -setp 0.5 -time 10

...
