#!/usr/bin/env python3
"""Check user-supplied A2.1 logs; NEVER substitute CI pixels for phone acceptance."""
import argparse
import json
from pathlib import Path
import re


def require(condition, message):
    if not condition:
        raise ValueError(message)


def phone_identity(report, expected_sha):
    sources = re.findall(r'"app_source_sha"\s*:\s*"([0-9a-f]{40})"', report)
    sessions = re.findall(r'A21_SESSION session=([A-Za-z0-9-]+) clock=local_monotonic', report)
    require(sources == [expected_sha], 'Missing/wrong/ambiguous iPhone source SHA')
    require(len(sessions) == 1, 'Exactly one phone session report is required')
    require('A2.1 REAL REMOTE DISPLAY' in report and 'Device:' in report, 'Not a device remote-display report')
    return sessions[0]


def analyze(ubuntu, phone, frames, expected_sha, require_cleanup=False, previous_phone=None):
    require(frames in (1, 7, 12), 'Only finite A2.1 cases 1/7/12 are supported')
    session = phone_identity(phone, expected_sha)
    require('GL_RENDERER=virgl' in ubuntu, 'Ubuntu did not report remote VirGL')
    draws = re.findall(r'DRAW frame=(\d+) offset=([-\d.]+),([-\d.]+) rgb=(\d+),(\d+),(\d+)', ubuntu)
    require(len(draws) == frames, 'Missing/extra Ubuntu application frames')
    for i, draw in enumerate(draws):
        n, x, y, r, g, b = draw
        require(int(n) == i, 'Ubuntu application frame order mismatch')
        require(abs(float(x) - (i % 5 - 2) * .16) < .0011 and
                abs(float(y) - (i // 5 % 3 - 1) * .12) < .0011, 'Unexpected triangle position')
        require((int(r), int(g), int(b)) == (40 + i * 37 % 180, 50 + i * 67 % 170, 60 + i * 97 % 160),
                'Unexpected triangle color')
    hold_begin = re.search(r'HOLD_BEGIN frames=(\d+) seconds=([\d.]+) resources_alive=1', ubuntu)
    require(hold_begin and int(hold_begin[1]) == frames and float(hold_begin[2]) >= 120,
            'Ubuntu live-resource hold was not configured for at least 120 seconds')
    completed = re.findall(r'A21_FRAME present=(\d+) resource=(\d+) after=(\d+) completed_ms=([\d.]+) duration_ms=([\d.]+)', phone)
    count = len(completed)
    require(count in (frames, frames + 1), 'Missing/extra completed Metal frames (startup PRESENT is allowed)')
    require([int(row[0]) for row in completed] == list(range(1, count + 1)), 'Nonconsecutive displayed PRESENTs')
    received = re.findall(r'PRESENT received frame=(\d+) resource=(\d+) after=(\d+) processed=(\d+)', phone)
    require(len(received) == count, 'Receive/completion count mismatch')
    last_time = -1.0
    last_after = -1
    for row, arrival in zip(completed, received):
        present, resource, after, ended, duration = row
        require((present, resource, after) == arrival[:3] and after == arrival[3], 'PRESENT sequence/resource mismatch')
        require(int(resource) > 0 and int(after) > last_after and float(ended) >= last_time,
                'Invalid resource or regressing frame timing/order')
        last_after, last_time = int(after), float(ended)
    for marker in ('Remote producer fence complete: GL error 0x0', 'GPU copy fence complete:',
                   'Snapshot complete; source pin released.', 'Metal command status: COMPLETED'):
        require(phone.count(marker) == count, 'Missing completion/isolation evidence: ' + marker)
    gets = re.findall(r'TRANSFER_GET=(\d+)', phone)
    require(gets and all(int(value) == 0 for value in gets), 'Display readback missing or nonzero')
    require(all(int(value, 16) == 0 for value in re.findall(r'GL error 0x([0-9a-fA-F]+)', phone)), 'GL error reported')
    require(all(int(value, 16) == 0x3000 for value in re.findall(r'EGL error 0x([0-9a-fA-F]+)', phone)), 'EGL error reported')
    require(not any(marker in phone for marker in ('NETWORK FAILED:', 'REMOTE DISPLAY FAILED:', 'INIT FAILED:')),
            'Device reported a failed session')
    holds = re.findall(r'A21_HOLD live=YES last_present=(\d+) quiet_s=([\d.]+) completed=(\d+)', phone)
    quiet = max((float(seconds) for frame, seconds, n in holds if int(frame) == count and int(n) == count), default=0)
    require(quiet >= 120, 'No 120-second quiet live-session observation for the final displayed frame')
    closed = f'A21_SESSION_CLOSED session={session} displayed={count} cleanup_returned=YES reason=User cancelled display session' in phone
    require(not require_cleanup or closed, 'User-disconnect/native-cleanup evidence missing')
    reconnect = False
    if previous_phone is not None:
        previous = phone_identity(previous_phone, expected_sha)
        require(previous != session, 'Reconnect reused the same session ID')
        require(re.search(rf'A21_SESSION_CLOSED session={re.escape(previous)} displayed=\d+ cleanup_returned=YES reason=User cancelled display session', previous_phone),
                'Previous phone session did not finish user cancellation cleanup')
        reconnect = True
    return {'technical_log_checks': 'PASS', 'device_visual_acceptance': 'USER_REVIEW_REQUIRED',
            'session_id': session, 'app_source_sha': expected_sha, 'application_frames': frames,
            'completed_presents': count, 'startup_present_count': count - frames,
            'quiet_live_seconds': quiet, 'display_TRANSFER_GET': 0,
            'user_disconnect_cleanup_observed': closed, 'fresh_session_after_cleanup_observed': reconnect,
            'timing_scope': 'phone-local monotonic completion durations, NOT cross-device latency',
            'present_duration_ms': [float(row[4]) for row in completed],
            'remaining': ['User screen recording/screenshots must verify EVERY frame color, position and orientation.',
                          'No sustained A3 FPS, ten-minute stability or Minecraft capability acceptance implied.']}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ubuntu-log', type=Path, required=True)
    parser.add_argument('--iphone-report', type=Path, required=True)
    parser.add_argument('--frames', type=int, choices=(1, 7, 12), required=True)
    parser.add_argument('--expected-sha', required=True)
    parser.add_argument('--require-cleanup', action='store_true')
    parser.add_argument('--previous-iphone-report', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    try:
        result = analyze(args.ubuntu_log.read_text(), args.iphone_report.read_text(), args.frames,
                         args.expected_sha, args.require_cleanup,
                         args.previous_iphone_report.read_text() if args.previous_iphone_report else None)
    except ValueError as error:
        parser.exit(1, f'INCOMPLETE/FAILED evidence: {error}\n')
    # Exclusive creation: never overwrite a previous device acceptance record.
    with args.output.open('x') as output:
        json.dump(result, output, indent=2)
        output.write('\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
