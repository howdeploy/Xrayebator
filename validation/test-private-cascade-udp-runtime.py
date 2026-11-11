#!/usr/bin/env python3
"""Isolated PR36 UDP check: real renderer, raw XUDP, relay and VLESS classifier.

No router, VPS, interface, firewall or routing-table changes. The only fixture
exceptions allow two local UDP sink addresses and one local TCP sink port.
Branch evidence is recvfrom's actual source IPv4, not the Xray log label.
"""
import argparse
import contextlib
import json
import os
import pathlib
import queue
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import uuid
import urllib.parse

IDENTITY = uuid.UUID('22222222-2222-4222-8222-222222222222')
# Official Xray v26.10.31 common/protocol/quic/sniff_test.go, TestSniffQUIC.
# Decryptable Initial with SNI www.google.com, used only against local sinks.
QUIC = bytes.fromhex('cd0000000108f1fb7bcc78aa5e7203a8f86400421531fe825b19541876db6c55c38890cd73149d267a084afee6087304095417a3033df6a81bbb71d8512e7a3e16df1e277cae5df3182cb214b8fe982ba3fdffbaa9ffec474547d55945f0fddbeadfb0b5243890b2fa3da45169e2bd34ec04b2e29382f48d612b28432a559757504d158e9e505407a77dd34f4b60b8d3b555ee85aacd6648686802f4de25e7216b19e54c5f78e8a5963380c742d861306db4c16e4f7fc94957aa50b9578a0b61f1e406b2ad5f0cd3cd271c4d99476409797b0c3cb3efec256118912d4b7e4fd79d9cb9016b6e5eaa4f5e57b637b217755daf8968a4092bed0ed5413f5d04904b3a61e4064f9211b2629e5b52a89c7b19f37a713e41e27743ea6dfa736dfa1bb0a4b2bc8c8dc632c6ce963493a20c550e6fdb2475213665e9a85cfc394da9cec0cf41f0c8abed3fc83be5245b2b5aa5e825d29349f721d30774ef5bf965b540f3d8d98febe20956b1fc8fa047e10e7d2f921c9c6622389e02322e80621a1cf5264e245b7276966eb02932584e3f7038bd36aa908766ad3fb98344025dec18670d6db43a1c5daac00937fce7b7c7d61ff4e6efd01a2bdee0ee183108b926393df4f3d74bbcbb015f240e7e346b7d01c41111a401225ce3b095ab4623a5836169bf9599eeca79d1d2e9b2202b5960a09211e978058d6fc0484eff3e91ce4649a5e3ba15b906d334cf66e28d9ff575406e1ae1ac2febafd72870b6f5d58fc5fb949cb1f40feb7c1d9ce5e71b')


def free_port():
    """Find an unused loopback TCP port without changing network configuration."""
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        return s.getsockname()[1]


def address(host):
    """Encode a VLESS address without resolving a domain name."""
    for family, kind in ((socket.AF_INET, 1), (socket.AF_INET6, 3)):
        try:
            return bytes([kind]) + socket.inet_pton(family, host)
        except OSError:
            pass
    data = host.encode('ascii')
    return bytes([2, len(data)]) + data


def frame(status, host, port, payload, global_id):
    """Encode an XUDP frame whose explicit destination may differ from earlier frames."""
    meta = struct.pack('>HBBB', 1, status, 1, 2)
    meta += struct.pack('>H', port) + address(host)
    if status == 1:
        meta += global_id
    return struct.pack('>H', len(meta)) + meta + struct.pack('>H', len(payload)) + payload


def exact(sock, n):
    """Read a complete protocol field and reject an early connection close."""
    result = b''
    while len(result) < n:
        chunk = sock.recv(n - len(result))
        if not chunk:
            raise EOFError('closed before complete response')
        result += chunk
    return result


class Association:
    def __init__(self, port):
        """Open one authenticated raw VLESS mux association for destination changes."""
        self.sock = socket.create_connection(('127.0.0.1', port), timeout=4)
        self.sock.settimeout(4)
        self.sock.sendall(b'\x00' + IDENTITY.bytes + b'\x00\x03')
        self.first = True
        self.response_header = False
        self.global_id = os.urandom(8)

    def send(self, host, port, payload):
        """Keep every new destination inside the original XUDP association."""
        self.sock.sendall(frame(1 if self.first else 2, host, port, payload, self.global_id))
        self.first = False

    def response(self):
        """Decode one returned data frame while skipping mux control frames."""
        if not self.response_header:
            header = exact(self.sock, 2)
            assert header[0] == 0, header
            exact(self.sock, header[1])
            self.response_header = True
        for _ in range(20):
            length = struct.unpack('>H', exact(self.sock, 2))[0]
            meta = exact(self.sock, length)
            if meta[3] & 1:
                size = struct.unpack('>H', exact(self.sock, 2))[0]
                return exact(self.sock, size)
        raise AssertionError('no data response frame')

    def close(self):
        """Release only this fixture's client connection."""
        self.sock.close()


def stop(process):
    """Stop a captured fixture process with a bounded termination fallback."""
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=2)


def ready(process, port, log):
    """Wait for a listener or report its fixture log if startup fails."""
    for _ in range(80):
        if process.poll() is not None:
            log.flush()
            raise RuntimeError(pathlib.Path(log.name).read_text())
        try:
            with socket.create_connection(('127.0.0.1', port), timeout=.1):
                return
        except OSError:
            time.sleep(.05)
    raise TimeoutError(f'listener {port} not ready')


def sink_thread(sock, events, stopped):
    """Record the real UDP source and destination before echoing the exact payload."""
    sock.settimeout(.1)
    while not stopped.is_set():
        try:
            data, peer = sock.recvfrom(65535)
        except socket.timeout:
            continue
        except OSError:
            return
        events.put((sock.getsockname()[0], peer[0], data))
        sock.sendto(data, peer)


def tcp_sink_thread(sock, stopped):
    """Return the observed TCP source address for independent routing canaries."""
    sock.settimeout(.1)
    while not stopped.is_set():
        try:
            conn, peer = sock.accept()
        except socket.timeout:
            continue
        except OSError:
            return
        with conn:
            conn.settimeout(3)
            if conn.recv(4096):
                conn.sendall(b'tcp-source:' + peer[0].encode())


def dns_a_response(packet, identifier):
    """Validate a test DNS response and extract its IPv4 answers."""
    ident, flags, questions, answers, _, _ = struct.unpack('>HHHHHH', packet[:12])
    assert ident == identifier and flags & 0x8000 and flags & 15 == 0, packet.hex()

    def skip_name(offset):
        """Skip a DNS name or compression pointer without following arbitrary offsets."""
        for _ in range(128):
            size = packet[offset]
            if size & 0xc0 == 0xc0:
                return offset + 2
            offset += 1
            if size == 0:
                return offset
            offset += size
        raise AssertionError('invalid DNS name')

    offset = 12
    for _ in range(questions):
        offset = skip_name(offset) + 4
    result = []
    for _ in range(answers):
        offset = skip_name(offset)
        kind, cls, _, length = struct.unpack('>HHIH', packet[offset:offset + 10])
        offset += 10
        if kind == 1 and cls == 1 and length == 4:
            result.append(socket.inet_ntop(socket.AF_INET, packet[offset:offset + length]))
        offset += length
    return result


def local_ip():
    """Select an existing local IPv4 without adding an interface or address."""
    if sys.platform == 'darwin':
        return subprocess.check_output(['/usr/sbin/ipconfig', 'getifaddr', 'en0'], text=True).strip()
    for ip in socket.gethostbyname_ex(socket.gethostname())[2]:
        if not ip.startswith('127.'):
            return ip
    raise RuntimeError('Pass --local-ip with an existing local IPv4 address')


def run(binary, relay_script, source_ip, keep, repo, bash, transport, decoy_name, decoy_target, empty_ips=False):
    """Check real-core delivery using narrowly scoped local destination exceptions."""
    version = subprocess.check_output([binary, 'version'], text=True).splitlines()[0].split()[1]
    profile = 'unmatched' if empty_ips else 'full'
    directory = pathlib.Path(tempfile.mkdtemp(prefix='udp-split-' + version + '-' + transport + '-' + profile + '-'))
    print(version, transport, profile, 'fixture', directory, flush=True)
    with contextlib.ExitStack() as stack:
        if not keep:
            import shutil
            stack.callback(shutil.rmtree, directory)
        events = queue.Queue()
        stopped = threading.Event()
        stack.callback(stopped.set)
        sinks = []
        for target in ('127.0.0.1', source_ip):
            sock = stack.enter_context(socket.socket(socket.AF_INET, socket.SOCK_DGRAM))
            sock.bind((target, 0 if not sinks else sinks[0].getsockname()[1]))
            threading.Thread(target=sink_thread, args=(sock, events, stopped), daemon=True).start()
            sinks.append(sock)
        sink_port = sinks[0].getsockname()[1]
        sink6 = stack.enter_context(socket.socket(socket.AF_INET6, socket.SOCK_DGRAM))
        sink6.bind(('::1', sink_port))
        threading.Thread(target=sink_thread, args=(sink6, events, stopped), daemon=True).start()
        prohibited = stack.enter_context(socket.socket(socket.AF_INET, socket.SOCK_DGRAM))
        prohibited.bind(('127.0.0.1', 0))
        threading.Thread(target=sink_thread, args=(prohibited, events, stopped), daemon=True).start()
        tcp_sink = stack.enter_context(socket.socket())
        tcp_sink.bind(('127.0.0.1', 0))
        tcp_sink.listen(8)
        tcp_port = tcp_sink.getsockname()[1]
        threading.Thread(target=tcp_sink_thread, args=(tcp_sink, stopped), daemon=True).start()
        ports = [free_port() for _ in range(5)]
        assert len(set(ports)) == len(ports)
        public_port, relay_port, dispatch_port, foreign_port, front_port = ports
        keys = dict(line.split(': ', 1) for line in subprocess.check_output([binary, 'x25519'], text=True).splitlines() if ': ' in line)
        public_key = next(v for k, v in keys.items() if 'Public' in k or 'Password' in k)
        network = 'xhttp' if transport == 'plain' else transport
        def reality_stream(outgoing=False):
            """Build matching REALITY settings for the selected trusted TLS target."""
            reality = ({'serverName': decoy_name, 'fingerprint': 'chrome',
                'publicKey': public_key, 'shortId': 'ab12'} if outgoing else
                {'target': decoy_target, 'serverNames': [decoy_name],
                    'privateKey': keys['PrivateKey'], 'shortIds': ['ab12']})
            result = {'network': network, 'security': 'reality', 'realitySettings': reality}
            if network == 'xhttp':
                result['xhttpSettings'] = {'host': decoy_name, 'path': '/fixture', 'mode': 'stream-one'}
            return result

        template_user = {'id': str(uuid.uuid4())}
        if network == 'tcp':
            template_user['flow'] = 'xtls-rprx-vision'
        template = {'inbounds': [{'tag': 'template', 'port': 15442, 'protocol': 'vless',
            'settings': {'decryption': 'none', 'clients': [template_user]},
            'streamSettings': reality_stream()}]}
        policy = {'inbound_tag': 'template', 'listen': '127.0.0.1', 'port': public_port,
            'client_id': str(IDENTITY), 'udp_relay_port': relay_port, 'udp_dispatch_port': dispatch_port,
            'russia_only_domains': ['full:inside.test', 'full:www.google.com'],
            'blocked_domains': ['full:blocked.ru'], 'blocked_ips': [source_ip + '/32'],
            'russian_domains': ['domain:ru'], 'russian_ips': [] if empty_ips else ['127.0.0.1/32']}
        files = {name: directory / name for name in ('source.json', 'policy.json', 'upstream.txt', 'candidate.json')}
        files['source.json'].write_text(json.dumps(template))
        files['policy.json'].write_text(json.dumps(policy))
        uri = {'security': 'reality', 'type': network, 'sni': decoy_name,
            'fp': 'chrome', 'pbk': public_key, 'sid': 'ab12'}
        if network == 'tcp':
            uri['flow'] = 'xtls-rprx-vision'
        else:
            uri.update({'host': decoy_name, 'path': '/fixture', 'mode': 'stream-one'})
        files['upstream.txt'].write_text('vless://11111111-1111-4111-8111-111111111111@203.0.113.8:25443?' + urllib.parse.urlencode(uri) + '\n')
        env = dict(os.environ, XRAY_LOCATION_ASSET=str(binary.parent))
        command = [str(bash), '-c',
            'source ./xrayebator; CONFIG_FILE=$1; XRAY_BIN=$2; shift 2; private_cascade_command "$@"',
            'bash', files['source.json'], binary, 'render', '--policy-file', files['policy.json'],
            '--upstream-file', files['upstream.txt'], '--output', files['candidate.json']]
        rendered = subprocess.run(command, cwd=repo, env=env, text=True, capture_output=True)
        assert rendered.returncode == 0, rendered.stderr
        config = json.loads(files['candidate.json'].read_text())
        config['log'] = {'loglevel': 'debug'}
        hosts = {'inside.test': source_ip, 'ordinary.ru': '127.0.0.1', 'blocked.ru': '127.0.0.1',
            'other.test': source_ip, 'www.google.com': source_ip, 'only6.test': '::1'}
        config['dns'] = {'hosts': hosts, 'queryStrategy': 'UseIPv4'}
        if transport == 'plain':
            config['inbounds'][0]['streamSettings'] = {'network': 'tcp', 'security': 'none'}
        # Permit exactly our two fixture addresses in classification; finalRules
        # still allow only the exact sink port, not the prohibited local socket.
        for inbound in config['inbounds']:
            excluded = inbound.get('sniffing', {}).get('ipsExcluded', [])
            inbound.get('sniffing', {})['ipsExcluded'] = [x if x != 'geoip:private' else '10.231.254.253/32' for x in excluded]
        for rule in config['routing']['rules']:
            if 'ip' in rule:
                rule['ip'] = [x if x != 'geoip:private' else '10.231.254.253/32' for x in rule['ip']]
        for outbound in config['outbounds']:
            tag = outbound['tag']
            if tag.startswith('direct'):
                outbound['sendThrough'] = '127.0.0.1'
                ips = ['127.0.0.1/32'] + ([source_ip + '/32'] if tag == 'direct-russia-only' else [])
                outbound['settings']['finalRules'].insert(0, {'action': 'allow', 'network': 'udp', 'ip': ips, 'port': str(sink_port)})
                outbound['settings']['finalRules'].insert(0, {'action': 'allow', 'network': 'tcp', 'ip': ['127.0.0.1/32'], 'port': str(tcp_port)})
            if tag == 'cascade-upstream':
                if transport == 'plain':
                    outbound.clear()
                    outbound.update({'tag': tag, 'protocol': 'vless',
                        'settings': {'vnext': [{'address': '127.0.0.1', 'port': foreign_port,
                            'users': [{'id': '11111111-1111-4111-8111-111111111111', 'encryption': 'none'}]}]},
                        'streamSettings': {'network': 'tcp', 'security': 'none'}})
                else:
                    outbound['settings']['vnext'][0].update({'address': '127.0.0.1', 'port': foreign_port})
            if tag == 'cascade-fragment' and transport != 'plain':
                outbound['settings']['finalRules'] = [{'action': 'allow', 'network': 'tcp', 'ip': ['127.0.0.1/32'], 'port': str(foreign_port)}]
        files['candidate.json'].write_text(json.dumps(config))
        foreign = {'log': {'loglevel': 'debug'}, 'dns': {'hosts': hosts, 'queryStrategy': 'UseIPv4'},
            'inbounds': [{'tag': 'foreign-in', 'listen': '127.0.0.1', 'port': foreign_port, 'protocol': 'vless',
                'settings': {'clients': [{'id': '11111111-1111-4111-8111-111111111111'}], 'decryption': 'none'},
                'streamSettings': {'network': 'tcp', 'security': 'none'}}],
            'outbounds': [{'tag': 'foreign-exit', 'protocol': 'freedom', 'sendThrough': source_ip,
                'settings': {'domainStrategy': 'ForceIPv4', 'finalRules': [
                    {'action': 'allow', 'network': 'udp', 'ip': ['127.0.0.1/32', source_ip + '/32'], 'port': str(sink_port)},
                    {'action': 'allow', 'network': 'tcp', 'ip': ['127.0.0.1/32'], 'port': str(tcp_port)},
                    {'action': 'block', 'ip': ['geoip:private', '::/0']}]},
                'streamSettings': {'sockopt': {'domainStrategy': 'ForceIPv4'}}}]}
        if transport != 'plain':
            foreign['inbounds'][0]['streamSettings'] = reality_stream()
            if network == 'tcp':
                foreign['inbounds'][0]['settings']['clients'][0]['flow'] = 'xtls-rprx-vision'
        foreign_file = directory / 'foreign.json'
        foreign_file.write_text(json.dumps(foreign))
        foreign_log = stack.enter_context((directory / 'foreign.log').open('w'))
        foreign_process = subprocess.Popen([binary, 'run', '-config', foreign_file], env=env, stdout=foreign_log, stderr=subprocess.STDOUT)
        stack.callback(stop, foreign_process)
        ready(foreign_process, foreign_port, foreign_log)
        core_log = stack.enter_context((directory / 'ingress.log').open('w'))
        core = subprocess.Popen([binary, 'run', '-config', files['candidate.json']], env=env, stdout=core_log, stderr=subprocess.STDOUT)
        stack.callback(stop, core)
        ready(core, public_port, core_log)
        relay_log = stack.enter_context((directory / 'relay.log').open('w'))
        relay = subprocess.Popen([sys.executable, relay_script, '--config', files['candidate.json']], env=env, stdout=relay_log, stderr=subprocess.STDOUT)
        stack.callback(stop, relay)
        ready(relay, relay_port, relay_log)
        connection_port = public_port
        if transport != 'plain':
            front_user = {'id': str(IDENTITY), 'encryption': 'none', 'packetEncoding': 'xudp'}
            if network == 'tcp':
                front_user['flow'] = 'xtls-rprx-vision'
            front_config = {'log': {'loglevel': 'debug'}, 'inbounds': [{'listen': '127.0.0.1',
                'port': front_port, 'protocol': 'vless', 'settings': {'decryption': 'none', 'clients': [{'id': str(IDENTITY)}]},
                'streamSettings': {'network': 'tcp', 'security': 'none'}}],
                'outbounds': [{'protocol': 'vless', 'settings': {'vnext': [{'address': '127.0.0.1',
                    'port': public_port, 'users': [front_user]}]}, 'streamSettings': reality_stream(True),
                    'mux': {'enabled': True, 'concurrency': -1, 'xudpConcurrency': 1, 'xudpProxyUDP443': 'allow'}}]}
            front_file = directory / 'front.json'
            front_file.write_text(json.dumps(front_config))
            front_log = stack.enter_context((directory / 'front.log').open('w'))
            front = subprocess.Popen([binary, 'run', '-config', front_file], env=env, stdout=front_log, stderr=subprocess.STDOUT)
            stack.callback(stop, front)
            ready(front, front_port, front_log)
            connection_port = front_port

        def tcp_canary(host, expected_branch):
            """Verify TCP routing independently of whether the UDP helper is running."""
            with socket.create_connection(('127.0.0.1', connection_port), timeout=8) as client:
                client.settimeout(8)
                request = b'\x00' + IDENTITY.bytes + b'\x00\x01' + struct.pack('>H', tcp_port) + address(host)
                request += f'GET / HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n'.encode()
                client.sendall(request)
                header = exact(client, 2)
                assert header[0] == 0, header
                exact(client, header[1])
                expected = b'tcp-source:' + ('127.0.0.1' if expected_branch == 'RU' else source_ip).encode()
                assert exact(client, len(expected)) == expected
            print(version, 'TCP canary', host, '->', expected_branch, flush=True)

        def observed(client, host, expected_branch, target=None, payload=None):
            """Assert the actual UDP target, source address and byte-exact response."""
            target = target or hosts.get(host, host)
            data = payload if payload is not None else (host + ':' + uuid.uuid4().hex[:8]).encode()
            client.send(host, sink_port, data)
            event = events.get(timeout=5)
            expected = (target, '127.0.0.1' if expected_branch == 'RU' else source_ip, data)
            assert event == expected, (host, expected_branch, event, expected)
            assert client.response() == data, ('return payload changed', host)
            print(version, host, '->', expected_branch, 'actual source', event[1], 'target', event[0], flush=True)

        def denied(client, host, port, payload=None):
            """Require that a prohibited datagram reaches none of the controlled sinks."""
            marker = payload if payload is not None else ('denied-' + uuid.uuid4().hex).encode()
            client.send(host, port, marker)
            try:
                event = events.get(timeout=.55)
            except queue.Empty:
                return
            raise AssertionError(('prohibited packet reached local sink', host, event))

        tcp_canary('ordinary.ru', 'RU')
        tcp_canary('blocked.ru', 'FOREIGN')
        # Service DNS first must not pin the whole association to the DNS exit.
        with contextlib.closing(Association(connection_port)) as client:
            identifier = 0x2468
            qname = b''.join(bytes([len(part)]) + part.encode() for part in 'ordinary.ru'.split('.')) + b'\0'
            query = struct.pack('>HHHHHH', identifier, 0x0100, 1, 0, 0, 0) + qname + struct.pack('>HH', 1, 1)
            client.send('192.0.2.53', 53, query)
            answer = client.response()
            assert '127.0.0.1' in dns_a_response(answer, identifier), answer.hex()
            assert events.empty(), 'DNS query leaked to an application sink'
            observed(client, 'ordinary.ru', 'RU')
            observed(client, 'other.test', 'FOREIGN')
            print(version, 'same association DNS-first actual A answer -> RU -> foreign', flush=True)
        # One association repeatedly changes routing category, including overlap.
        with contextlib.closing(Association(connection_port)) as client:
            observed(client, 'ordinary.ru', 'RU')
            observed(client, 'other.test', 'FOREIGN')
            observed(client, source_ip, 'FOREIGN', source_ip)
            observed(client, 'blocked.ru', 'FOREIGN')
            observed(client, 'inside.test', 'RU', source_ip)
            observed(client, '127.0.0.1', 'FOREIGN' if empty_ips else 'RU')
            denied(client, '127.0.0.1', prohibited.getsockname()[1])
            denied(client, '::1', sink_port)
            denied(client, 'only6.test', sink_port)
            observed(client, 'ordinary.ru', 'RU')
        with contextlib.closing(Association(connection_port)) as client:
            observed(client, 'other.test', 'FOREIGN')
            observed(client, 'ordinary.ru', 'RU')
            observed(client, 'other.test', 'FOREIGN')
        # QUIC SNI must change the real destination, not merely the route label.
        with contextlib.closing(Association(connection_port)) as client:
            observed(client, '127.0.0.1', 'RU', source_ip, QUIC)
        with contextlib.closing(Association(connection_port)) as client:
            denied(client, '::1', sink_port, QUIC)
            observed(client, 'ordinary.ru', 'RU')
        if transport == 'plain':
            # Offline CI also checks a policy change with fresh core listeners.
            stop(core)
            config['routing']['rules'] = [r for r in config['routing']['rules']
                if not (r.get('outboundTag') == 'direct-russian-ip' and r.get('ip') == ['127.0.0.1/32'])]
            files['candidate.json'].write_text(json.dumps(config))
            core = subprocess.Popen([binary, 'run', '-config', files['candidate.json']], env=env, stdout=core_log, stderr=subprocess.STDOUT)
            stack.callback(stop, core)
            ready(core, public_port, core_log)
            tcp_canary('ordinary.ru', 'RU')
            tcp_canary('blocked.ru', 'FOREIGN')
            print(version, 'variant without Russian-IP route: unmatched literal follows foreign default', flush=True)
            with contextlib.closing(Association(connection_port)) as client:
                observed(client, '127.0.0.1', 'FOREIGN')
                observed(client, 'ordinary.ru', 'RU')
        # Foreign failure must not convert subsequent traffic into direct output.
        stop(foreign_process)
        with contextlib.closing(Association(connection_port)) as client:
            denied(client, 'other.test', sink_port)
            observed(client, 'ordinary.ru', 'RU')
        stop(relay)
        with contextlib.closing(Association(connection_port)) as client:
            denied(client, 'ordinary.ru', sink_port)
        tcp_canary('ordinary.ru', 'RU')
        foreign_process = subprocess.Popen([binary, 'run', '-config', foreign_file], env=env, stdout=foreign_log, stderr=subprocess.STDOUT)
        stack.callback(stop, foreign_process)
        ready(foreign_process, foreign_port, foreign_log)
        tcp_canary('blocked.ru', 'FOREIGN')
        print(version, transport, profile, 'PASS UDP split, DNS-first, TCP canaries, bidirectional payloads, destination changes, prohibited targets, foreign/relay failure', directory if keep else '', flush=True)


if __name__ == '__main__':
    os.umask(0o077)
    parser = argparse.ArgumentParser()
    parser.add_argument('--repo', type=pathlib.Path, default=pathlib.Path.cwd())
    parser.add_argument('--bash', type=pathlib.Path, default=pathlib.Path('/bin/bash'))
    parser.add_argument('--relay-script', type=pathlib.Path)
    parser.add_argument('--xray', '--binary', dest='binary', type=pathlib.Path, action='append', required=True)
    parser.add_argument('--local-ip')
    parser.add_argument('--keep', action='store_true')
    parser.add_argument('--transport', choices=['plain', 'tcp', 'xhttp'], default='plain',
        help='tcp/xhttp additionally exercise real REALITY on both hops; plain bypasses outer transport')
    parser.add_argument('--decoy-name', default='www.cloudflare.com',
        help='TLS name and XHTTP host of the REALITY decoy for full transport checks')
    parser.add_argument('--decoy-target', default='www.cloudflare.com:443',
        help='reachable HOST:PORT of the valid TLS decoy; may be a local SSH forward')
    args = parser.parse_args()
    ip = args.local_ip or local_ip()
    relay_script = args.relay_script or args.repo / 'libexec/private_cascade_udp.py'
    for binary in args.binary:
        run(binary, relay_script, ip, args.keep, args.repo, args.bash, args.transport, args.decoy_name, args.decoy_target)
        if args.transport != 'plain':
            # A distinct cold configuration tests unmatched routing without
            # conflating this policy test with live HTTP/2 restart recovery.
            run(binary, relay_script, ip, args.keep, args.repo, args.bash, args.transport, args.decoy_name, args.decoy_target, True)
