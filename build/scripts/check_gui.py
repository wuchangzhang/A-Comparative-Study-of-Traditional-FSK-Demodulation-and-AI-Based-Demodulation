"""Exercise Tk views using decoded RTL telemetry at both supported sizes."""
import sys
import tkinter as tk
import struct
from unittest.mock import patch
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'src/host'))
from gui import App
from protocol import Parser, Snapshots
root=tk.Tk()
app=App(root)
assert tuple(app.wave['values']) == ('Sine','Square','Triangle','Sawtooth')
app.wave.current(3)
sent=[]
app.send=lambda cmd,payload=b'': sent.append((cmd,payload))
app.apply_dds()
assert sent[-1][0]==1 and sent[-1][1][4]==3
assembler=Snapshots()
capture=ROOT/'data'/'simulation'/'tb_uart_system'/'uart_tx.hex'
snapshots=[s for s in (assembler.feed(p) for p in Parser().feed(bytes.fromhex(capture.read_text()))) if s]
for event in snapshots:
    if event['kind']=='status': app.render_status(event)
    else: app.render_report(event)
status=app.last_status
assert app.number('hz')==status['dds_requested']['hz']
assert app.number('amp')==status['dds_requested']['amplitude']
app.variables['hz'].set('1430')
changed=dict(status,dds_requested=dict(status['dds_requested'],amplitude=99))
app.render_status(changed)
assert app.number('hz')==1430 and app.number('amp')==99
app.apply_dds()
submitted=sent[-1][1]
assert struct.unpack('>IBBh',submitted)[0]==1430
assert struct.unpack('>IBBh',submitted)[2]==99
app.variables['hz'].set('1440')
app.acknowledge_edit({'command':1,'payload':submitted.hex()})
app.render_status(changed)
assert app.number('hz')==1440
app.apply_dds()
app.acknowledge_edit({'command':1,'payload':sent[-1][1].hex()})
app.render_status(changed)
assert app.number('hz')==changed['dds_requested']['hz']
app.variables['offset'].set('-50')
app.apply_fsk()
assert 'offset' in app.dirty_fields
app.acknowledge_edit({'command':2,'payload':sent[-1][1].hex()})
assert 'offset' not in app.dirty_fields
app.variables['scale'].set('256')
app.noise.set(0)
app.acknowledge_edit({'command':4,'payload':struct.pack('>BH',0,256).hex()})
assert 'scale' not in app.dirty_fields and 'noise' not in app.dirty_fields
from types import SimpleNamespace
saved=[{'config_id':7,'session_id':'old','time_utc':'old'}]
app.worker=SimpleNamespace(is_alive=lambda:False,client=SimpleNamespace(records=saved))
app.port.set('fixture')
with patch('gui.Worker') as worker:
    app.connect()
    assert worker.call_args.kwargs['records']==saved
app.worker=None
app.enable(True)
messages=['PASS GUI sawtooth selection encodes wave=3',
          'PASS GUI readback fills untouched fields, drafts survive status/older ACK, DDS/FSK/noise ACKs clear accepted drafts',
          'PASS GUI reconnect carries prior session records into the new Worker']
for width,height in ((980,740),(800,640)):
    root.geometry('%dx%d'%(width,height)); root.update()
    for widget in (app.table,app.message_label):
        assert widget.winfo_rootx()+widget.winfo_width()<=root.winfo_rootx()+width
        assert widget.winfo_rooty()+widget.winfo_height()<=root.winfo_rooty()+height
    rows={app.table.item(item,'text'):app.table.item(item,'values') for item in app.table.get_children()}
    assert rows['Errors / bits'][1]=='5 / 512'
    assert 'Lost frames' in rows and 'Dropped reports' in app.stats_text.get()
    messages.append('PASS GUI %dx%d: telemetry render, bounds, independent branch BER'%(width,height))
(ROOT/'sim'/'host_results'/'gui_check.log').write_text('\n'.join(messages)+'\n',encoding='ascii')
print('\n'.join(messages))
root.destroy()
