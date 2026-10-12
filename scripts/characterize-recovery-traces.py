#!/usr/bin/env python3
"""Correlate opt-in loopback evidence without inferring cause from suite totals."""
import argparse
import base64
import json
from pathlib import Path
import re


def decode(entry):
    return base64.b64decode(entry['bytes'])


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
    output = {'calls': calls}
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
    print(f'{len(calls)} calls; {len(errors)} independent byte/ordering violations; '
          f'{sum(call["timeout_before_registration"] for call in calls)} HTTP timeouts before registration')
    return bool(errors)


if __name__ == '__main__':
    raise SystemExit(main())
