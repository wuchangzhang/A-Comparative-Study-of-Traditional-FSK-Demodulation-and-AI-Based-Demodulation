"""Capture the actual Tk window with offline RTL telemetry, without opening a port."""
import sys
import time
import tkinter as tk
from pathlib import Path
from PIL import ImageGrab

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'src/host'))
from gui import App
from protocol import Parser, Snapshots

root = tk.Tk()
app = App(root)
root.title('EGO1 final GUI - OFFLINE RTL replay')
assembler = Snapshots()
data = bytes.fromhex((ROOT/'data/simulation/tb_uart_system/uart_tx.hex').read_text())
for packet in Parser().feed(data):
    event = assembler.feed(packet)
    if event:
        (app.render_status if event['kind']=='status' else app.render_report)(event)
app.connection_status.set('Offline RTL replay')
app.note('Offline preview; no serial device connected')
out = ROOT/'data/gui_preview'
out.mkdir(parents=True, exist_ok=True)
for width, height in ((980, 740), (800, 640)):
    root.geometry(f'{width}x{height}+30+30')
    root.attributes('-topmost', True)
    root.update()
    time.sleep(0.3)
    root.update()
    bounds = (root.winfo_rootx(), root.winfo_rooty(),
              root.winfo_rootx()+width, root.winfo_rooty()+height)
    picture = ImageGrab.grab(bbox=bounds, all_screens=True)
    assert any(low != high for low, high in picture.getextrema())
    picture.save(out/f'gui_{width}x{height}.png')
    app.control_tabs.select(1)
    root.update()
    time.sleep(0.2)
    ImageGrab.grab(bbox=bounds, all_screens=True).save(out/f'interference_{width}x{height}.png')
    app.control_tabs.select(0)
root.destroy()
print('PASS GUI screenshots: two window sizes, offline RTL telemetry only')
