package main

import (
	"encoding/binary"
	"flag"
	"fmt"
	"caribou/nukv"
	"math/rand"
	"os"
	"sync"
	"time"
	//   "encoding/hex"
	"bufio"
	"os/exec"
	"strconv"
	"strings"
)

type configuration struct {
	host        string
	numClients  int
	runtime     int
	scans       int
	setProb     float64
	valueLength int
	zipfs       float64
	decomp      bool
	matchExpr   string
	timing      bool
}

type statistics struct {
	reqs         int
	sets         int
	gets         int
	updates      int
	miss         int
	setErrors    int
	updateErrors int
	getErrors    int
}

const letters = "0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz"

func GenerateKeys(numKeys int, threadid int) []string {

	keys := make([]string, numKeys)

	// Generate keys in range
	pre := 13

	for i := 0; i < numKeys; i++ {
		bs := make([]byte, 4)
		ra := make([]byte, 4)

		binary.LittleEndian.PutUint32(bs, uint32(i%(1024*1024))) //uint32(i*pre+i+(threadid+1)*256*1024))
		binary.LittleEndian.PutUint32(ra, uint32((i / (1024))))  //uint32(i*pre*17+i/2+(threadid+1)*256*1024))

		//rsum := 10000000+i
		//keys[i] = strconv.Itoa(rsum)

		keys[i] = (string(bs)) + "GOOG" // (string(ra))

		if i%len(letters) == 0 {
			pre = pre + 1
		}
	}

	// Check key length
	for _, key := range keys {
		if len(key) != 8 {
			fmt.Println("Error: key has unexpected length: ", len(key))
			os.Exit(1)
		}
	}
	return keys
}

func GenerateCondition(descr string) []int {
	columns := []string{"year", "month", "day", "opening", "closing", "low", "high", "volume"}
	offs := 0
	cfunc := 0
	cval := 0
	parsedto := 0

	for x := 0; x < len(columns); x++ {
		if strings.HasPrefix(descr, columns[x]) {
			offs = 2 + 4*x
			parsedto = len(columns[x])
			break
		}
	}

	if offs > 0 {
		if descr[parsedto] == '=' {
			cfunc = 0
			parsedto += 2
		} else if descr[parsedto] == '<' {
			cfunc = 1
			parsedto += 2
		} else if descr[parsedto] == '>' {
			cfunc = 2
			parsedto += 2
		} else if descr[parsedto] == '!' {
			cfunc = 3
			parsedto = parsedto + 2
		}

		pval, err := strconv.Atoi(descr[parsedto:])

		if err != nil {
			offs = 0
			cfunc = 0
			cval = 0
		} else {
			cval = pval
		}
	}
	//fmt.Println(offs, cfunc, cval)

	return []int{offs, cfunc, cval}
}

func PrettyPrint(value []byte, header bool) {

	if header == true {
		fmt.Println("year month day opening closing low high volume description")
	}

	for pos := 0; pos < len(value); pos += 8 {
		if value[pos] == 0xFF && value[pos+1] == 0xFF {
			//nothing
		} else if value[pos] == 0x00 && value[pos+1] == 0x00 {
			//nothing
		} else if int(value[pos])+int(value[pos+1])*256 <= 1024 {
			// this is a value
			remlen := int(value[pos]) + int(value[pos+1])*256
			pos += 2
			remlen -= 2

			for nums := 0; nums < 8; nums++ {
				number := int(value[pos+nums*4+0]) + int(value[pos+nums*4+1])*256 + int(value[pos+nums*4+2])*256*256 + int(value[pos+nums*4+3])*256*256*256
				fmt.Printf("%d ", number)
				remlen -= 4

			}

			pos += 8 * 4

			fmt.Printf("\"%s\"\n", value[pos:pos+remlen])
			pos += remlen
		}

	}

}

//TODO Generate Skewed Keys

func client(wg *sync.WaitGroup, s chan bool, mc *nukv.Client, config *configuration, statschan chan statistics, 
				mustPopulate bool, mustFlush bool, startpct float64, stoppct float64, numKeys int, keys []string, values [][]byte) {
	defer wg.Done()

	

	

	stats := statistics{reqs: 0, sets: 0, gets: 0, setErrors: 0, getErrors: 0, updates: 0, updateErrors: 0}

	// Open a connection by issuing a set/get



	if mustFlush == true && startpct==0 {
		err := mc.FlushAll()		
		if err != nil {
			fmt.Println("Error on flush: ", err.Error())
		}	
	} else {    
		_, err := mc.Get(keys[0])
		if err != nil {
			fmt.Println("Error on open/set connection: ", err.Error())
		}
	}

	

  wrapped := false

  firstIdx := int(float64(numKeys)*startpct)
  lastIdx := int(float64(numKeys)*stoppct)
  myNumKeys := int(float64(numKeys)*(stoppct-startpct))

	// Wait for start signal
	startsig := <-s
	if !startsig {
		fmt.Println("Wrong start signal.")
		return
	}

	

  starttime := time.Now()

	oracle := rand.New(rand.NewSource(time.Now().UnixNano()))

	keyidx := firstIdx
	for {
		select {
		case stopsig := <-s:
			//fmt.Println("go signal")
			if !stopsig {
				statschan <- stats
				return
			}
		default:
			stats.reqs++

			keyidx++

        if keyidx==lastIdx {
          keyidx = firstIdx
        }

			if wrapped == false && stats.reqs > myNumKeys {
				wrapped = true
			}


			var err error
			prob := oracle.Float64()

			if prob < config.setProb || (mustPopulate == true && wrapped == false) {
				if mustPopulate == true {

					if wrapped == true {            
			            duration := time.Since(starttime)
			            fmt.Println("----------------------------")
			            fmt.Println("Duration[s]: ", float64(duration)/1000000000.0)
			            fmt.Println("Requests: ", stats.reqs)
			            fmt.Println("Sets: ", stats.sets)
			            fmt.Println("Updates: ", stats.updates)
			            fmt.Println("Gets: ", stats.gets)
			            fmt.Println("Misses: ", stats.miss)
			            fmt.Println("Set errors: ", stats.setErrors)
			            fmt.Println("Update errors: ", stats.updateErrors)
			            fmt.Println("Get errors: ", stats.getErrors)
			            os.Exit(0)
          
						//nothing more to do...				
					}

					if config.timing {
						starttime = time.Now()
					}

					/*for x:=keyidx; x<keyidx+8 && x<lastIdx; x++ {
						_ = mc.SetAsync(&nukv.Item{Key: keys[x], Value: values[x]})
					}

					for x:=keyidx; x<keyidx+8 && x<lastIdx; x++ {
						err = mc.WaitSetResp(&nukv.Item{Key: keys[x], Value: values[x]})
					*/

						err = mc.Set(&nukv.Item{Key: keys[keyidx], Value: values[keyidx]})

						if err != nil {
							fmt.Println(stats.reqs, ": Error on set: ", err.Error())
							stats.setErrors++
							//os.Exit(1)
						} else {
							if stats.sets%1024 == 1023 {
								fmt.Println(startpct, stats.reqs, ": Success ")
							}
							stats.sets++
						}

						if config.timing {
							elapsed := time.Since(starttime)
							print("Set took ", elapsed/1000, "\n")
						}
					/*}

					stats.reqs+=7

					keyidx+=8
					if (keyidx>=lastIdx) {
						keyidx = lastIdx-1
					}*/

				} else {

					if config.timing {
						//time.Sleep(time.Millisecond)
						starttime = time.Now()
					}

					err = mc.Replace(&nukv.Item{Key: keys[keyidx], Value: values[keyidx]})

					if config.timing && err == nil {
						elapsed := time.Since(starttime)
						print("Upd took ", elapsed/1000, "\n")
					}

					if err != nil {
						fmt.Println(startpct, stats.reqs, ": Error on replace: ", err.Error())
						stats.updateErrors++
						//os.Exit(1)
					} else {
						stats.updates++
					}

				}

			} else {
				//TODO decomp config

				if config.timing {
					starttime = time.Now()
				}

				var val *nukv.Item

				if len(config.matchExpr) == 0 {

					val, _ = mc.Get(keys[keyidx])
					//fmt.Printf("%s\n", val)

				} else {

					condoffs := []int{0, 0, 0, 0}
					condfunc := []int{0, 0, 0, 0}
					condval := []int{0, 0, 0, 0}
					regexbytes := []byte{0}

					subconds := strings.Split(config.matchExpr, ",")

					for x := 0; x < len(subconds)-1; x++ {
						conf := GenerateCondition(subconds[x])
						condoffs[x] = conf[0]
						condfunc[x] = conf[1]
						condval[x] = conf[2]
					}
					regexbytes = []byte(subconds[len(subconds)-1])

					condregex, err := exec.Command("regexconfig", string(regexbytes)).Output()

					if err != nil {
						fmt.Println("Error creating regex configuration bits: ", err.Error())
						os.Exit(1)
					}

					if config.scans == 0 {
						//_, err = mc.Ret(&nukv.Item{Key: keys[keyidx], Value: filtcond}, 0)
						_, err = mc.Ret(keys[keyidx], false, condoffs, condfunc, condval, condregex)
					} else if config.scans == 1 {

            starttime = time.Now()
						//val, err = mc.Ret("deadbeef", true, []int{2, 6, 10, 14}, []int{0, 0, 0, 0}, []int{2016, 2, 16, 6817}, []byte("YU.*M"))
						val, err = mc.Ret("deadbeef", true, condoffs, condfunc, condval, condregex)
						PrettyPrint(val.Value, false)

					} else if config.scans == 2 && wrapped==false {

            starttime = time.Now()
            			
						for itr := firstIdx; itr < lastIdx; itr++ {
							val, err = mc.Ret(keys[itr], false, condoffs, condfunc, condval, condregex)

							if val != nil && val.Value != nil {
								PrettyPrint(val.Value, false)
							}
						}

						if (config.numClients>1) {
							wrapped = true
						}

					}

				}

				if err != nil {
					fmt.Println(stats.reqs, ": Error on get/ret: ", err.Error())
					stats.getErrors++
					//os.Exit(1)
				} else {
					stats.gets++

					if config.scans > 0 && config.numClients==1 {						
            duration := time.Since(starttime)
            fmt.Println("----------------------------")
            fmt.Println("Duration[s]: ", float64(duration)/1000000000.0)
            fmt.Println("Requests: ", stats.reqs)
            fmt.Println("Sets: ", stats.sets)
            fmt.Println("Updates: ", stats.updates)
            fmt.Println("Gets: ", stats.gets)
            fmt.Println("Misses: ", stats.miss)
            fmt.Println("Set errors: ", stats.setErrors)
            fmt.Println("Update errors: ", stats.updateErrors)
            fmt.Println("Get errors: ", stats.getErrors)
            os.Exit(0)
					}
				}

				if config.timing {
					elapsed := time.Since(starttime)
					print("Get took ", elapsed/1000, "\n")
				}
			}

		} //select
	} //for

}

func main() {
	hostPtr := flag.String("host", "10.1.212.209:2888", "host addr and port")
	replicatePtr := flag.Bool("replicate", false, "use replication")
	numPtr := flag.Int("clients", 1, "number of clients")
	timePtr := flag.Int("time", 10, "runtime in seconds")
	scanPtr := flag.Int("scans", 0, "scan mode (0=no scan, 1=scan internal, 2=explicit)")
	setPtr := flag.Float64("setp", 0.1, "probability of set")
	populatePtr := flag.Bool("populate", false, "populating the store, ignore set ratios")
	flushPtr := flag.Bool("flush", false, "start by flushing everything")
	valuePtr := flag.Int("vallen", 64, "length of value")
	timingPtr := flag.Bool("timing", false, "use timed mode")
	matchPtr := flag.String("regexmatch", "", "expressions to match on, separated by comma. year|month|day|opening|closing|low|high|volume ==|>=|<=|!= value ,")
	flag.Parse()

	useReplication := *replicatePtr
	mustPopulate := *populatePtr
	mustFlush := *flushPtr

	config := configuration{
		host:        *hostPtr,
		numClients:  *numPtr,
		runtime:     *timePtr,
		scans:       *scanPtr,
		setProb:     *setPtr,
		valueLength: *valuePtr,
		matchExpr:   *matchPtr,
		timing:      *timingPtr}

	if mustPopulate == true {
		config.setProb = 1.0
	}

	if config.valueLength%8 != 0 {
		fmt.Println("value length Must be multiple of 8")
		os.Exit(1)
	}

	numKeysGen := 1024
	numKeys := 0

	keys := make([]string, 10*1024*1024)
	values := make([][]byte, 10*1024*1024)

	tvallen := 0

	file, err := os.Open("input.csv")
	if err == nil {
		idx := 0

		scanner := bufio.NewScanner(file)
		for scanner.Scan() {
			s := strings.Split(scanner.Text(), " ")
			symbol, timestamp := s[0], s[1]

			tsi, _ := strconv.Atoi(timestamp)
			bs := make([]byte, 4)
			binary.LittleEndian.PutUint32(bs, uint32(tsi))

			keys[idx] = symbol + string(bs)

			for len(keys[idx]) < 8 {
				keys[idx] = keys[idx] + symbol
			}
			keys[idx] = keys[idx][0:8]

			//          date_year, date_month, date_day, opening, closing, low, high, volume := s[2], s[3], s[4], s[5], s[6], s[7], s[8], s[9]

			lenfp := 0
			for x := 0; x <= 9; x++ {
				lenfp += len(s[x])
			}
			rest := scanner.Text()[lenfp+2:]

			binaryint := make([]byte, 4)
			valuestring := ""

			for x := 2; x <= 9; x++ {
				q, _ := strconv.Atoi(s[x])
				binary.LittleEndian.PutUint32(binaryint, uint32(q))
				valuestring = valuestring + string(binaryint)
			}
			valuestring = valuestring + rest

			vallen := len(valuestring) + 2
			if vallen < 64 {
				vallen = 64
			} else if vallen < 128 {
				vallen = 128
			} else if vallen < 256 {
				vallen = 256
			}

			tvallen += vallen

			values[idx] = make([]byte, vallen)
			values[idx][0] = byte(vallen % 256)
			values[idx][1] = byte(vallen / 256)
			for i := 0; i < len(valuestring); i++ {
				values[idx][i+2] = valuestring[i]
			}

			//fmt.Println(values[idx])

			numKeys = idx
			idx = idx + 1

			if idx > numKeysGen {
				break
			}

		}

		file.Close()

		//fmt.Println(tvallen)

		fmt.Println("CSV loaded...")

		//os.Exit(0)
	} else {
		fmt.Println("Couldn't open file!")
		fmt.Println(err)
		os.Exit(1)
	}


	//TODO make host as input
	mc := nukv.New(config.host)
	// Set max idle cons
	mc.MaxIdleConns = config.numClients+2
	// set network timeout
	mc.Timeout = 5000 * time.Millisecond
	mc.UseReplication = useReplication
	mc.DoTiming = *timingPtr

	wg := new(sync.WaitGroup)
	start := make(chan bool)
	statschan := make(chan statistics)

  perclient := 1.0/float64(config.numClients)

	// start clients
	for i := 0; i < config.numClients; i++ {
		wg.Add(1)

		startPercent := float64(i)*perclient
        stopPercent := float64(i+1)*perclient

		go client(wg, start, mc, &config, statschan, mustPopulate, mustFlush, startPercent, stopPercent, numKeys, keys, values)

	}

	// wait for clients to setup
	time.Sleep(time.Second)

	fmt.Println("Start...")
	starttime := time.Now()
	for i := 0; i < config.numClients; i++ {
		start <- true
	}
	// Run for x seconds
	time.Sleep(time.Duration(config.runtime) * time.Second)

	// Stop clients
	fmt.Println("Stopping...")
	for i := 0; i < config.numClients; i++ {
		start <- false
	}
	stats := make([]statistics, config.numClients)
	gstats := statistics{reqs: 0, sets: 0, gets: 0, miss: 0, setErrors: 0, getErrors: 0, updates: 0, updateErrors: 0}
	for i := 0; i < config.numClients; i++ {
		stats[i] = <-statschan
		gstats.reqs += stats[i].reqs
		gstats.sets += stats[i].sets
		gstats.updates += stats[i].updates
		gstats.gets += stats[i].gets
		gstats.setErrors += stats[i].setErrors
		gstats.getErrors += stats[i].getErrors
		gstats.updateErrors += stats[i].updateErrors
	}
	wg.Wait()
	duration := time.Since(starttime).Seconds()

	fmt.Println("----------------------------")
	fmt.Printf("Throughput[KReq/s]: %2f\n", float64(gstats.reqs)/duration/1000)
	fmt.Printf("Duration[s]: %2f\n", duration)
	fmt.Println("Requests: ", gstats.reqs)
	fmt.Println("Sets: ", gstats.sets)
	fmt.Println("Updates: ", gstats.updates)
	fmt.Println("Gets: ", gstats.gets)
	fmt.Println("Misses: ", gstats.miss)
	fmt.Println("Set errors: ", gstats.setErrors)
	fmt.Println("Update errors: ", gstats.updateErrors)
	fmt.Println("Get errors: ", gstats.getErrors)

}
