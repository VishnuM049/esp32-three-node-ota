import json
import re
import sys
from pathlib import Path
import tempfile
import threading
import unittest
from http.client import HTTPConnection
from http.server import ThreadingHTTPServer
from unittest.mock import patch

import record_event
from server import StatusLog, handler_for, parse_status

GOOD = ("role=0 version=8 noise=1 edge1=192.168.4.2 edge2=192.168.4.3 "
        "edge1_secure=v7_ota2_minheap214024_stack10844_rttms334 "
        "edge2_secure=v7_ota2_minheap213468_stack10844_rttms315 "
        "ota=valid last_invalid=none heap=201956 minheap=183364 stack_margin=9468\n")
GOOD_TLS = (GOOD.replace('version=8 noise=1', 'version=11 noise=1 tls=1')
            .replace('edge1_secure=v7_', 'edge1_secure=v9_')
            .replace('edge2_secure=v7_', 'edge2_secure=v9_'))


class BrowserLogTests(unittest.TestCase):
    def test_parse_authenticated_status(self):
        result = parse_status(GOOD)
        self.assertEqual(result['controller']['version'], 8)
        self.assertFalse(result['controller']['tls'])
        self.assertEqual(result['controller']['ota'], 'valid')
        self.assertEqual(result['edges']['edge1']['version'], 7)
        self.assertEqual(result['edges']['edge2']['ota'], 'valid')
        self.assertEqual(result['edges']['edge2']['rtt_ms'], 315)
        self.assertEqual(result['controller']['stack_margin'], 9468)

    def test_https_status_is_reported_without_claiming_http_status_encryption(self):
        result = parse_status(GOOD_TLS)
        self.assertEqual(result['controller']['version'], 11)
        self.assertTrue(result['controller']['tls'])
        self.assertTrue(result['controller']['noise'])
        self.assertEqual(result['edges']['edge1']['version'], 9)
        self.assertEqual(result['edges']['edge2']['ota'], 'valid')

    def test_reject_wrong_or_incomplete_controller(self):
        with self.assertRaises(ValueError):
            parse_status('not the controller\n')
        with self.assertRaises(ValueError):
            parse_status(GOOD.replace('edge2_secure=', 'missing='))
        with self.assertRaises(ValueError):
            parse_status(GOOD + 'second line\n')

    def test_records_real_changes_only_and_marks_offline_stale(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'events.jsonl'
            times = iter(f'2026-10-28T00:00:{n:02d}+00:00' for n in range(30))
            log = StatusLog(path, now=lambda: next(times))
            log.observe(GOOD)
            baseline = len(log.data()['events'])
            log.observe(GOOD)
            self.assertEqual(len(log.data()['events']), baseline)
            pending = GOOD.replace('edge1_secure=v7_ota2_', 'edge1_secure=v8_ota1_')
            log.observe(pending)
            valid = pending.replace('edge1_secure=v8_ota1_', 'edge1_secure=v8_ota2_')
            log.observe(valid)
            events = log.data()['events']
            self.assertTrue(any(e['kind'] == 'version' and e['node'] == 'edge1' for e in events))
            self.assertTrue(any(e['kind'] == 'confirmed' and e['node'] == 'edge1' for e in events))
            log.unavailable('Mac is not on demo AP')
            log.unavailable('Mac is not on demo AP')
            data = log.data()
            self.assertFalse(data['connected'])
            self.assertEqual(data['snapshot']['edges']['edge1']['version'], 8)
            self.assertEqual(sum(e['detail'] == 'Mac is not on demo AP' for e in data['events']), 1)
            self.assertTrue(path.is_file())

    def test_sender_event_appears_in_running_browser_log(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'events.jsonl'
            log = StatusLog(path)
            with patch.object(record_event, 'LOG', path), \
                 patch.object(sys, 'argv', ['record_event.py', 'edge1', '8', 'accepted']):
                record_event.main()
            events = log.data()['events']
            self.assertEqual(events[0]['kind'], 'upload')
            self.assertIn('v8 · Signed transfer accepted', events[0]['detail'])

    def test_reconnect_is_not_falsely_logged_as_firmware_update(self):
        with tempfile.TemporaryDirectory() as directory:
            log = StatusLog(Path(directory) / 'events.jsonl')
            offline_edge = re.sub(r'edge2_secure=v7_ota2_minheap\d+_stack\d+_rttms\d+',
                                  'edge2_secure=unregistered', GOOD)
            log.observe(offline_edge)
            log.observe(GOOD)
            edge2 = [e for e in log.data()['events'] if e['node'] == 'edge2']
            self.assertFalse(any(e['kind'] == 'version' for e in edge2))
            self.assertTrue(any('Authenticated again at v7' in e['detail'] for e in edge2))

    def test_loopback_endpoint_is_read_only_and_serves_no_secrets(self):
        with tempfile.TemporaryDirectory() as directory:
            log = StatusLog(Path(directory) / 'events.jsonl')
            server = ThreadingHTTPServer(('127.0.0.1', 0), handler_for(log))
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                connection = HTTPConnection('127.0.0.1', server.server_port, timeout=4)
                connection.request('GET', '/api/state')
                response = connection.getresponse()
                self.assertEqual(response.status, 200)
                self.assertFalse(json.loads(response.read())['connected'])
                connection.request('GET', '/private_keys/demo.pem')
                response = connection.getresponse()
                self.assertEqual(response.status, 404)
                response.read()
                connection.request('POST', '/update', body=b'unsafe')
                response = connection.getresponse()
                self.assertEqual(response.status, 405)
                response.read()
                connection.close()
            finally:
                server.shutdown()
                server.server_close()
                thread.join(timeout=4)


if __name__ == '__main__':
    unittest.main()
