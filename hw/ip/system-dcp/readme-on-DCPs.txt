All these DCPs originate from 
https://github.com/fpgasystems/fpga-network-stack

The DCP used for the SmartCam is available in two versions. The plain one, which is actually over-sized for the current deployment of the TCP stack (it can hold 10k entries instead of 2k needed for the networking stack). We provide an experimental scaled-down version of the SmartCam as well, to help with meeting timing in larger designs.  
