"""Protocol and GUI checks for the optional payload-burst extension."""
import struct
import sys
import tkinter as tk
from pathlib import Path

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'src/host'))
from protocol import Packet, REPORT, Snapshots, jammer_payload
from gui import App

assert jammer_payload(1,80,1050)==bytes.fromhex('0150041a')
assert jammer_payload(1,80,1050,True)==bytes.fromhex('0150041a01')
pages=[bytearray(48) for _ in range(3)]
pages[1][36:40]=bytes.fromhex('0350041a')
assembly=Snapshots()
result=None
for i,page in enumerate(pages):
    result=assembly.feed(Packet(REPORT,7,struct.pack('>BBBII',2,i,3,1,2)+page))
assert (result['jam_enable'],result['jam_burst'],result['jam_amplitude'],result['jam_hz'])==(1,1,80,1050)
root=tk.Tk()
root.withdraw()
app=App(root)
sent=[]
app.send=lambda cmd,payload: sent.append((cmd,payload))
app.jam.set(1)
app.variables['jamamp'].set('80')
app.variables['jamhz'].set('1050')
app.jam_mode.current(1)
app.mark_dirty('jam_mode')
app.apply_jammer()
assert sent==[(8,bytes.fromhex('0150041a01'))]
app.acknowledge_edit(dict(command=8,payload=sent[-1][1].hex()))
assert not ({'jam','jamamp','jamhz','jam_mode'} & app.dirty_fields)
root.destroy()
print('PASS check_burst_host: legacy/extended command, frozen report mode, GUI selection and ACK')
