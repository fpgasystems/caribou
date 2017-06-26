package ch.ethz.zookeeper;


import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStreamReader;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.net.UnknownHostException;
import java.nio.ByteBuffer;
import java.nio.channels.SelectionKey;
import java.nio.channels.Selector;
import java.nio.channels.ServerSocketChannel;
import java.nio.channels.SocketChannel;
import java.util.HashMap;
import java.util.LinkedList;
import java.util.Queue;
import java.util.concurrent.ArrayBlockingQueue;

public class Node implements Runnable {

	private int port;
	private ServerSocketChannel serverSocketChannel;
	private Selector selector;
	private HashMap<SelectionKey, SocketChannel> channelMap;	
	private Queue<Request> requestQueue;
	
	private Queue<SocketChannel> socketQueue;
	
	private HashMap<Long, SocketChannel> rsockMap;
	
	
	private byte myId;
	private byte leaderId;
	
	private int peerCnt;
	
	private Socket[] peerSockets;	
	private long[] proposedZxid;
	private long[] ackedZxid;
	private long[] commitedZxid;
	private long myZxid;
	private long myEpoch = 1;
	private long myIpAddr;
	private boolean iAmLeader;
	private boolean knowLeader;
	
	
	public Node(int port) throws IOException {

		this.port = port;
		
		serverSocketChannel = ServerSocketChannel.open();
		serverSocketChannel.socket().bind(new InetSocketAddress("129.132.102.231", this.port));
		serverSocketChannel.configureBlocking(false);
		
		this.channelMap = new HashMap<SelectionKey, SocketChannel>();
		this.requestQueue = new LinkedList<Request>();
		
		selector = Selector.open();
		
		knowLeader = false;
		
		
		peerSockets = new Socket[32];
		proposedZxid = new long[32];
		ackedZxid = new long[32];
		commitedZxid = new long[32];
		
		for (int x=0; x<32; x++) {
			proposedZxid[x]=0;
			ackedZxid[x]=0;
			commitedZxid[x]=0;
		}
		
		peerCnt=0;
		
		rsockMap = new HashMap<Long, SocketChannel>();
		socketQueue = new LinkedList<SocketChannel>();
	}

	@Override
	public void run() {
		ByteBuffer buf = ByteBuffer.allocate(1024*16*1024);
		int processed = 0;
		byte[] bufB = new byte[0];
		
		while (true){
			try {
				int selected = 0;
								
				if (!knowLeader || iAmLeader) {
					
					//System.out.println("   "+this.port+" accepting");
					
						SocketChannel socketChannel =  serverSocketChannel.accept();
						if (socketChannel!=null) {
							System.out.println(this+";; new connection");
							socketChannel.configureBlocking(false);
							SelectionKey key = socketChannel.register(selector, SelectionKey.OP_READ);
							channelMap.put(key, socketChannel);
						}
				}
				
				//System.out.println("   "+this+" selecting");
				if (!knowLeader || iAmLeader) {
					selected = selector.select(100);
				} else {
					selected = selector.select();
				}							
				
				if (selected>0) {		
					
					//System.out.println("   "+this+" selected");
					
					
					
					for (SelectionKey key : selector.selectedKeys()) {
						SocketChannel sc = channelMap.get(key);
						
						//System.out.println("   "+buf.remaining());
						int cnt = sc.read(buf);								
						buf.flip();
																
						if (cnt>0) {
							System.out.println(this+" "+cnt);
							
							if (bufB.length>0) {
								byte[] bufX = new byte[cnt+bufB.length];
								
								for (int r=0; r<bufB.length; r++) {
									bufX[r]=bufB[r];
								}
								for (int r=0; r<cnt; r++) {
									bufX[bufB.length+r] = buf.get(r);
								}
								cnt += bufB.length;
								bufB = bufX.clone();								
							} else {
								bufB = new byte[cnt];
								for (int r=0; r<cnt; r++) {
									bufB[r] = buf.get(r);
								}
							}
							
							processed = 0;
							
							while (processed<cnt) {													
								Request req = Request.parse(bufB);
								if (req!=null) {
									this.requestQueue.add(req);
									this.socketQueue.add(sc);
									processed += 16+req.getPaylSize();
								}
								else {	
									if (cnt>16) {
										System.out.println("Could not process x"+cnt);
									}
									break;
								}								
																
								byte[] bufX = new byte[cnt-processed];
								
								System.out.println(bufX.length);
								System.out.println(bufB.length);
								
								for (int r=processed; r<cnt; r++) {								
									bufX[r-processed] = bufB[r];									
								}
								bufB=bufX.clone();
								cnt -= processed;
								processed = 0;
							}
							
							if (processed>=cnt) {
								bufB = new byte[0];
							} 
							
						}
						
						buf.clear();
						
						
					}
					
					selector.selectedKeys().clear();
					
					
										
				}
				
				int proc = 0;
				
				while (!requestQueue.isEmpty()) {
					process(requestQueue.poll(), socketQueue.poll());
					proc++;			
					
					if (proc>64) {
						for (int p=0; p<32; p++) {
							if (peerSockets[p]==null) continue;
							
							peerSockets[p].getOutputStream().flush();
						}
					}
				}
				
				
				
				
				
				//Thread.sleep(500);
			} catch (Exception  e) {
				// TODO Auto-generated catch block
				e.printStackTrace();
			}
			
		}
		
	}

	private void process(Request r, SocketChannel source) {
		
		int opcode = r.getOpCode();
		
		switch (opcode) {
		case Request.OPCODE_SETUPPEER:
			System.out.println(this+"SETUPPEER w ID:"+r.getPeerId());
			myId = r.getPeerId();
			myZxid = r.getZxid();
			myIpAddr = r.getEpoch();
			
			break;
		
		case Request.OPCODE_ADDPEER:
			System.out.print(this+"ADDPEER w ID:"+r.getPeerId());
			int pid = r.getPeerId();
			int[] parts = new int[4];
			
			long addrB = r.getEpoch();
			long port = r.getZxid();
			parts[0]= (int) (addrB/(1)%256);
			parts[1]= (int) (addrB/(256)%256);
			
			parts[2]= (int) (addrB/(256*256)%256);
			parts[3]= (int) (addrB/(256*256*256)%256);
			
			
			try {
				String addr = ""+parts[3]+"."+parts[2]+"."+parts[1]+"."+parts[0];
				System.out.println(this+" (IP:"+addr+" PORT:"+port+")");
				peerSockets[pid] = new Socket(addr, (int)port);
				peerSockets[pid].setSendBufferSize(1024);
				peerCnt++;
			} catch (IOException e) {
				// TODO Auto-generated catch block
				e.printStackTrace();				
			}
			break;
			

		case Request.OPCODE_SETLEADER:
			System.out.println(this+"SETLEADER w ID:"+r.getPeerId());
			leaderId = r.getPeerId();
			if (leaderId==myId) {
				this.iAmLeader=true;
			}
			knowLeader=true;
			break;
			
		case Request.OPCODE_WRITEREQ:			
			if (iAmLeader) {
				System.out.println(this+"WRITEREQ -- sending proposals");
				Request prop = new Request(Request.OPCODE_PROPOSAL, myId, myZxid+1, myEpoch, r.getPaylSize(), r.getPayload());
				for (int x=0; x<peerSockets.length; x++) {
					if (peerSockets[x]==null) continue;
					try {						
						peerSockets[x].getOutputStream().write(prop.getByteArray());
						proposedZxid[x]=(int) (myZxid+1);
						//System.out.println(this+" -- sent proposal to ID"+x);						
					} catch (IOException e) {
						// TODO Auto-generated catch block
						e.printStackTrace();
					}
				}
				
				rsockMap.put(myZxid+1, source);
				
			} else {
				System.out.println(this+"WRITEREQ -- not leader");
			}
			break;
			
		case Request.OPCODE_ACKPROPOSE:
			if (iAmLeader) {
				//System.out.println(this+"ACKPROP from "+r.getPeerId());
				long acked = r.getZxid();
				if (acked==ackedZxid[r.getPeerId()]+1) {
					boolean majorityAcked = false;
					int cnt = 0;
					int cntCmt = 0;
					for (int x=0; x<32; x++) {
						if (ackedZxid[x]==acked) cnt++;
						if (commitedZxid[x]>=acked) cntCmt++;
					}
					
					ackedZxid[r.getPeerId()] = acked;
					
					Request com = new Request(Request.OPCODE_COMMIT, myId, r.getZxid(), r.getEpoch());
					
					if ((cnt+1)>((peerCnt+1)/2) && cntCmt==0) {
						// if majority
						
						myZxid=r.getZxid();
						
						for (int x=0; x<32; x++) {
							if (peerSockets[x]==null || ackedZxid[x]<r.getZxid()) continue;
							
							try {						
								peerSockets[x].getOutputStream().write(com.getByteArray());
								commitedZxid[x]= r.getZxid();								
								
								//System.out.println(this+" -- sent commit to ID"+x);
							} catch (IOException e) {
								// TODO Auto-generated catch block
								e.printStackTrace();
							}
						
						}
						
						SocketChannel s = rsockMap.get(r.getZxid());
						if (s!=null) {
							Request done = new Request((byte) 0, (byte) myId, r.getZxid(), r.getEpoch());
							try {
								s.write(ByteBuffer.wrap(done.getByteArray()));
							} catch (IOException e) {
								// TODO Auto-generated catch block
								e.printStackTrace();
							}							
						}
					} else {
						if (commitedZxid[r.getPeerId()]==r.getZxid()-1 && myZxid>=r.getZxid()) {
							if (peerSockets[r.getPeerId()]!=null) {
								try {
									peerSockets[r.getPeerId()].getOutputStream().write(com.getByteArray());
									commitedZxid[r.getPeerId()] = r.getZxid();
									//System.out.println(this+" -- sent commit just to ID"+r.getPeerId());
								} catch (IOException e) {
									// TODO Auto-generated catch block
									e.printStackTrace();
								}
							}
						}
					}
				}
			} else {
				System.out.println(this+"ACKPROP -- not leader");
			}
			break;
			
		case Request.OPCODE_PROPOSAL:
			//if (!iAmLeader && peerSockets[r.getPeerId()]!=null) {
				
				System.out.println(this+"PROPOSAL -- zxid"+r.getZxid());
				if (myZxid==r.getZxid()-1) {
					Request ack = new Request(Request.OPCODE_ACKPROPOSE, myId, r.getZxid(), r.getEpoch());
					try {						
						peerSockets[r.getPeerId()].getOutputStream().write(ack.getByteArray());
						System.out.println(this+" -- sent ack to ID"+r.getPeerId());
					} catch (IOException e) {
						// TODO Auto-generated catch block
						e.printStackTrace();
					}
				} else {
					Request ack = new Request(Request.OPCODE_SYNCREQ, myId, 1, 1);
					try {						
						peerSockets[r.getPeerId()].getOutputStream().write(ack.getByteArray());
						System.out.println(this+" -- sent ack to ID"+r.getPeerId());
					} catch (IOException e) {
						// TODO Auto-generated catch block
						e.printStackTrace();
					}
				}
			//} else {
			//	System.out.println(this+"PROPOSAL -- i am leader or no such peer");
			//}
			break;
			
		case Request.OPCODE_COMMIT:
			if (!iAmLeader && r.getZxid()==myZxid+1) {
				System.out.println(this+"COMMIT -- now at zxid "+r.getZxid());
				myZxid=r.getZxid();
			} else {
				System.out.println(this+"COMMIT -- bogus zxid -- expected "+(myZxid+1)+" got "+r.getZxid());
			}
			
			break;
			
		case Request.OPCODE_SYNCRESP:
			System.out.println(this+"SYNCRESP -- zxid"+r.getZxid());
			
			break;
			
		case Request.OPCODE_SYNCRESP_BULK:
			System.out.println(this+"SYNCRESP -- "+r.getEpoch()+" = "+((r.getEpoch()*64)/1024/1024));
			/*if (r.getPaylSize()>0) {
				for (byte x : r.getPayload()) {
					System.out.print(x+" ");
				}
			}*/
			//System.out.println();
			break;
			
		default:
			System.out.println(this+"OPCODE:"+r.getOpCode());
			break;
		}
		
	}
	
	@Override
	public String toString() {
		// TODO Auto-generated method stub
		return "Node"+this.myId+" ";
	}
	
	public long getZxid() {
		return this.myZxid;
	}
	
	
	public static void main(String[] args) throws Exception {
		Integer myport = args.length>0 ? new Integer(args[0]) : 2888;
		Node n = new Node(myport);
		new Thread(n).start();
	}

}
