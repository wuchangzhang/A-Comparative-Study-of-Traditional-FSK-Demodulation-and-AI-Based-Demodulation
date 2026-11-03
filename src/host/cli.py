import argparse
import json
import struct
import time
from client import Client
from protocol import dds_payload, fsk_payload


def main():
    parser = argparse.ArgumentParser(description='EGO1 DDS control v3')
    parser.add_argument('--port', required=True)
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('status')
    commands.add_parser('ping')
    dds = commands.add_parser('dds')
    dds.add_argument('--hz', type=int, default=1000)
    dds.add_argument('--wave', type=int, choices=(0, 1, 2, 3), default=0,
                     help='0 sine, 1 square, 2 triangle, 3 sawtooth')
    dds.add_argument('--amplitude', type=int, default=255)
    dds.add_argument('--bias', type=int, default=0)
    fsk = commands.add_parser('fsk')
    fsk.add_argument('--amplitude', type=int, default=128)
    fsk.add_argument('--bias', type=int, default=0)
    fsk.add_argument('--offset', type=int, default=0)
    run = commands.add_parser('run')
    run.add_argument('enabled', type=int, choices=(0, 1))
    noise = commands.add_parser('noise')
    noise.add_argument('--enable', type=int, choices=(0, 1), default=1)
    noise.add_argument('--scale', type=int, default=0)
    test = commands.add_parser('test')
    test.add_argument('action', choices=('start', 'stop', 'clear'))
    test.add_argument('--frames', type=int, default=100)
    monitor = commands.add_parser('monitor')
    monitor.add_argument('--seconds', type=float, default=10)
    monitor.add_argument('--csv')
    monitor.add_argument('--conditions', default='Uncalibrated')
    args = parser.parse_args()
    client = Client(args.port, callback=lambda data: print(json.dumps(data, ensure_ascii=False)))
    try:
        client.connect()
        if args.command == 'dds':
            client.command(1, dds_payload(args.hz, args.wave, args.amplitude, args.bias))
        elif args.command == 'fsk':
            client.command(2, fsk_payload(args.amplitude, args.bias, args.offset))
        elif args.command == 'run':
            client.command(3, bytes([args.enabled]))
        elif args.command == 'noise':
            client.command(4, struct.pack('>BH', args.enable, args.scale))
        elif args.command == 'test':
            code = {'stop': 0, 'start': 1, 'clear': 2}[args.action]
            client.command(7, bytes([code]) + (struct.pack('>I', args.frames) if code == 1 else b''))
        elif args.command == 'monitor':
            deadline = time.monotonic() + args.seconds
            while time.monotonic() < deadline:
                client.read()
            if args.csv:
                client.export_csv(args.csv, args.conditions)
        client.command(5)
    finally:
        client.close()


if __name__ == '__main__':
    main()
