#!/usr/bin/env python3
"""Correlate opt-in loopback evidence without inferring cause from suite totals."""
import argparse
import base64
import json
from pathlib import Path
import re


def decode(entry):
    return base64.b64decode(entry['bytes'])


def framing_order(entries, calls):
    """Check scripted record framing independently of observed recovery transitions."""
    label = next((call for call in calls if call.startswith('sender/')
                  and call.endswith(('/incomplete', '/framed'))), None)
    if label is None:
        return None
    events = {}
    for entry in entries:
        events.setdefault(entry['event'], []).append(entry)
    errors = []
    required = ['fixture.body.scripted', 'framing.prefix.received', 'http.completed',
                'consumer.resume', 'report', 'report.attempt']
    for event in required:
        if len(events.get(event, [])) != 1:
            errors.append(f'framing requires one {event}')
    if errors:
        return {'label': label, 'errors': errors}
    scripted = decode(events['fixture.body.scripted'][0])
    prefix = events['framing.prefix.received'][0]
    completion = events['http.completed'][0]
    resume = events['consumer.resume'][0]
    sends = events.get('send.enter', [])
    prefix_bytes = scripted.split(b'\n', 1)[0]
    if decode(prefix) != prefix_bytes:
        errors.append('prefix differs from scripted first unterminated line')
    if any(entry['uptime'] < prefix['uptime'] for entry in sends):
        errors.append('sender preceded complete first line')
    if label.endswith('/incomplete'):
        if decode(completion) != prefix_bytes:
            errors.append('incomplete transport delivered a suffix')
        if events.get('fixture.suffix.release') or events.get('caller.cancel'):
            errors.append('incomplete case supplied framing or cancelled before transport termination')
        if any('recoveryFailure' not in entry['detail'] for entry in sends):
            errors.append('incomplete line produced a nonterminal sender')
        if any(entry['uptime'] < completion['uptime'] for entry in sends):
            errors.append('terminal sender preceded HTTP termination')
        if not any(f'cause=NSURLErrorDomain/{code} ' in completion['detail'] for code in (-1, -1005)):
            errors.append('incomplete transport lacks typed partial-file/lost-connection cause')
        if not events['report.attempt'][0]['detail'].startswith('transport cause=NSURLErrorDomain/'):
            errors.append('incomplete terminal report is not a typed transport failure')
        progress = events['report'][0]['progress']
        if any(progress[phase][field] for phase in ('observed', 'delivered')
               for field in ('contentBytes', 'reasoningBytes', 'toolFragments', 'completedToolCalls')):
            errors.append('incomplete line produced semantic progress')
        closes = [entry for entry in events.get('socket.close', [])
                  if 'result=0' in entry['detail'] and entry['uptime'] < resume['uptime']]
        if len(closes) != 1:
            errors.append('incomplete transport lacks successful socket closure before resumption')
    else:
        suffix = events.get('fixture.suffix.release', [])
        held = events.get('registration.held', [])
        cancelled = events.get('caller.cancel', [])
        if len(suffix) != 1 or len(held) != 1 or len(cancelled) != 1 or not sends:
            errors.append('framed control lacks suffix, sender, registration or cancellation handshake')
        elif not (prefix['uptime'] < suffix[0]['uptime'] < sends[0]['uptime']
                  <= held[0]['uptime'] < cancelled[0]['uptime'] < completion['uptime']):
            errors.append('framed control violates prefix/suffix/sender/cancellation/HTTP ordering')
        if decode(completion) != scripted:
            errors.append('framed completion bytes differ from complete scripted body')
        if 'cause=NSURLErrorDomain/-999' not in completion['detail']:
            errors.append('framed control lacks typed cancelled HTTP cause')
        if not any(entry['detail'] == 'true' and entry['uptime'] < resume['uptime']
                   for entry in events.get('socket.peer.closed', [])):
            errors.append('framed control lacks peer closure before resumption')
    lifecycle = events.get('lifecycle', [])
    if len(lifecycle) != 3 or any('lifecycle' not in entry for entry in lifecycle):
        errors.append('full lifecycle fields missing')
    path = label.split('/')[-2]
    expected_producers = {'gateway': 1, 'broker': 2, 'session': 3}[path]
    if len(events.get('producer.completed', [])) != expected_producers:
        errors.append('missing or duplicate producer task completion')
    return {'label': label, 'scripted_body': base64.b64encode(scripted).decode(),
            'prefix': prefix, 'errors': errors}


def framing_pairs(calls):
    pairs = {}
    errors = []
    for call in calls:
        framing = call['registration_framing']
        if framing:
            label, mode = framing['label'].rsplit('/', 1)
            if mode in pairs.setdefault(label, {}):
                errors.append(f'{label}: duplicate {mode} experiment')
            pairs[label][mode] = call
    comparisons = []
    for label, pair in pairs.items():
        if set(pair) != {'incomplete', 'framed'}:
            errors.append(f'{label}: missing matched control')
            continue
        rejecting, control = pair['incomplete'], pair['framed']
        if rejecting['registration_framing'].get('scripted_body') != control['registration_framing'].get('scripted_body'):
            errors.append(f'{label}: matched scripted bodies differ')
        if len(rejecting['attempts']) != 1 or len(control['attempts']) != 1:
            errors.append(f'{label}: experiment did not make exactly one request per call')
            continue
        request_bytes = [base64.b64decode(call['attempts'][0]['request_bytes'])
                         for call in (rejecting, control)]
        # JSONEncoder may order keys differently across public invocations. Retain
        # both exact wire captures; compare public request inputs as JSON values.
        if json.loads(request_bytes[0]) != json.loads(request_bytes[1]):
            errors.append(f'{label}: matched public request inputs differ')
        comparisons.append({'label': label, 'rejecting_trace': rejecting['trace'],
                            'control_trace': control['trace'],
                            'raw_request_bytes_equal': request_bytes[0] == request_bytes[1]})
    return {'pairs': comparisons, 'errors': errors}


def characterize(path):
    entries = json.loads(path.read_text())
    calls = [e['detail'] for e in entries if e['event'] == 'call']
    if not calls:
        calls = [e['detail'] for e in entries if e['event'] == 'test']
    if not calls:
        return None
    requests = [e for e in entries if e['event'] == 'wire.request']
    attempts = []
    for index, request in enumerate(requests):
        identity = request.get('identity')
        # Older diagnostic shapes did not encode identities separately.
        if identity is None:
            raise ValueError(f'{path}: missing structured wire identity')
        correlated = [e for e in entries if e.get('identity') == identity]
        body = b''.join(decode(e) for e in correlated if e['event'] == 'wire.body')
        completed = [e for e in correlated if e['event'] == 'http.completed']
        reports = [e for e in entries if e['event'] == 'report'
                   and e.get('logicalID') == identity['logicalID']]
        failures = [e for e in correlated if e['event'] == 'report.attempt']
        next_request = requests[index + 1]['uptime'] if index + 1 < len(requests) else float('inf')
        socket_requests = [e for e in entries if e['event'] == 'socket.request'
                           and decode(e) == decode(request)
                           and request['uptime'] <= e['uptime'] < next_request]
        errors = []
        dispatched = any(e['event'] == 'lifecycle' and e['detail'] == 'attemptStarted'
                         for e in correlated)
        if dispatched and len(completed) != 1:
            errors.append('missing or duplicate final-attempt HTTP delegate completion')
        if len(reports) != 1:
            errors.append('missing or duplicate final-attempt terminal report')
        if completed and any(decode(e) != body for e in completed):
            errors.append('delegate completion bytes differ from wire-observed bytes')
        if failures and any(decode(e) != body for e in failures):
            errors.append('terminal attempt bytes differ from wire-observed bytes')
        if dispatched and completed and reports and completed[-1]['uptime'] > reports[0]['uptime']:
            errors.append('report precedes HTTP delegate completion')
        port = re.search(r'127\.0\.0\.1:(\d+)', request['detail'])
        attempts.append({
            'identity': identity,
            'dispatched': dispatched,
            'port': int(port[1]) if port else None,
            'request_bytes': request['bytes'],
            'observed_body': base64.b64encode(body).decode(),
            'socket_requests': socket_requests,
            'socket_correlation': 'unique' if len(socket_requests) == 1 else
                                  'absent' if not socket_requests else 'ambiguous',
            'delegate_completions': completed,
            'reports': reports,
            'terminal_attempts': failures,
            'lifecycle': [e for e in correlated if e['event'] == 'lifecycle'],
            'ordering_errors': errors,
        })
    held = [e for e in entries if e['event'] == 'registration.held']
    resumes = [e for e in entries if e['event'] == 'consumer.resume']
    finishes = [e for e in entries if e['event'] == 'producer.completed']
    cleanup_errors = []
    if not requests and any(call.startswith(("sender/", "interruption/", "healthy-generation/",
                                             "receivedSemanticProgressSurvivesMalformedTail/")) for call in calls):
        cleanup_errors.append("required public boundary was not reached: no wire proposal recorded")
    if resumes:
        if not finishes or max(e['uptime'] for e in finishes) > resumes[0]['uptime']:
            cleanup_errors.append('consumer resumes before producer completion')
        for attempt in attempts:
            if not attempt['delegate_completions']:
                cleanup_errors.append('consumer resumes without delegate completion evidence')
    timeouts = [e for a in attempts for e in a['delegate_completions']
                if 'cause=NSURLErrorDomain/-1001' in e['detail']]
    return {
        'trace': str(path), 'calls': calls, 'attempts': attempts,
        'registration_framing': framing_order(entries, calls),
        'zero_wire_reports': [e for e in entries if e['event'] == 'report'] if not requests else [],
        'zero_wire_lifecycle': [e for e in entries if e['event'] == 'lifecycle'] if not requests else [],
        'socket_lifetime': [e for e in entries if e['event'].startswith(('socket.', 'listener.'))],
        'registration': [e for e in entries if e['event'].startswith(('registration.', 'send.'))],
        'cancellation': [e for e in entries if e['event'] in ('caller.cancel', 'http.cancel')],
        'producer_completion': finishes,
        'delivery_finish': [e for e in entries if e['event'] in ('finish', 'producer.finished')],
        'consumer_resumption': resumes,
        'fixture_lifetime': [e for e in entries if e['event'].startswith('fixture.')],
        'cleanup_errors': cleanup_errors,
        'timeout_before_registration': any(call.startswith('sender/') for call in calls)
        and bool(timeouts) and (not held or timeouts[0]['uptime'] < held[0]['uptime']),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--syscalls', type=Path)
    args = parser.parse_args()
    paths = sorted(args.directory.glob('*.json'))
    if not paths:
        parser.error('no per-call traces found')
    calls = [call for path in paths if (call := characterize(path)) is not None]
    if not calls:
        parser.error('no named public-call traces found')
    comparisons = framing_pairs(calls)
    output = {'calls': calls, 'registration_framing_comparison': comparisons}
    if args.syscalls:
        lines = args.syscalls.read_text().splitlines()
        output['descriptor_exhaustion'] = [line for line in lines if 'EMFILE' in line]
        # The full syscall log remains authoritative. Endpoint matching supplements
        # fixture FD lifetimes and does not pretend FD numbers are unique forever.
        ports = {attempt['port'] for call in calls for attempt in call['attempts']}
        output['endpoint_syscalls'] = {
            str(port): [line for line in lines if f':{port}' in line or f'htons({port})' in line]
            for port in ports if port is not None
        }
    args.output.write_text(json.dumps(output, indent=2) + '\n')
    errors = [error for call in calls for error in call['cleanup_errors']]
    errors += [error for call in calls for attempt in call['attempts'] for error in attempt['ordering_errors']]
    errors += [error for call in calls if call['registration_framing']
               for error in call['registration_framing']['errors']]
    errors += comparisons['errors']
    print(f'{len(calls)} calls; {len(errors)} independent byte/ordering violations; '
          f'{sum(call["timeout_before_registration"] for call in calls)} HTTP timeouts before registration')
    return bool(errors)


if __name__ == '__main__':
    raise SystemExit(main())
