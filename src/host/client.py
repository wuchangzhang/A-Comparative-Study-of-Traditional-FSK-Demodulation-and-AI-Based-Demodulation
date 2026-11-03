"""Serial transport with one outstanding transaction and idempotent retries."""
import csv
import json
import queue
import threading
import time
import uuid
from datetime import datetime, timezone
from protocol import Packet, Parser, Snapshots, ACK, NACK, STATUS, REPORT, PONG, ERRORS


class Client:
    def __init__(self, port, baud=115200, factory=None, callback=None, records=()):
        if factory is None:
            import serial
            factory = serial.serial_for_url
        self.serial = factory(port, baudrate=baud, timeout=0.03, write_timeout=1)
        self.callback = callback or (lambda event: None)
        self.seq = 0
        self.parser = Parser()
        self.snapshots = Snapshots()
        self.status = None
        self.configurations = {}
        self.closed = False
        self.records = list(records)
        self.session_id = uuid.uuid4().hex

    def close(self):
        if not self.closed:
            self.closed = True
            self.serial.close()

    def read(self):
        packets = self.parser.feed(self.serial.read(256))
        for packet in packets:
            snapshot = self.snapshots.feed(packet)
            if snapshot:
                snapshot['time_utc'] = datetime.now(timezone.utc).isoformat()
                snapshot['session_id'] = self.session_id
                if snapshot['kind'] == 'status':
                    self.status = snapshot
                    self.configurations[snapshot['config_id']] = snapshot
                else:
                    snapshot['configuration'] = {
                        'fsk_active_config': snapshot['fsk_active_config'],
                        'rtl_version': snapshot['rtl_version'],
                        'last_status': self.configurations.get(snapshot['config_id'])}
                    self.records.append(snapshot)
                self.callback(snapshot)
        return packets

    def command(self, cmd, payload=b'', timeout=0.7, retries=2):
        self.seq = (self.seq + 1) & 0xffff
        packet = Packet(cmd, self.seq, payload)
        encoded = packet.encode()
        for attempt in range(retries + 1):
            self.serial.write(encoded)
            deadline = time.monotonic() + timeout
            ack = None
            while time.monotonic() < deadline:
                for response in self.read():
                    if response.seq == packet.seq and response.cmd in (ACK, NACK, PONG):
                        if response.cmd == NACK:
                            raise ValueError(ERRORS.get(response.payload[1], 'UNKNOWN_ERROR'))
                        ack = response
                if ack is not None and (cmd != 5 or (self.status is not None and
                        self.status['protocol_version'] == 2 and self.status['request_seq'] == packet.seq)):
                    return ack
        raise TimeoutError('No response for sequence %d after %d attempts' % (packet.seq, retries+1))

    def connect(self):
        self.serial.reset_input_buffer()
        pong = self.command(6)
        if pong.cmd != PONG or len(pong.payload) != 5 or pong.payload[0] != 2:
            raise ValueError('Firmware protocol 2 required; update FPGA bitstream')
        self.parser = Parser()
        self.snapshots = Snapshots()
        self.status = None
        self.command(5)

    def export_csv(self, path, snr_conditions='Uncalibrated'):
        fields = ['time_utc', 'session_id', 'protocol_version', 'rtl_version', 'config_id', 'snapshot_id', 'run_id', 'flags', 'tx_frames',
                  'dac_clips', 'test_frames', 'adc_errors', 'adc_clips', 'dropped_reports',
                  'trad_valid', 'trad_errors', 'trad_bits', 'trad_ber', 'trad_crc_failures',
                  'trad_captured_frames', 'trad_lost_frames', 'ai_valid', 'ai_errors',
                  'ai_bits', 'ai_ber', 'ai_crc_failures', 'ai_captured_frames', 'ai_lost_frames',
                  'trad_model_version', 'ai_model_version', 'final', 'incomplete',
                  'trad_incomplete', 'ai_incomplete', 'trad_offset_estimate', 'trad_agc_exponent',
                  'ai_offset_estimate', 'ai_agc_exponent', 'configuration', 'snr_conditions',
                  'jam_enable', 'jam_amplitude', 'jam_hz', 'jam_burst']
        with open(path, 'w', newline='', encoding='utf-8-sig') as handle:
            writer = csv.DictWriter(handle, fieldnames=fields, extrasaction='ignore')
            writer.writeheader()
            for record in self.records:
                row = dict(record, snr_conditions=snr_conditions)
                row['configuration'] = json.dumps(record.get('configuration'), ensure_ascii=False)
                writer.writerow(row)


class Worker(threading.Thread):
    """All serial access stays on this thread; Tk only exchanges queued events."""
    def __init__(self, port, records=()):
        super().__init__(daemon=True)
        self.port = port
        self.tasks = queue.Queue()
        self.events = queue.Queue()
        self.stop_event = threading.Event()
        self.client = None
        self.records = tuple(records)

    def execute_command(self, args):
        # Check fresh telemetry on the serial thread, including races with board keys.
        if args[0] == 8:
            self.client.command(5)
            status = self.client.status or {}
            if not status or any(status.get(key, 0) for key in
                                 ('run_requested', 'fsk_active', 'frame_active', 'test_running', 'test_pending')):
                self.events.put({'kind': 'notice', 'command': 8,
                                 'message': 'Interference unchanged. Stop / Exit FSK and wait, then apply again.'})
                return
        response = self.client.command(*args)
        self.events.put({'kind': 'ack', 'seq': response.seq,
                         'command': args[0], 'payload': args[1].hex()})
        self.client.command(5)

    def run(self):
        try:
            self.client = Client(self.port, callback=self.events.put, records=self.records)
            self.client.connect()
            self.events.put({'kind': 'connected'})
            next_status = time.monotonic() + 1
            while not self.stop_event.is_set():
                try:
                    action, args = self.tasks.get_nowait()
                except queue.Empty:
                    action, args = None, None
                try:
                    if action == 'command':
                        self.execute_command(args)
                    elif action == 'export':
                        self.client.export_csv(*args)
                        self.events.put({'kind': 'exported', 'path': args[0]})
                    else:
                        self.client.read()
                    if time.monotonic() >= next_status:
                        self.client.command(5)
                        next_status = time.monotonic() + 1
                except ValueError as exc:
                    self.events.put({'kind': 'error', 'command': args[0] if action == 'command' else None,
                                     'message': str(exc)})
        except Exception as exc:
            self.events.put({'kind': 'disconnected', 'message': str(exc)})
        finally:
            if self.client:
                self.client.close()
