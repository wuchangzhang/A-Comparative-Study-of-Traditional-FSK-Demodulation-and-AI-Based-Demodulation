"""Real pyserial socket transport and CLI/Worker smoke checks using RTL telemetry.

The local endpoint is a protocol fixture, not a hardware receiver or BER source.
"""
import socket
import struct
import subprocess
import sys
import threading
import time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'src/host'))
from protocol import Parser, Packet, ACK, PONG, STATUS, REPORT
from client import Worker

packets=Parser().feed(bytes.fromhex((ROOT/'data'/'simulation'/'tb_uart_system'/'uart_tx.hex').read_text()))
def complete_pages(command):
    groups={}
    for packet in packets:
        if packet.cmd==command:
            groups.setdefault(packet.payload[3:11],{})[packet.payload[1]]=packet
    return next([g[i] for i in range(3)] for g in reversed(list(groups.values())) if len(g)==3)
status=complete_pages(STATUS)
report=complete_pages(REPORT)
assert len(status)==len(report)==3
server=socket.socket()
server.bind(('127.0.0.1',0)); server.listen(); server.settimeout(.1)
port=server.getsockname()[1]
stop=threading.Event()
def serve():
    while not stop.is_set():
        try: connection,_=server.accept()
        except socket.timeout: continue
        with connection:
            parser=Parser(); connection.settimeout(.1)
            while not stop.is_set():
                try: data=connection.recv(4096)
                except socket.timeout: continue
                except OSError: break
                if not data: break
                for packet in parser.feed(data):
                    if packet.cmd==6: responses=[Packet(PONG,packet.seq,struct.pack('>BI',2,0x30003))]
                    else: responses=[Packet(ACK,packet.seq,bytes([packet.cmd,packet.cmd!=5])+struct.pack('>I',1))]
                    if packet.cmd==5: responses += [Packet(p.cmd,packet.seq,p.payload) for p in status]+report
                    stream=b''.join(p.encode() for p in responses)
                    try:
                        for offset in range(0,len(stream),17): connection.sendall(stream[offset:offset+17])
                    except OSError: break
thread=threading.Thread(target=serve,daemon=True); thread.start()
url='socket://127.0.0.1:%d'%port
try:
    result=subprocess.run([sys.executable,str(ROOT/'src/host'/'cli.py'),'--port',url,'dds','--hz','1200','--amplitude','128','--wave','3'],
                          capture_output=True,text=True,timeout=15)
    assert result.returncode==0,result.stderr
    assert '"kind": "status"' in result.stdout and '"kind": "report"' in result.stdout
    (ROOT/'sim'/'host_results'/'cli_transport.log').write_text('LOCAL FIXTURE ONLY\n'+result.stdout,encoding='utf-8')
    worker=Worker(url); worker.start(); events=[]; deadline=time.monotonic()+5
    while time.monotonic()<deadline:
        try: event=worker.events.get(timeout=.1); events.append(event)
        except Exception: continue
        if event['kind']=='connected': worker.tasks.put(('command',(3,b'\x01')))
        if event['kind']=='ack': break
    worker.stop_event.set(); worker.join(3)
    assert not worker.is_alive()
    assert any(e['kind']=='connected' for e in events) and any(e['kind']=='ack' for e in events)
    assert any(e['kind']=='status' for e in events)
    saved=list(worker.client.records)
    assert saved
    reconnected=Worker(url,records=saved); reconnected.start()
    deadline=time.monotonic()+5
    while time.monotonic()<deadline:
        event=reconnected.events.get(timeout=1)
        if event['kind']=='connected': break
    reconnected.stop_event.set(); reconnected.join(3)
    assert not reconnected.is_alive()
    assert reconnected.client.records[:len(saved)]==saved
    assert reconnected.client.session_id!=worker.client.session_id
    (ROOT/'sim'/'host_results'/'host_transport.log').write_text('PASS pyserial socket, CLI DDS, Worker connect/command/close, reconnect records and session IDs; local protocol fixture only\n',encoding='ascii')
    print('PASS real pyserial transport: CLI + Worker + reconnect record retention using local fixture and RTL-generated telemetry')
finally:
    stop.set(); thread.join(2); server.close()
