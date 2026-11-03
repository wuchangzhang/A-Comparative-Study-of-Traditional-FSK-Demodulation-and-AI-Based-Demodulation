import json
import queue
import struct
import tkinter as tk
from tkinter import ttk, filedialog
from client import Worker
from protocol import dds_payload, fsk_payload, jammer_payload


class App(ttk.Frame):
    def __init__(self, master):
        super().__init__(master, padding=14)
        self.pack(fill='both', expand=True)
        self.worker = None
        self.last_status = None
        self.variables = {}
        self.dirty_fields = set()
        self.updating_fields = False
        self.command_controls = []
        self.pending_commands = set()
        self.connected = False
        self.last_report = None
        master.title('EGO1 DDS / FSK - Traditional and AI')
        master.geometry('980x740')
        master.minsize(800, 640)
        self.columnconfigure(1, weight=1)
        self.rowconfigure(1, weight=1)
        connection = ttk.Frame(self)
        connection.grid(row=0, column=0, columnspan=2, sticky='ew', pady=(0, 12))
        ttk.Label(connection, text='Serial port').pack(side='left')
        self.port = ttk.Combobox(connection, width=16, values=self.ports())
        self.port.pack(side='left', padx=8)
        self.connect_button = ttk.Button(connection, text='Connect', command=self.connect)
        self.connect_button.pack(side='left')
        ttk.Button(connection, text='Disconnect', command=self.disconnect).pack(side='left', padx=8)
        self.connection_status = tk.StringVar(value='Disconnected')
        ttk.Label(connection, textvariable=self.connection_status).pack(side='left', padx=12)
        control_area = ttk.Frame(self)
        control_area.grid(row=1, column=0, sticky='nsw', padx=(0, 18))
        self.control_tabs = ttk.Notebook(control_area, width=310)
        self.control_tabs.pack(fill='both', expand=True)
        controls = ttk.Frame(self.control_tabs, padding=6)
        self.control_tabs.add(controls, text='DDS')
        self.section(controls, 'DDS', 0)
        self.field(controls, 'Frequency (Hz)', 'hz', 1000, 1)
        self.field(controls, 'Amplitude (code)', 'amp', 255, 2)
        self.field(controls, 'Bias (code)', 'bias', 0, 3)
        ttk.Label(controls, text='Waveform').grid(row=4, column=0, sticky='w', pady=5)
        self.wave = ttk.Combobox(controls, values=('Sine', 'Square', 'Triangle', 'Sawtooth'), state='readonly', width=14)
        self.wave.current(0)
        self.wave.bind('<<ComboboxSelected>>', lambda event: self.mark_dirty('wave'))
        self.wave.grid(row=4, column=1, sticky='ew')
        self.button(controls, 'Apply DDS', 5, self.apply_dds)
        controls = ttk.Frame(self.control_tabs, padding=6)
        self.control_tabs.insert(0, controls, text='FSK')
        self.control_tabs.select(controls)
        self.section(controls, 'FSK transmitter', 6)
        self.field(controls, 'Amplitude (code)', 'famp', 128, 7)
        self.field(controls, 'Bias (code)', 'fbias', 0, 8)
        self.field(controls, 'Offset (Hz)', 'offset', 0, 9)
        self.button(controls, 'Apply FSK', 10, self.apply_fsk)
        runbar = ttk.Frame(controls)
        runbar.grid(row=11, column=0, columnspan=2, sticky='ew', pady=5)
        for label, value in (('Enter FSK', 1), ('Exit FSK', 0)):
            button = ttk.Button(runbar, text=label, command=lambda n=value: self.send(3, bytes([n])))
            button.pack(side='left', expand=True, fill='x')
            self.command_controls.append(button)
        self.section(controls, 'Noise / test', 12)
        self.noise = tk.IntVar(value=1)
        self.noise.trace_add('write', lambda *args: self.mark_dirty('noise'))
        ttk.Checkbutton(controls, text='Software noise permission', variable=self.noise).grid(row=13, column=0, columnspan=2, sticky='w')
        self.field(controls, 'Noise scale (Q8.8)', 'scale', 0, 14)
        self.button(controls, 'Apply noise', 15, lambda: self.send(4, struct.pack('>BH', self.noise.get(), self.number('scale'))))
        controls = ttk.Frame(self.control_tabs, padding=6)
        self.control_tabs.insert(1, controls, text='Interference / test')
        self.section(controls, 'Tone jammer', 16)
        self.jam = tk.IntVar(value=0)
        self.jam.trace_add('write', lambda *args: self.mark_dirty('jam'))
        ttk.Checkbutton(controls, text='Narrowband jammer enable', variable=self.jam).grid(row=17, column=0, columnspan=2, sticky='w')
        self.field(controls, 'Jammer frequency (Hz)', 'jamhz', 1500, 18)
        self.field(controls, 'Jammer amplitude (code)', 'jamamp', 0, 19)
        ttk.Label(controls, text='Jammer mode').grid(row=20, column=0, sticky='w', pady=5)
        self.jam_mode = ttk.Combobox(controls, values=('Continuous', 'Payload burst'), state='readonly', width=14)
        self.jam_mode.current(0)
        self.jam_mode.grid(row=20, column=1, sticky='ew')
        self.jam_mode.bind('<<ComboboxSelected>>', lambda event: self.mark_dirty('jam_mode'))
        self.jammer_button = self.button(controls, 'Apply jammer', 21, self.apply_jammer)
        self.jammer_hint = tk.StringVar(value='Connect to configure interference')
        ttk.Label(controls, textvariable=self.jammer_hint, wraplength=305).grid(row=22, column=0, columnspan=2, sticky='w')
        self.field(controls, 'Target frames', 'frames', 100, 23)
        testbar = ttk.Frame(controls)
        testbar.grid(row=24, column=0, columnspan=2, sticky='ew', pady=5)
        for label, action in (('Start', 1), ('Stop', 0), ('Clear', 2)):
            button = ttk.Button(testbar, text=label, command=lambda n=action: self.test(n))
            button.pack(side='left', expand=True, fill='x')
            self.command_controls.append(button)
        view = ttk.Frame(self)
        view.grid(row=1, column=1, sticky='nsew')
        view.columnconfigure(0, weight=1)
        view.rowconfigure(1, weight=1)
        self.state_text = tk.StringVar(value='No device status')
        state_label = ttk.Label(view, textvariable=self.state_text, justify='left', wraplength=530)
        state_label.grid(row=0, column=0, sticky='ew', pady=(0, 8))
        view.bind('<Configure>', lambda event: state_label.configure(wraplength=max(200,event.width-8)))
        self.table = ttk.Treeview(view, columns=('traditional', 'ai'), show='tree headings', height=9)
        self.table.heading('#0', text='Measurement')
        self.table.heading('traditional', text='Traditional')
        self.table.heading('ai', text='AI')
        self.table.column('#0', minwidth=110, width=140)
        for column in ('traditional', 'ai'):
            self.table.column(column, minwidth=85, width=110, anchor='center')
        self.table.grid(row=1, column=0, sticky='nsew')
        self.stats_text = tk.StringVar(value='Traditional BER: unavailable\nAI BER: unavailable')
        self.stats_label = ttk.Label(view, textvariable=self.stats_text, justify='left', wraplength=400)
        self.stats_label.grid(row=2, column=0, sticky='ew', pady=12)
        self.message = tk.StringVar(value='Ready')
        self.message_label = ttk.Label(view, textvariable=self.message, wraplength=400)
        self.message_label.grid(row=3, column=0, sticky='ew', pady=4)
        def resize(event):
            for label in (state_label, self.stats_label, self.message_label):
                label.configure(wraplength=max(200, event.width-8))
        view.bind('<Configure>', resize)
        self.conditions = tk.StringVar(value='Uncalibrated')
        ttk.Label(view, text='Experiment notes').grid(row=4, column=0, sticky='w', pady=(10, 2))
        ttk.Entry(view, textvariable=self.conditions).grid(row=5, column=0, sticky='ew')
        footer = ttk.Frame(view)
        footer.grid(row=6, column=0, sticky='ew', pady=8)
        ttk.Button(footer, text='Diagnostics', command=self.diagnostics).pack(side='left')
        ttk.Button(footer, text='Export CSV', command=self.export).pack(side='right')
        self.enable(False)
        master.protocol('WM_DELETE_WINDOW', self.close)
        master.after(50, self.poll)

    @staticmethod
    def ports():
        try:
            from serial.tools.list_ports import comports
            return [p.device for p in comports()]
        except ImportError:
            return []

    def section(self, parent, text, row):
        ttk.Label(parent, text=text, font=('Segoe UI', 11, 'bold')).grid(row=row, column=0, columnspan=2, sticky='w', pady=(10, 5))

    def field(self, parent, label, name, default, row):
        ttk.Label(parent, text=label).grid(row=row, column=0, sticky='w', padx=(0, 10), pady=4)
        var = tk.StringVar(value=str(default)); self.variables[name] = var
        if name != 'frames':
            var.trace_add('write', lambda *args: self.mark_dirty(name))
        ttk.Entry(parent, textvariable=var, width=14).grid(row=row, column=1, sticky='ew')

    def mark_dirty(self, name):
        if not self.updating_fields:
            self.dirty_fields.add(name)

    def button(self, parent, label, row, callback):
        def checked():
            try:
                callback()
            except (ValueError, struct.error) as exc:
                self.note(str(exc))
        button = ttk.Button(parent, text=label, command=checked)
        button.grid(row=row, column=0, columnspan=2, sticky='ew', pady=5)
        self.command_controls.append(button)
        return button

    def number(self, key):
        return int(self.variables[key].get())

    def send(self, cmd, payload=b''):
        if self.worker and self.worker.is_alive():
            if cmd in self.pending_commands:
                self.note('Command pending; wait for device confirmation')
                return
            self.pending_commands.add(cmd)
            self.worker.tasks.put(('command', (cmd, payload)))
            self.refresh_jammer_control()

    def apply_dds(self):
        self.send(1, dds_payload(self.number('hz'), self.wave.current(), self.number('amp'), self.number('bias')))

    def apply_fsk(self):
        self.send(2, fsk_payload(self.number('famp'), self.number('fbias'), self.number('offset')))

    def apply_jammer(self):
        if self.jammer_busy():
            self.note('Interference unchanged. Stop the test / Exit FSK, then apply again.')
            return
        enable = 1 if self.jam.get() else 0
        amplitude, frequency = self.number('jamamp'), self.number('jamhz')
        if not 0 <= amplitude <= 255 or not 100 <= frequency <= 2100:
            raise ValueError('Interference amplitude: 0..255; frequency: 100..2100 Hz')
        self.send(8, jammer_payload(enable, amplitude, frequency,
                                    burst=self.jam_mode.current()==1))

    def test(self, action):
        try:
            self.send(7, bytes([action]) + (struct.pack('>I', self.number('frames')) if action == 1 else b''))
        except (ValueError, struct.error) as exc:
            self.note(str(exc))

    def connect(self):
        if self.worker and self.worker.is_alive():
            return
        if not self.port.get().strip():
            self.note('Select a serial port'); return
        records = self.worker.client.records if self.worker and self.worker.client else ()
        self.worker = Worker(self.port.get().strip(), records=records); self.worker.start()
        self.connection_status.set('Connecting')

    def disconnect(self):
        if self.worker:
            self.worker.stop_event.set()
        self.enable(False); self.connection_status.set('Disconnected')
        self.last_status = None
        self.pending_commands.clear()

    def enable(self, enabled):
        self.connected = enabled
        for control in self.command_controls:
            control.configure(state='normal' if enabled else 'disabled')
        self.refresh_jammer_control()

    def jammer_busy(self):
        status = self.last_status or {}
        return any(status.get(key, 0) for key in
                   ('run_requested', 'fsk_active', 'frame_active', 'test_running', 'test_pending'))

    def refresh_jammer_control(self):
        ready = self.connected and self.last_status is not None and not self.jammer_busy() and 8 not in self.pending_commands
        self.jammer_button.configure(state='normal' if ready else 'disabled')
        self.jammer_hint.set('Stop / Exit FSK before applying interference' if self.jammer_busy() else
                             ('Waiting for device confirmation' if 8 in self.pending_commands else
                              ('Interference settings ready' if ready else 'Waiting for device status')))

    def note(self, message):
        self.message.set(message)

    def diagnostics(self):
        window = tk.Toplevel(self)
        window.title('Device diagnostics')
        window.geometry('700x500')
        text = tk.Text(window, wrap='word')
        text.pack(fill='both', expand=True)
        text.insert('end', json.dumps({'status': self.last_status, 'report': self.last_report}, indent=2))
        text.configure(state='disabled')

    def render_status(self, status):
        self.last_status = status
        dds, fsk = status['dds_requested'], status['fsk_requested']
        requested = {'hz': dds['hz'], 'amp': dds['amplitude'], 'bias': dds['bias'],
                     'famp': fsk['amplitude'], 'fbias': fsk['bias'], 'offset': fsk['offset_hz'],
                     'scale': fsk['noise_scale'], 'jamhz': status.get('jam_hz', 1500),
                     'jamamp': status.get('jam_amplitude', 0)}
        self.updating_fields = True
        try:
            for name, value in requested.items():
                if name not in self.dirty_fields:
                    self.variables[name].set(str(value))
            if 'wave' not in self.dirty_fields: self.wave.current(dds['wave'])
            if 'noise' not in self.dirty_fields: self.noise.set(fsk['software_noise'])
            if 'jam' not in self.dirty_fields: self.jam.set(status.get('jam_enable', 0))
            if 'jam_mode' not in self.dirty_fields: self.jam_mode.current(status.get('jam_burst', 0))
        finally:
            self.updating_fields = False
        active = status['fsk_active_config'] if status['fsk_active'] else status['dds_active']
        self.state_text.set('Config %d | %s | RX lock %d\nActive amplitude %d | bias %d | %s\nInterference: %s / %s, %d Hz, amplitude %d\nGaussian scale %d | gate %d/%d/%d' % (
            status['config_id'], 'FSK 1000/2000 Hz, 100 bit/s' if status['fsk_active'] else 'DDS',
            status['rx_lock'], active['amplitude'], active['bias'],
            'offset %d Hz' % active['offset_hz'] if status['fsk_active'] else '%d Hz' % active['hz'],
            'ON' if status.get('jam_enable') else 'OFF',
            'Payload burst' if status.get('jam_burst') else 'Continuous',
            status.get('jam_hz', 0), status.get('jam_amplitude', 0),
            status['fsk_active_config']['noise_scale'],
            fsk['physical_noise'], fsk['software_noise'], status['noise_actual']))
        self.refresh_jammer_control()

    def render_report(self, report):
        self.last_report = report
        state = 'Final incomplete' if report.get('incomplete') else ('Final' if report.get('final') else 'Live')
        self.table.delete(*self.table.get_children())
        rows = [('Payload BER', lambda b: '%.6g' % report[b+'_ber'] if report.get(b+'_ber') is not None else 'unavailable'),
                ('Errors / bits', lambda b: '%d / %d' % (report[b+'_errors'], report[b+'_bits'])),
                ('CRC failures', lambda b: report[b+'_crc_failures']),
                ('Captured frames', lambda b: report[b+'_captured_frames']),
                ('Lost frames', lambda b: report[b+'_lost_frames']),
                ('Offset (Hz)', lambda b: report.get(b+'_offset_estimate', '?')),
                ('AGC exponent', lambda b: report.get(b+'_agc_exponent', '?')),
                ('Model version', lambda b: '%08x' % report[b+'_model_version'])]
        for title, value in rows:
            self.table.insert('', 'end', text=title, values=tuple(value(b) if report[b+'_valid'] else 'unavailable' for b in ('trad','ai')))
        upper = ['%s zero-error 95%% upper bound: %.6g' % (name, 3/report[b+'_bits'])
                 for b,name in (('trad','Traditional'),('ai','AI'))
                 if report[b+'_valid'] and report[b+'_bits'] and report[b+'_errors']==0]
        self.stats_text.set('%s | report config %d / run %d | TX %d frames\nADC errors %d | ADC clips %d | DAC clips %d\nDropped reports %d%s' % (
            state, report['config_id'], report['run_id'], report['tx_frames'], report['adc_errors'],
            report['adc_clips'], report['dac_clips'], report['dropped_reports'],
            ('\n'+'\n'.join(upper)) if upper else ''))

    def acknowledge_edit(self, event):
        command, payload = event['command'], bytes.fromhex(event['payload'])
        if command == 1:
            values = dict(zip(('hz', 'wave', 'amp', 'bias'), struct.unpack('>IBBh', payload)))
        elif command == 2:
            values = dict(zip(('famp', 'fbias', 'offset'), struct.unpack('>IIHBhh', payload)[3:]))
        elif command == 4:
            values = dict(zip(('noise', 'scale'), struct.unpack('>BH', payload)))
        elif command == 8:
            values = dict(zip(('jam', 'jamamp', 'jamhz'), struct.unpack('>BBH', payload[:4])))
            values['jam_mode'] = payload[4] if len(payload)==5 else 0
        else:
            return
        for name, value in values.items():
            try:
                special = {'wave': self.wave.current, 'noise': self.noise.get,
                           'jam': self.jam.get, 'jam_mode': self.jam_mode.current}
                current = special[name]() if name in special else self.number(name)
                if current == value: self.dirty_fields.discard(name)
            except ValueError:
                pass

    def poll(self):
        if self.worker:
            while True:
                try: event = self.worker.events.get_nowait()
                except queue.Empty: break
                if event['kind'] == 'connected': self.enable(True); self.connection_status.set('Connected - 115200 8N1')
                elif event['kind'] == 'status': self.render_status(event)
                elif event['kind'] == 'report': self.render_report(event)
                elif event['kind'] == 'ack':
                    self.pending_commands.discard(event['command'])
                    self.acknowledge_edit(event)
                    self.note('Settings accepted' if event['command'] in (1,2,4,8) else 'Command accepted')
                else:
                    self.pending_commands.discard(event.get('command'))
                    message = event.get('message', 'Exported '+event.get('path', ''))
                    if message == 'BUSY': message = 'Device busy. Stop / Exit FSK and wait, then apply again.'
                    self.note(message)
                    if event['kind'] == 'disconnected':
                        self.last_status = None
                        self.pending_commands.clear()
                        self.enable(False)
                        self.connection_status.set('Disconnected')
                self.refresh_jammer_control()
        self.master.after(50, self.poll)

    def export(self):
        if not self.worker or not self.worker.client:
            self.note('No session records'); return
        path = filedialog.asksaveasfilename(defaultextension='.csv', filetypes=[('CSV', '*.csv')])
        if path:
            if self.worker.is_alive(): self.worker.tasks.put(('export', (path, self.conditions.get())))
            else:
                self.worker.client.export_csv(path, self.conditions.get())
                self.note('Exported '+path)

    def close(self):
        self.disconnect()
        if self.worker: self.worker.join(timeout=3)
        self.master.destroy()


if __name__ == '__main__':
    root = tk.Tk()
    App(root)
    root.mainloop()
