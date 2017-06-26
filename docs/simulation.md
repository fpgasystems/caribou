Simulation
----------

**We used Model Technology ModelSim SE-64 vsim 10.1c for simulation. Newer versions should also work. Vivado's simulator also works, but was significantly slower to start up.**

We simulated extensively, so there is a relatively easy way of "faking" network input to the Consensus logic and the KVS. The simulation files do not include the network module or the DRAM controller though.

There is a simulation toplevel (zk_toplevel_nukv_TB) that reads "network" input from a file. It is actually one file for simulating "data received events" and one for the actual data. These can be found in the ./docs/simulation-input folder. There is an input file for a node that would be leader, and one for follower.

The file format for the data input is as follows:

	wwww
	0000
	Ldddddddddddddddd
	[wwww] or [L....]


* wwww [2B] = number of clock cycles to wait before proceeding with reading the input
* L [4bit] = TLAST of the packet. Should be 0 all the way, except for the last data word before a wait block. Requests can be split across network packets or a single network packet can have multiple requests.
* ddd... [8B] = one network data line (64 bit)

The above format is similar for the event file, except that 'L' is always 0.