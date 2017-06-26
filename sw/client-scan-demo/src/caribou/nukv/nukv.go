

/*
Copyright 2011 Google Inc.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

     http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

// Package nukv provides a client for the nukvd cache server.
package nukv

import (
"bufio"
"bytes"
"errors"
"fmt"
"net"

"strconv"
"strings"
"sync"
"time"
)

// Similar to:
// http://code.google.com/appengine/docs/go/nukv/reference.html

var (
	// ErrCacheMiss means that a Get failed because the item wasn't present.
	ErrCacheMiss = errors.New("nukv: cache miss")

	// ErrCASConflict means that a CompareAndSwap call failed due to the
	// cached value being modified between the Get and the CompareAndSwap.
	// If the cached value was simply evicted rather than replaced,
	// ErrNotStored will be returned instead.
	ErrCASConflict = errors.New("nukv: compare-and-swap conflict")

	// ErrNotStored means that a conditional write operation (i.e. Add or
	// CompareAndSwap) failed because the condition was not satisfied.
	ErrNotStored = errors.New("nukv: item not stored")

	// ErrServer means that a server error occurred.
	ErrServerError = errors.New("nukv: server error")

	// ErrNoStats means that no statistics were available.
	ErrNoStats = errors.New("nukv: no statistics available")

	// ErrMalformedKey is returned when an invalid key is used.
	// Keys must be at maximum 250 bytes long, ASCII, and not
	// contain whitespace or control characters.
	ErrMalformedKey = errors.New("malformed: key is too long or contains invalid characters")

	// ErrNoServers is returned when no servers are configured or available.
	ErrNoServers = errors.New("nukv: no servers configured or available")
)



const (
   // DefaultTimeout is the default socket read/write timeout.
	DefaultTimeout      = 10 * time.Millisecond

   // DefaultMaxIdleConns is the default maximum number of idle connections
   // kept for any single address
	DefaultMaxIdleConns = 2
)

const buffered = 8 // arbitrary buffered channel size, for readability

// resumableError returns true if err is only a protocol-level cache error.
// This is used to determine whether or not a server connection should
// be re-used or not. If an error occurs, by default we don't reuse the
// connection, unless it was just a cache error.
func resumableError(err error) bool {
	switch err {
	case ErrCacheMiss, ErrCASConflict, ErrNotStored, ErrMalformedKey:
		return true
	}
	return false
}

func legalKey(key string) bool {
	if len(key) > 250 {
		return false
	}/*
	for i := 0; i < len(key); i++ {
		if key[i] <= ' ' || key[i] > 0x7e {
			return false
		}
	}
	return true
	*/
	return true
}

var (
	crlf            = []byte("\r\n")
	space           = []byte(" ")
	resultOK        = []byte("OK\r\n")
	resultStored    = []byte("STORED\r\n")
	resultNotStored = []byte("NOT_STORED\r\n")
	resultExists    = []byte("EXISTS\r\n")
	resultNotFound  = []byte("NOT_FOUND\r\n")
	resultDeleted   = []byte("DELETED\r\n")
	resultEnd       = []byte("END\r\n")
	resultOk        = []byte("OK\r\n")
	resultTouched   = []byte("TOUCHED\r\n")

	resultClientErrorPrefix = []byte("CLIENT_ERROR ")
)

// New returns a nukv client using the provided server(s)
// with equal weight. If a server is listed multiple times,
// it gets a proportional amount of weight.
func New(server ...string) *Client {
	ss := new(ServerList)
	ss.SetServers(server...)
	return NewFromSelector(ss)
}

// NewFromSelector returns a new Client using the provided ServerSelector.
func NewFromSelector(ss ServerSelector) *Client {
	return &Client{selector: ss}
}

// Client is a nukv client.
// It is safe for unlocked use by multiple concurrent goroutines.
type Client struct {
	// Timeout specifies the socket read/write timeout.
	// If zero, DefaultTimeout is used.
	Timeout time.Duration

   // MaxIdleConns specifies the maximum number of idle connections that will
   // be maintained per address. If less than one, DefaultMaxIdleConns will be
   // used.
   //
   // Consider your expected traffic rates and latency carefully. This should
   // be set to a number higher than your peak parallel requests.
	MaxIdleConns int

	DoTiming bool

	UseReplication bool

	selector ServerSelector

	lk       sync.Mutex
	freeconn map[string][]*conn
}

// Item is an item to be got or stored in a nukvd server.
type Item struct {
	// Key is the Item's key (250 bytes maximum).
	Key string

	// Value is the Item's value.
	Value []byte

	// Flags are server-opaque flags whose semantics are entirely
	// up to the app.
	Flags uint32

	// Expiration is the cache expiration time, in seconds: either a relative
	// time from now (up to 1 month), or an absolute Unix epoch time.
	// Zero means the Item has no expiration time.
	Expiration int32

	// Compare and swap ID.
	casid uint64
}

// conn is a connection to a server.
type conn struct {
	nc   net.Conn
	rw   *bufio.ReadWriter
	addr net.Addr
	c    *Client
}

// release returns this connection back to the client's free pool
func (cn *conn) release() {
	cn.c.putFreeConn(cn.addr, cn)
}

func (cn *conn) extendDeadline() {
	cn.nc.SetDeadline(time.Now().Add(cn.c.netTimeout()))
}

// condRelease releases this connection if the error pointed to by err
// is nil (not an error) or is only a protocol level error (e.g. a
// cache miss).  The purpose is to not recycle TCP connections that
// are bad.
func (cn *conn) condRelease(err *error) {
	if *err == nil || resumableError(*err) {
		cn.release()
	} else {
		cn.nc.Close()
	}
}

func (c *Client) putFreeConn(addr net.Addr, cn *conn) {
	c.lk.Lock()
	defer c.lk.Unlock()
	if c.freeconn == nil {
		c.freeconn = make(map[string][]*conn)
	}
	freelist := c.freeconn[addr.String()]
	if len(freelist) >= c.maxIdleConns() {
		cn.nc.Close()
		return
	}
	c.freeconn[addr.String()] = append(freelist, cn)
}

func (c *Client) getFreeConn(addr net.Addr) (cn *conn, ok bool) {
	c.lk.Lock()
	defer c.lk.Unlock()
	if c.freeconn == nil {
		return nil, false
	}
	freelist, ok := c.freeconn[addr.String()]
	if !ok || len(freelist) == 0 {
		return nil, false
	}
	cn = freelist[len(freelist)-1]
	c.freeconn[addr.String()] = freelist[:len(freelist)-1]

	return cn, true
}

func (c *Client) netTimeout() time.Duration {
	if c.Timeout != 0 {
		return c.Timeout
	}
	return DefaultTimeout
}

func (c *Client) maxIdleConns() int {
	if c.MaxIdleConns > 0 {
		return c.MaxIdleConns
	}
	return DefaultMaxIdleConns
}

// ConnectTimeoutError is the error type used when it takes
// too long to connect to the desired host. This level of
// detail can generally be ignored.
type ConnectTimeoutError struct {
	Addr net.Addr
}

func (cte *ConnectTimeoutError) Error() string {
	return "nukv: connect timeout to " + cte.Addr.String()
}

func (c *Client) dial(addr net.Addr) (net.Conn, error) {
	type connError struct {
		cn  net.Conn
		err error
	}

	nc, err := net.DialTimeout(addr.Network(), addr.String(), c.netTimeout())
	if err == nil {
		return nc, nil
	}

	if ne, ok := err.(net.Error); ok && ne.Timeout() {
		return nil, &ConnectTimeoutError{addr}
	}

	return nil, err
}

func (c *Client) getConn(addr net.Addr) (*conn, error) {
	cn, ok := c.getFreeConn(addr)
	if ok {
		cn.extendDeadline()
		return cn, nil
	}
	nc, err := c.dial(addr)
	if err != nil {
		return nil, err
	}
	cn = &conn{
		nc:   nc,
		addr: addr,
		rw:   bufio.NewReadWriter(bufio.NewReaderSize(nc,16*1014*1024), bufio.NewWriter(nc)),
		c:    c,
	}
	cn.extendDeadline()
	return cn, nil
}

func (c *Client) onItem(item *Item, fn func(*Client, *bufio.ReadWriter, *Item) error) error {
	addr, err := c.selector.PickServer(item.Key)
	if err != nil {
		return err
	}
	cn, err := c.getConn(addr)
	if err != nil {
		return err
	}
	defer cn.condRelease(&err)
	if err = fn(c, cn.rw, item); err != nil {
		return err
	}
	return nil
}

func (c *Client) FlushAll() error {
	return c.selector.Each(c.flushAllFromAddr)
}

// Get gets the item for the given key. ErrCacheMiss is returned for a
// nukv cache miss. The key must be at most 250 bytes in length.
func (c *Client) Get(key string) (item *Item, err error) {
	err = c.withKeyAddr(key, func(addr net.Addr) error {
		return c.getFromAddr(addr, []string{key}, func(it *Item) { item = it }, 1)
		})
	/*if err == nil && item == nil {
		err = ErrCacheMiss
		}*/
		return
	}

// Get gets the item for the given key. ErrCacheMiss is returned for a
// nukv cache miss. The key must be at most 250 bytes in length.
	func (c *Client) Delete(key string) (item *Item, err error) {
		err = c.withKeyAddr(key, func(addr net.Addr) error {
			return c.delFromAddr(addr, []string{key}, func(it *Item) { item = it })
			})
	/*if err == nil && item == nil {
		err = ErrCacheMiss
		}*/
		return
	}

// Ret, regular expression get
	func (c *Client) Ret(key string,  scan bool, offs []int, funcs []int, consts []int, regex []byte) (item *Item, err error) {
		err = c.withKeyAddr(key, func(addr net.Addr) error {
			return c.retFromAddr(addr, key, func(it *Item) { item = it}, scan , offs, funcs, consts, regex)
			})
   /*if err == nil && item == nil {
      err = ErrCacheMiss
      }*/
      return
  }

  func (c *Client) withKeyAddr(key string, fn func(net.Addr) error) (err error) {
  	if !legalKey(key) {
  		return ErrMalformedKey
  	}
  	addr, err := c.selector.PickServer(key)
  	if err != nil {
  		return err
  	}
  	return fn(addr)
  }

  func (c *Client) withAddrRw(addr net.Addr, fn func(*bufio.ReadWriter) error) (err error) {
  	cn, err := c.getConn(addr)
  	if err != nil {
  		return err
  	}
  	defer cn.condRelease(&err)
  	return fn(cn.rw)
  }

  func (c *Client) withKeyRw(key string, fn func(*bufio.ReadWriter) error) error {
  	return c.withKeyAddr(key, func(addr net.Addr) error {
  		return c.withAddrRw(addr, fn)
  		})
  }

  func (c *Client) getFromAddr(addr net.Addr, keys []string, cb func(*Item), scancount int) error {
  	return c.withAddrRw(addr, func(rw *bufio.ReadWriter) error {
      // Add Zsolt header
  		padding := []byte{0, 0, 0, 0, 0, 0, 0, 0}
  		padLen := 0
  		mheader := fmt.Sprintf("%s", strings.Join(keys, ""))
  		length := len(mheader)
  		if length % 8 != 0 {
  			padLen = 8 - (length % 8)
  		}
  		length += padLen
  		length /= 8
  		zheader := []byte{0xFF, 0xFF, 0, 0, byte(length), 0, byte(1), 0, 0, 0, 0, 0, 0, 0, 0, 0}


  		if _, err := rw.Write(zheader); err != nil {
  			return err
  		}


  		if _, err := fmt.Fprintf(rw, "%s", mheader); err != nil {
  			return err
  		}
  		if padLen != 0 {
  			if _, err := rw.Write(padding[0:padLen]); err != nil {
  				return err
  			}
  		}
  		if err := rw.Flush(); err != nil {
  			return err
  		}



  		for i := 0; i < scancount; i++ {
  			if !c.DoTiming {
  				if err := parseZsoltResponse(rw.Reader, cb); err != nil {
  					return err
  				}
  			} else {
  				start := time.Now()
  				if err := parseZsoltResponseWt(rw.Reader, cb, start); err != nil {
  					return err
  				}
  			}
  		}
  		return nil
  		})
  }


  func (c *Client) delFromAddr(addr net.Addr, keys []string, cb func(*Item)) error {
  	return c.withAddrRw(addr, func(rw *bufio.ReadWriter) error {
      // Add Zsolt header
  		padding := []byte{0, 0, 0, 0, 0, 0, 0, 0}
  		padLen := 0
  		mheader := fmt.Sprintf("%s", strings.Join(keys, ""))
  		length := len(mheader)
  		if length % 8 != 0 {
  			padLen = 8 - (length % 8)
  		}
  		length += padLen
  		length /= 8
  		zheader := []byte{0xFF, 0xFF, 0, 0, byte(length), 0, byte(1), 2, 0, 0, 0, 0, 0, 0, 0, 0}

  		if _, err := rw.Write(zheader); err != nil {
  			return err
  		}  			

  		if _, err := fmt.Fprintf(rw, "%s", mheader); err != nil {
  			return err
  		}
  		if padLen != 0 {
  			if _, err := rw.Write(padding[0:padLen]); err != nil {
  				return err
  			}
  		}
  		if err := rw.Flush(); err != nil {
  			return err
  		}


  		if err := parseZsoltResponse(rw.Reader, cb); err != nil {
  			return err
  		}


  	return nil
  	})
  }

  func (c *Client) retFromAddr(addr net.Addr, key string, cb func(*Item), scan bool, offs []int, funcs []int, consts []int, regex []byte) error {
  	return c.withAddrRw(addr, func(rw *bufio.ReadWriter) error {
      // Add Zsolt header

  		mheader := fmt.Sprintf("%s", key)
  		padding := []byte{0, 0, 0, 0, 0, 0, 0, 0}
  		padLen := 0

  		cfg := make([]byte, 64)
  		cfglen := 0

  		for x:=0; x<len(consts); x++ {
  			cfg[cfglen] = byte(offs[x]%256)
  			cfg[cfglen+1] = byte(offs[x]/256 + funcs[x]*16)

  			cfg[cfglen+2] = byte(consts[x]%256)
  			cfg[cfglen+3] = byte(consts[x]/256%256)
  			cfg[cfglen+4] = byte(consts[x]/256/256%256)
  			cfg[cfglen+5] = byte(consts[x]/256/256/256%256)

  			cfglen += 6
  		}

  		var w bytes.Buffer
  		
  		
  		w.Write(regex)     	
  		

  		interm := bytes.Split(w.Bytes(),[]byte(" "))	   
  		for x:=0; x <len(interm); x++ {
  			bim, _ := strconv.Atoi(string(interm[x]))
  			cfg[cfglen] = byte(bim)     	
  			cfglen += 1
      	//fmt.Println(bim)
  		}

  		length := len(mheader) + 64

  		if length % 8 != 0 {
  			padLen = 8 - (length % 8)
  		}
  		length += padLen
  		length /= 8

    //

  		optype := 4
  		if scan == true {
  			optype	= 12	
  		}


  		zheader := []byte{0xFF, 0xFF, 0, 0, byte(length), 0, byte(1), byte(optype), 0, 0, 0, 0, 0, 0, 0, 0}


  		if _, err := rw.Write(zheader); err != nil {
  			return err
  		}


  		if _, err := fmt.Fprintf(rw, "%s", mheader); err != nil {
  			return err
  		}
  		if _,err := rw.Write(cfg); err != nil {
  			return err
  		}

  		if padLen != 0 {
  			if _, err := rw.Write(padding[0:padLen]); err != nil {
  				return err
  			}
  		}
  		if err := rw.Flush(); err != nil {
  			return err
  		}

  		if scan==false {
  			if err := parseZsoltResponseCOND(rw.Reader, cb); err != nil {
  				return err
  			}
  		} else {
  			done := false
  			marker := []byte{0xed, 0xda, 0xeb, 0xfe, 0,0,0,0}	

  			it := new(Item)

  			it.Key = ""
  			var vals bytes.Buffer
  			vals.Grow(1024*1024)

  			length := 0; 			

  			for done == false { 

  				pline, err := rw.Reader.Peek(8)

  				if err!=nil {
  					fmt.Printf("Error\n")
  					done = true
  				}

  				if bytes.Equal(pline,marker) {
  					done = true
  				} else {
  					vals.Write(pline)
  				}
  				length = length+8
  				rw.Reader.Discard(8)

  			}

  			it.Value = vals.Bytes()

  			cb(it)




  			return nil
  		}



  		return nil
  		})
  }


// flushAllFromAddr send the flush_all command to the given addr
  func (c *Client) flushAllFromAddr(addr net.Addr) error {
  	return c.withAddrRw(addr, func(rw *bufio.ReadWriter) error {
		// Add Zsolt header
  		mheader := fmt.Sprintf("%s", "flushall")
  		length := len(mheader)
  		length /= 8
  		zheader := []byte{0xFF, 0xFF, 0, 0, byte(length), 0, byte(1), 8, 0, 0, 0, 0, 0, 0, 0, 0}


  		if _, err := rw.Write(zheader); err != nil {
  			return err
  		}


  		if _, err := fmt.Fprintf(rw, "%s", mheader); err != nil {
  			return err
  		}

  		if err := rw.Flush(); err != nil {
  			return err
  		}

  		pline, err := rw.Reader.Peek(16)
  		if err == nil {
  			rw.Reader.Discard(16)
  		} else {
  			return fmt.Errorf("nukv: unexpected response", err.Error())
  		}

  		switch {
  		case pline[0] == 0xFF:
  			break
  		default:
  			return fmt.Errorf("nukv: unexpected response line from flush_all: %q", string(pline))
  		}
  		return nil
  		})
  }

/*
func (c *Client) touchFromAddr(addr net.Addr, keys []string, expiration int32) error {
	return c.withAddrRw(addr, func(rw *bufio.ReadWriter) error {
		for _, key := range keys {
			if _, err := fmt.Fprintf(rw, "touch %s %d\r\n", key, expiration); err != nil {
				return err
			}
			if err := rw.Flush(); err != nil {
				return err
			}
			line, err := rw.ReadSlice('\n')
			if err != nil {
				return err
			}
			switch {
			case bytes.Equal(line, resultTouched):
				break
			case bytes.Equal(line, resultNotFound):
				return ErrCacheMiss
			default:
				return fmt.Errorf("nukv: unexpected response line from touch: %q", string(line))
			}
		}
		return nil
	})
}
*/

// GetMulti is a batch version of Get. The returned map from keys to
// items may have fewer elements than the input slice, due to nukv
// cache misses. Each key must be at most 250 bytes in length.
// If no error is returned, the returned map will also be non-nil.
/*
func (c *Client) GetMulti(keys []string) (map[string]*Item, error) {
	var lk sync.Mutex
	m := make(map[string]*Item)
	addItemToMap := func(it *Item) {
		lk.Lock()
		defer lk.Unlock()
		m[it.Key] = it
	}

	keyMap := make(map[net.Addr][]string)
	for _, key := range keys {
		if !legalKey(key) {
			return nil, ErrMalformedKey
		}
		addr, err := c.selector.PickServer(key)
		if err != nil {
			return nil, err
		}
		keyMap[addr] = append(keyMap[addr], key)
	}

	ch := make(chan error, buffered)
	for addr, keys := range keyMap {
		go func(addr net.Addr, keys []string) {
			ch <- c.getFromAddr(addr, keys, addItemToMap, 1)
		}(addr, keys)
	}

	var err error
	for _ = range keyMap {
		if ge := <-ch; ge != nil {
			err = ge
		}
	}
	return m, err
	}*/

// parseGetResponse reads a GET response from r and calls cb for each
// read and allocated Item
	func parseZsoltResponse(r *bufio.Reader, cb func(*Item)) error {

		pline, err := r.Peek(2)
		if err != nil {
			return err
		}
		if pline[0] == byte(0xFF) && pline[1] == byte(0xFF) {
			if _,err := r.Discard(2); err != nil {
				return err
			}

			success, err := r.Peek(1)
			if err != nil {
				return err
			}

			r.Discard(2)

			size, err := r.Peek(1)
			if err != nil {
				return err
			}

			

			if success[0] == 0 || size[0] == 0  {
        r.Discard(4)
				return errors.New("nukv: cache miss")
			}
      r.Discard(4+8)

			it := new(Item)

			it.Value = make([]byte, int(size[0])*8)
			it.Value, err = r.Peek(int(size[0])*8)
			r.Discard(int(size[0])*8)
			if err != nil {
				return err
			}

			cb(it)
		}

		return nil

	}

// parseGetResponse reads a GET response from r and calls cb for each
// read and allocated Item
	func parseZsoltResponseCOND(r *bufio.Reader, cb func(*Item)) error {

		pline, err := r.Peek(2)
		if err != nil {
			return err
		}
		if pline[0] == byte(0xFF) && pline[1] == byte(0xFF) {
			if _,err := r.Discard(2); err != nil {
				return err
			}

			success, err := r.Peek(1)
			if err != nil {
				return err
			}

			r.Discard(2)

			size, err := r.Peek(1)
			if err != nil {
				return err
			}


			
			if success[0] == 0 {
				r.Discard(4+8)
				return errors.New("nukv: cache miss")
			}

			it := new(Item)

			if size[0] == 0 {
				r.Discard(4)
			} else {
				r.Discard(4+8)
			}

			if size[0] != 0 {


				it.Value = make([]byte, int(size[0])*8)
				it.Value, err = r.Peek(int(size[0])*8)
				r.Discard(int(size[0])*8)


			} else {
				it.Value = nil
			}
			if err != nil {
				return err
			}

			cb(it)
		}

		return nil

	}

// parseGetResponse reads a GET response from r and calls cb for each
// read and allocated Item
	func parseZsoltResponseWt(r *bufio.Reader, cb func(*Item), st time.Time) error {

		pline, err := r.Peek(2)
		if err != nil {
			return err
		}

		elapsed := time.Since(st)
		print("Get took ", elapsed/1000, "\n")

		if pline[0] == byte(0xFF) && pline[1] == byte(0xFF) {
			if _,err := r.Discard(2); err != nil {
				return err
			}

			success, err := r.Peek(1)
			if err != nil {
				return err
			}

			r.Discard(2)

			size, err := r.Peek(1)
			if err != nil {
				return err
			}

			r.Discard(4+8)

			if success[0] == 0 || size[0] == 0  {
				return errors.New("nukv: cache miss")
			}


			it := new(Item)

			it.Value = make([]byte, int(size[0])*8)
			it.Value, err = r.Peek(int(size[0])*8)
			r.Discard(int(size[0])*8)
			if err != nil {
				return err
			}

			cb(it)
		}

		return nil

	}

/*
func parseZsoltRetResponse(r *bufio.Reader, cb func(*Item)) error {
   if _, err := r.Discard(8); err != nil {
      return err
   }  

   pline, err := r.Peek(8)

   if err!=nil {
      return err     
   }

   if bytes.Contains(pline, []byte("-------")) {
      _, _ = r.Discard(8)
      return nil;
   }


   totalbytes := 0
   for {          
      line, err := r.ReadSlice('\n')
      if err != nil {
         return err
      }     

      totalbytes += len(line)

      if bytes.Contains(line, resultEnd) {                  
         if totalbytes % 8 !=0 {
            r.Discard(8-( totalbytes % 8 ))
         }
         return nil         
      }
   }
}
*/

/*
func parseZsoltScanResponse(r *bufio.Reader, cb func(*Item)) error {

	for {
		pline, err := r.Peek(8)

		if err != nil {
			return err
		}

		r.Discard(8)

		if bytes.Contains(pline, []byte{0xd, 0xe, 0xe, 0xa, 0xd, 0xb, 0xe, 0xe, 0xf}) {

			it := new(Item)
		
		    it.Value = make([]byte, 8)

		    if err != nil {
		      return err
		    }
			
		    cb(it)
		}
	}
}
*/



/*
// scanGetResponseLine populates it and returns the declared size of the item.
// It does not read the bytes of the item.
func scanGetResponseLine(line []byte, it *Item) (size int, err error) {
	pattern := "VALUE %s %d %d %d\r\n"
	dest := []interface{}{&it.Key, &it.Flags, &size, &it.casid}
	if bytes.Count(line, space) == 3 {
		pattern = "VALUE %s %d %d\r\n"
		dest = dest[:3]
	}
	n, err := fmt.Sscanf(string(line), pattern, dest...)
	if err != nil || n != len(dest) {
		return -1, fmt.Errorf("nukv: unexpected line in get response: %q", line)
	}
	return size, nil
}
*/

// Set writes the given item, unconditionally.
func (c *Client) Set(item *Item) error {
	return c.onItem(item, (*Client).set)
}

func (c *Client) set(rw *bufio.ReadWriter, item *Item) error {
	return c.populateOne(rw, "set", item)
}

func (c *Client) SetAsync(item *Item) error {
	return c.onItem(item, (*Client).asyncSet)
}

func (c *Client) asyncSet(rw *bufio.ReadWriter, item *Item) error {
	return c.populateOne(rw, "asyncset", item)
}

func (c *Client) WaitSetResp(item *Item) error {
  return c.onItem(item, (*Client).asyncResponse)
}

func (c *Client) asyncResponse(rw *bufio.ReadWriter, item *Item) error {
  return c.populateOne(rw, "asyncresponse", item)
}

// Replace writes the given item, but only if the server *does*
// already hold data for this key
func (c *Client) Replace(item *Item) error {
	return c.onItem(item, (*Client).replace)
}

func (c *Client) replace(rw *bufio.ReadWriter, item *Item) error {
	return c.populateOne(rw, "replace", item)
}

// CompareAndSwap writes the given item that was previously returned
// by Get, if the value was neither modified or evicted between the
// Get and the CompareAndSwap calls. The item's Key should not change
// between calls but all other item fields may differ. ErrCASConflict
// is returned if the value was modified in between the
// calls. ErrNotStored is returned if the value was evicted in between
// the calls.
func (c *Client) CompareAndSwap(item *Item) error {
	return c.onItem(item, (*Client).cas)
}

func (c *Client) cas(rw *bufio.ReadWriter, item *Item) error {
	return c.populateOne(rw, "cas", item)
}

func (c *Client) populateOne(rw *bufio.ReadWriter, verb string, item *Item) error {
	if !legalKey(item.Key) {
		return ErrMalformedKey
	}

  if verb != "asyncresponse" {

     // Change for Zsolts protocol
  	padding := []byte{0, 0, 0, 0, 0, 0, 0, 0}
  	padLen := 0

  	var err error
  	
      //Changed for Zsolts protocol
      //mheader := fmt.Sprintf("%s %s %d %d %d\r\n",
        //    verb, item.Key, item.Flags, item.Expiration, len(item.Value))
  	mheader := fmt.Sprintf("%s", item.Key)
  	length := len(mheader) + len(item.Value) 
  	if length % 8 != 0 {
  		padLen = 8 - (length % 8)
  	}
  	length += padLen
  	length /= 8

      //

  	optype := 1
  	if verb == "replace" {
  		optype = 1
  	}

  	zheader := []byte{0xFF, 0xFF, 0, 0, byte(length), 0, byte(1), byte(optype), 0, 0, 0, 0, 0, 0, 0, 0}
  	if c.UseReplication {
  		zheader = []byte{0xFF, 0xFF, 0, 1, byte(length), 0, byte(0), byte(0),  0, 0, 0, 0, 0, 0, 0, 0}
  	} 


  	if _, err := rw.Write(zheader); err != nil {
  		return err
  	}

  	_, err = fmt.Fprintf(rw, "%s", mheader)	
      //verb, item.Key, item.Flags, item.Expiration, len(item.Value))

  	
  	if err != nil {
  		return err
  	}
  	if _, err = rw.Write(item.Value); err != nil {
  		return err
  	}
  	//if _, err := rw.Write(crlf); err != nil {
  	//	return err
  	//}
  	if  padLen != 0 {
  		if _, err := rw.Write(padding[0:padLen]); err != nil {
  			return err
  		}
  	}
  	if err := rw.Flush(); err != nil {
  		return err
  	}
  }

  if verb!="asyncset" {

    //Zsolt Discard 8 dummy bytes  

  	if !c.DoTiming {
  		if _, err := rw.Discard(2); err != nil {
  			return err
  		}

  		if success, _ := rw.Peek(1); success[0] != 1 {
  			if _, err := rw.Discard(14); err != nil {
  				return err
  			}
  			return ErrNotStored
  		}


  		rw.Discard(14)

  	} else {
  		start := time.Now()
  		if _, err := rw.Discard(2); err != nil {
  			return err
  		}
  		elapsed := time.Since(start)
  		print("Set took ", elapsed/1000, "\n")

  		if success, _ := rw.Peek(1); success[0] != 1 {
  			if _, err := rw.Discard(14); err != nil {
  				return err
  			}
  			return ErrNotStored
  		}


  		rw.Discard(14)
  	}
  }

	return nil;
	
}

/*
func writeReadLine(rw *bufio.ReadWriter, format string, args ...interface{}) ([]byte, error) {
	_, err := fmt.Fprintf(rw, format, args...)
	if err != nil {
		return nil, err
	}
	if err := rw.Flush(); err != nil {
		return nil, err
	}
	line, err := rw.ReadSlice('\n')
	return line, err
}

func writeExpectf(rw *bufio.ReadWriter, expect []byte, format string, args ...interface{}) error {
	line, err := writeReadLine(rw, format, args...)
	if err != nil {
		return err
	}
	switch {
	case bytes.Equal(line, resultOK):
		return nil
	case bytes.Equal(line, expect):
		return nil
	case bytes.Equal(line, resultNotStored):
		return ErrNotStored
	case bytes.Equal(line, resultExists):
		return ErrCASConflict
	case bytes.Equal(line, resultNotFound):
		return ErrCacheMiss
	}
	return fmt.Errorf("nukv: unexpected response line: %q", string(line))
	}*/

// Delete deletes the item with the provided key. The error ErrCacheMiss is
// returned if the item didn't already exist in the cache.
/*func (c *Client) Delete(key string) error {
	return c.withKeyRw(key, func(rw *bufio.ReadWriter) error {
		return writeExpectf(rw, resultDeleted, "delete %s\r\n", key)
	})
	}*/

// DeleteAll deletes all items in the cache.
/*
func (c *Client) DeleteAll() error {
	return c.withKeyRw("", func(rw *bufio.ReadWriter) error {
		return writeExpectf(rw, resultDeleted, "flush_all\r\n")
	})
}
*/
// Increment atomically increments key by delta. The return value is
// the new value after being incremented or an error. If the value
// didn't exist in nukvd the error is ErrCacheMiss. The value in
// nukvd must be an decimal number, or an error will be returned.
// On 64-bit overflow, the new value wraps around.
/*
func (c *Client) Increment(key string, delta uint64) (newValue uint64, err error) {
	return c.incrDecr("incr", key, delta)
}
*/

// Decrement atomically decrements key by delta. The return value is
// the new value after being decremented or an error. If the value
// didn't exist in nukvd the error is ErrCacheMiss. The value in
// nukvd must be an decimal number, or an error will be returned.
// On underflow, the new value is capped at zero and does not wrap
// around.
/*
func (c *Client) Decrement(key string, delta uint64) (newValue uint64, err error) {
	return c.incrDecr("decr", key, delta)
}

func (c *Client) incrDecr(verb, key string, delta uint64) (uint64, error) {
	var val uint64
	err := c.withKeyRw(key, func(rw *bufio.ReadWriter) error {
		line, err := writeReadLine(rw, "%s %s %d\r\n", verb, key, delta)
		if err != nil {
			return err
		}
		switch {
		case bytes.Equal(line, resultNotFound):
			return ErrCacheMiss
		case bytes.HasPrefix(line, resultClientErrorPrefix):
			errMsg := line[len(resultClientErrorPrefix) : len(line)-2]
			return errors.New("nukv: client error: " + string(errMsg))
		}
		val, err = strconv.ParseUint(string(line[:len(line)-2]), 10, 64)
		if err != nil {
			return err
		}
		return nil
	})
	return val, err
}
*/