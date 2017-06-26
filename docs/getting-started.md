SW Environment and Setup
========================

To build Caribou we used Ubuntu 14.04LTS. 

The IDEs and tools are as follows:
* Vivado 2014.3
* Modelsim SE-64 10.1c
* ChipScope Analyzer 14.7
* Java 1.7
* Golang 1.6

**While everything might work with newer versions of the tools, we have not tested it (especially IP core major version could have changed in newer versions of Vivado).**

The source code is organized in the following way:

	./hw 
	    /src -- actual source code of Caribou (toplevel file = zookeeper_nkv_fpga_para.v, toplevel for simulation = zk_toplevel_nukv_TB.vhd)
	    /ip -- IP cores and various DCPs
	    /constraints -- XDC constraint to use with the project
	./sw -- software clients
	    /ClusterManagement -- Java code to initialize/modify zookeeper groups
	    /client-scan-demo -- Client written in Go to showcase the scan feature, but not only


HW Environment and Setup
========================

Boards
------

To build and test Caribou we used the Xilinx VC709 evaluation boards (Virtex-7 VX690T). 

While we have included DCPs (binaries) for the DDR3 memory controller, SmartCam for network sessions and the TCP/IP implementation, please visit the repository below for more up to date versions:
https://github.com/fpgasystems/fpga-network-stack

The code is fairly easily portable to the Alpha Data ADM-PCIE-7V3 board, and binaries for the memory controller and XDC constraints should be available at the previously mentioned address.

Network setup
-------------

By default the boards have an IP address of 10.1.212.209 and the first and last byte can be incremented with up to 16 based on switches on the device (see picture).

In the provided code all network traffic happens through interface no.0 of the boards, so these have to be connected to the switch or to an other 10Gbps NIC in a machine. We used a 10Gbps Switch (Intel 82599ES). 


Contact
=======
For questions about Caribou please feel free to email Zsolt (zsolt.istvan@inf.ethz.ch)


