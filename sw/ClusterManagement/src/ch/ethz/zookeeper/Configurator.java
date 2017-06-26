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

import java.io.IOException;
import java.net.Socket;
import java.net.UnknownHostException;
import java.nio.ByteBuffer;

public class Configurator {

	public static void main(String[] args) throws UnknownHostException, IOException, InterruptedException {
		
		String[] peers = args[0].split(";");
		boolean justAddOne = false;
		int peerCnt = peers.length;
		
		if (args.length>1) {
			// we need to add new peers. this is different
			justAddOne = true;
			String[] peersNew = new String[peerCnt+1];
			
			for (int i=0; i<peerCnt; i++) {
				peersNew[i] = peers[i];
			}			
			peersNew[peerCnt] = args[1];
			
			peers = peersNew;
			peerCnt++;
			
		}
		
		
		
				
		long[] peerIp = new long[peerCnt];
		long[] peerPort = new long[peerCnt];
		byte[] peerId = new byte[peerCnt];
		Socket[] socks = new Socket[peerCnt];
	
		// set up peer ids and introduce them
		
		for (int i=0; i<peerCnt; i++) {
			String ipaddr = peers[i].split(":")[0];					
			int port = new Integer(peers[i].split(":")[1]);
			
			System.out.println("Connecting to "+ipaddr+":"+port);
			socks[i]=new Socket(ipaddr, port);
			
			peerPort[i]=port;
			String[] ipp = ipaddr.split("[.]");
			peerIp[i]= new Long(ipp[3])+new Long(ipp[2])*256+new Long(ipp[1])*256*256+new Long(ipp[0])*256*256*256;
			peerId[i]= (byte) (i+1);			
		}
		
		for (int i=0; i<peerCnt; i++) {
			if (justAddOne==false || i==peerCnt-1) {
				Request setup = new Request(Request.OPCODE_SETUPPEER, peerId[i], 0, 0);
				socks[i].getOutputStream().write(setup.getByteArray());
				socks[i].getOutputStream().flush();
			}
			
			Thread.sleep(500);
		}
		
		for (int i=0; i<peerCnt; i++) {
			for (int other=0; other<peerCnt; other++) {
				if (other==i || (justAddOne==true && other!=peerCnt-1 && i!=peerCnt-1)) continue;
				
				Request addp = new Request(Request.OPCODE_ADDPEER, peerId[other], peerPort[other], peerIp[other]);
				socks[i].getOutputStream().write(addp.getByteArray());
				socks[i].getOutputStream().flush();
				
				Thread.sleep(500);
			}
			
		}
		
		for (int i=0; i<peerCnt; i++) {
			if (justAddOne==false || i==peerCnt-1) {
				Request setlead = new Request(Request.OPCODE_SETLEADER, (byte)(1), 0, 0);
				socks[i].getOutputStream().write(setlead.getByteArray());
				socks[i].getOutputStream().flush();
			
				Thread.sleep(500);
			}
		}
		
		System.out.println("DONE!");					

	}

}
