"""Check device-busy guards, stale-status races, duplicate clicks and draft retention."""
import queue
import sys
import tkinter as tk
from pathlib import Path
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'src/host'))
from client import Worker
from gui import App


class Device:
    def __init__(self, busy=False):
        self.busy = busy
        self.status = None
        self.calls = []

    def command(self, command, payload=b''):
        self.calls.append((command, payload))
        if command == 5:
            self.status = {'fsk_active': int(self.busy)}
        return SimpleNamespace(seq=1)


worker = Worker('fixture')
worker.client = Device(busy=True)
worker.execute_command((8, b'\x01\x50\x04\x1a\x01'))
assert [c[0] for c in worker.client.calls] == [5]
assert worker.events.get_nowait()['kind'] == 'notice'
worker.client.busy = False
worker.execute_command((8, b'\x01\x50\x04\x1a\x01'))
assert [c[0] for c in worker.client.calls] == [5, 5, 8, 5]
assert worker.events.get_nowait()['kind'] == 'ack'

root = tk.Tk()
root.withdraw()
app = App(root)
app.worker = SimpleNamespace(is_alive=lambda: True, tasks=queue.Queue(), events=queue.Queue())
app.enable(True)
app.variables['jamamp'].set('80')
app.variables['jamhz'].set('1050')
for key in ('run_requested', 'fsk_active', 'frame_active', 'test_running', 'test_pending'):
    app.last_status = {key: 1}
    app.refresh_jammer_control()
    assert str(app.jammer_button['state']) == 'disabled'
    app.apply_jammer()
    assert app.worker.tasks.empty()
    assert 'unchanged' in app.message.get()
app.last_status = {'fsk_active': 0}
app.refresh_jammer_control()
assert str(app.jammer_button['state']) == 'normal'
app.apply_jammer()
app.apply_jammer()
assert app.worker.tasks.qsize() == 1
assert str(app.jammer_button['state']) == 'disabled'
app.worker.events.put({'kind': 'error', 'command': 8, 'message': 'BUSY'})
app.poll()
assert 8 not in app.pending_commands
assert 'jamamp' in app.dirty_fields
assert 'Device busy' in app.message.get() and '{' not in app.message.get()
app.apply_jammer()
assert app.worker.tasks.qsize() == 2
app.worker.events.put({'kind': 'ack', 'command': 8, 'payload': '0050041a'})
app.poll()
assert 'jamamp' not in app.dirty_fields
assert 8 not in app.pending_commands
app.worker.events.put({'kind': 'disconnected', 'message': 'fixture disconnected'})
app.poll()
assert app.last_status is None and not app.pending_commands
assert str(app.jammer_button['state']) == 'disabled'
root.destroy()
message = 'PASS GUI busy: active/pending guards, fresh status, duplicate clicks, BUSY draft retention, ACK and disconnect'
(ROOT/'sim/host_results/gui_busy_check.log').write_text(message+'\n', encoding='ascii')
print(message)
