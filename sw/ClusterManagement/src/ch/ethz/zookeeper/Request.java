//---------------------------------------------------------------------------
//--  Copyright 2015 - 2017 Systems Group, ETH Zurich
//-- 
//--  This hardware module is free software: you can redistribute it and/or
//--  modify it under the terms of the GNU General Public License as published
//--  by the Free Software Foundation, either version 3 of the License, or
//--  (at your option) any later version.
//-- 
//--  This program is distributed in the hope that it will be useful,
//--  but WITHOUT ANY WARRANTY; without even the implied warranty of
//--  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//--  GNU General Public License for more details.
//-- 
//--  You should have received a copy of the GNU General Public License
//--  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//---------------------------------------------------------------------------

package ch.ethz.zookeeper;

import java.math.BigDecimal;
import java.math.BigInteger;

public class Request {

	public static final byte OPCODE_SETUPPEER = 17;
	public static final byte OPCODE_ADDPEER = 18;
	public static final byte OPCODE_REMOVEPEER = 19;
	public static final byte OPCODE_SETLEADER = 20;
	
	public static final byte OPCODE_READREQ = 0;
	public static final byte OPCODE_WRITEREQ = 1;
	public static final byte OPCODE_PROPOSAL = 2;
	public static final byte OPCODE_ACKPROPOSE = 3;
	public static final byte OPCODE_COMMIT = 4;
	public static final byte OPCODE_SYNCREQ = 5;
	public static final byte OPCODE_SYNCRESP = 6;
	public static final byte OPCODE_SYNCCOMMIT = 7;
	
	public static final byte OPCODE_SETSILENCECNT = 26;
	
	public static final byte[] MAGIC = {(byte) 0xFF, (byte) 0xFF};
	
	private byte[] data;
	private byte[] payload;
	private boolean hasPayload;
	
	private byte opCode;
	private byte peerId;
	private long zxid;
	private long epoch;
	private int paylSize;
		
	
	private Request(byte opcode, byte peerid, long zxid, long epoch, int datasize) {
		super();
		
		data = new byte[datasize];			
		
		data[0]=MAGIC[0];
		data[1]=MAGIC[1];
		data[3]=opcode;
		data[2]=peerid;
		data[4]=0;
		data[5]=0;
		data[6]=0;
		data[7]=0;
		hasPayload=false;
		
		long aux = zxid;
		
		for (int x=0; x<4; x++) {
			data[8+x]=(byte) (aux%256);
			aux/=256;
		}

		aux = epoch;
		BigDecimal bi = new BigDecimal(aux);
		for (int x=0; x<4; x++) {
			data[12+x]=(bi.remainder(new BigDecimal(256)).byteValue());
			bi=bi.divide(new BigDecimal(256));
		}
		
		this.opCode = opcode;
		this.peerId = peerid;
		this.zxid=zxid;
		this.epoch = epoch;
		this.paylSize = 0;
	}
	
	public Request(byte opcode, byte peerid, long zxid, long epoch) {
		this(opcode, peerid, zxid, epoch, 16);			
	}
	
	public Request(byte opcode, byte peerid, long zxid, long epoch, int paylsize, byte[] payload) {
		this(opcode, peerid, zxid, epoch, 16+paylsize);
		
		int sizeInWords = (int) Math.ceil((float)paylsize/8.0);
		
		data[4]=(byte) (sizeInWords%256);
		data[5]=(byte) (sizeInWords/256);
		
		hasPayload=true;
		this.paylSize = paylsize;
		
		for (int x=0; x<paylsize; x++) {
			data[16+x]=payload[x];
		}
		
		this.payload=payload.clone();
	}
	
	public byte[] getByteArray() {
		/*StringBuilder s = new StringBuilder();
		s.append("00\n");
		for (int r =0; r<data.length/8; r++) {
			if (r!=data.length/8-1) {
				s.append("0");
			} else {
				s.append("1");
			}
			
			for (int i=0; i<8; i++) {
				s.append(String.format("%02X", data[r*8+i]));
			}
			
			s.append("\n");
		}
		System.err.println(s.toString());*/
		return data;
	}
	
	public byte[] getPayload() {
		return payload;
	}
	
	public boolean hasPayl(){
		return this.hasPayload;
	}
	
	public byte getOpCode() {
		return opCode;
	}

	public byte getPeerId() {
		return peerId;
	}

	public long getZxid() {
		return zxid;
	}

	public long getEpoch() {
		return epoch;
	}

	public int getPaylSize() {
		return paylSize;
	}
	

	public static Request parse(byte[] indata) {
		if (indata.length>=16) {
			if (indata[0]==(byte)0xff && indata[1]==(byte)0xff) {
				
				int paylsize = (int) fromBytes(indata, 4)*8;
				
				if (paylsize>=0 && indata.length>=16+paylsize) {
					
					byte opcode = indata[3];
					byte peerid = indata[2];
					
					long zxid = fromBytes(indata, 8);
					long epoch = fromBytes(indata, 12);
					
					if (paylsize==0) {
						return new Request(opcode, peerid, zxid, epoch);
					} else {
						byte[] pldata = new byte[(int) paylsize];
						
						for (int x=0; x<paylsize; x++){
							pldata[x]=indata[16+x];
						}
						
						return new Request(opcode, peerid, zxid, epoch, paylsize, pldata);
					}
						
					
				}
			}
		} else {
			System.out.println("what?");
		}
		
		return null;		
	}
	
	public static long fromBytes(byte[] arr, int pos) {		
		int[] iarr = new int[4];
		for (int r=0; r<4; r++) {
			iarr[r]=arr[pos+r]>=0 ? arr[pos+r] : arr[pos+r]+256;			
		}
		long number=0;
		for (int r=0; r<4; r++) {
			number = number*256+iarr[3-r];
		}
		return number;
	}
	 
}
