"""Decode actual RTL UART bytes with the independent host codec and export CSV."""
import csv
import sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'src/host'))
from protocol import Parser, Snapshots, ACK, NACK, PONG
from client import Client

folder = ROOT/'data'/'simulation'/'tb_uart_system'
data = bytes.fromhex((folder/'uart_tx.hex').read_text())
parser = Parser()
packets = parser.feed(data)
assert parser.errors == 0
assembler = Snapshots()
snapshots = [s for s in (assembler.feed(p) for p in packets) if s]
reports = [s for s in snapshots if s['kind']=='report']
statuses = [s for s in snapshots if s['kind']=='status']
assert statuses and reports
assert any(not s['trad_valid'] and not s['ai_valid'] and s['trad_ber'] is None for s in reports)
assert any(s['trad_errors']==2 and s['trad_bits']==768 and not s['ai_valid'] for s in reports)
assert any(s['trad_errors']==2 and s['ai_errors']==5 and s['ai_bits']==512 for s in reports)
assert any(s['tx_frames']==2 and s['test_frames']==2 and s['flags'] & 2 for s in reports)
assert any(s['config_id']==1 and s['fsk_active_config']['offset_hz']==-100 and s['rtl_version']==0x30003 for s in reports)
assert any(s['dds_active']['hz']==1700 and s['dds_active']['wave']==3 and s['knob_mode']==2 for s in statuses)
assert any(p.cmd==NACK and p.payload[1]==1 for p in packets)
assert any(p.cmd==NACK and p.payload[1]==6 for p in packets)
class CaptureSerial:
    def __init__(self,*args,**kwargs): self.data=data
    def read(self,n): out=self.data; self.data=b''; return out
client = Client('rtl-capture',factory=CaptureSerial)
client.read()
target = folder/'rtl_statistics.csv'
client.export_csv(target,'RTL simulation only; no analog receiver connected')
with target.open(encoding='utf-8-sig') as handle: rows=list(csv.DictReader(handle))
assert len(rows)==len(reports)
for row,report in zip(rows,reports):
    for key in ('config_id','run_id','tx_frames','dac_clips','test_frames','trad_errors','trad_bits','ai_errors','ai_bits',
                'trad_offset_estimate','trad_agc_exponent','ai_offset_estimate','ai_agc_exponent'):
        assert int(row[key])==report[key]
    for branch in ('trad','ai'):
        if not report[branch+'_valid']: assert row[branch+'_ber']==''
        else: assert float(row[branch+'_ber'])==report[branch+'_ber']
assert any(s['trad_offset_estimate']==-42 and s['ai_agc_exponent']==-2 for s in reports)
assert all(s['protocol_version']==2 for s in snapshots)
assert {s['request_seq'] for s in statuses}=={10,14}
message='PASS UART capture: %d packets, %d complete snapshots, %d CSV rows, exact raw counters' % (len(packets),len(snapshots),len(rows))
(folder/'host_decode.log').write_text(message+'\n',encoding='ascii')
print(message)
