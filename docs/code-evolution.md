A word on replacing modules
---------------------------

The project is fairly modular, so it should be relatively easy to swap out modules. In the following I will outline the most obvious options for "tweaking":

* If you want to change the key-value store implementation it should be easy because all functionality is encapsulated in a single wrapper (nukv_Top_Module_v2). The interfaces are simple, the only tricky part might be handling the different opcodes coming in.

* It is possible to modify the near-data processing by removing the modules from between nukv_Value_Set and nukv_Value_Get, and adding your own. Ideally there should be a single "drop" bit that gets passed on to the Value_Get module to indicate if data has not matched the filter and therefor should be dropped.

* Playing around with the consensus logic is also possible, just replace the files prefixed with zk_control. These implement the actual decisions. If you want to change headers, etc., the zk_data modules will need adjustments as well.

* Other networking stack than TCP. Even though the atomic broadcast requires ordered reliable transport (in essence TCP) to function correctly, it is possible to introduce your own module instead of the TCP stack we have. The consensus logic and KVS will make very few assumptions about the networking protocol: 1) for requests coming from clients they will send a response on the same socket (on the same socket-ID that has been provided to the logic by the TCP stack), 2) to send messages between FPGAs, the consensus logic will use "mono-directional" sockets, that each of them open to all other nodes. The socket-ID of this connection will be saved inside the consensus logic and is assumed to stay valid unless the FPGA on the other end "dies".


Differences to published papers
-------------------------------

The code in this repository differs slightly from the system presented in the VLDB17 paper. Some of the pipeline stages have been rewritten for clarity or to remove bugs (mostly the files with _v2 marking).

* Insert acts as both Insert and Replace in the KVS.

* The log of the replication engine has been moved to BRAM instead of DRAM. This has no impact on performance or correctness, but should help to meet timing in Vivado project without any tweaks.
The memory holding the log and the log header entries can be sized to hold several thousand requests. Beyond these recovery is done as a bulk-copy of the hash table and bitmap state. While this is sub-optimal in terms of recovery time, it should provide the needed functionality. 

* The relative sizes of different data structures are different. See the code for the bit-width of addresses to each portion of the memory.

* This version of the memory allocator uses a single tablespace in the bitmaps (but making it parameterizable for multiple tablespaces again should be straightforward). 

* The regular expression matchers have been moved to a faster clock domain (312MHz), thus there number can be halved and still achieve the same bandwidth.

Known issues / limitations
--------------------------

* In the current version of the code (June 2017) there is a mix between ZAB opcodes and KVS opcodes. Most notably, the ZAB write request will map internally to a KVS Insert when successfully replicated. At this point deletes, etc., have to be done "outside" the replication logic. This is a momentary limitation and originates from the fac tthat we re-use some parts of the header for both parts of the logic. In the future the KVS code shall be held inside the replicated package (which is anyway passed on verbatim to the KVS once the ZAB header has been stripped out).

* Scans and GETs are not compatible at the same time. This means that while a scan is executing no other operations can be serviced. This is a result of how memory access is arbitrated between the memory allocator (that performs the scan) and the rest of the pipeline. In future iterations this shall be fixed for better flexibility.


