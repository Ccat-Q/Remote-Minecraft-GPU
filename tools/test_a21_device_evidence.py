import unittest
from a21_device_evidence import analyze

SHA = 'a' * 40


def fixture(frames=7, session='session-one'):
    ubuntu = 'GL_RENDERER=virgl\n'
    for i in range(frames):
        ubuntu += f'DRAW frame={i} offset={(i % 5 - 2) * .16:.3f},{(i // 5 % 3 - 1) * .12:.3f} rgb={40 + i * 37 % 180},{50 + i * 67 % 170},{60 + i * 97 % 160}\n'
    ubuntu += f'HOLD_BEGIN frames={frames} seconds=120.000 resources_alive=1\n'
    phone = f'A2.1 REAL REMOTE DISPLAY\nDevice: SYNTHETIC UNIT TEST, NOT PHYSICAL EVIDENCE\n"app_source_sha": "{SHA}"\nA21_SESSION session={session} clock=local_monotonic\n'
    for i in range(1, frames + 2):
        phone += f'PRESENT received frame={i} resource=1 after={i} processed={i}\n'
        phone += 'Remote producer fence complete: GL error 0x0\nCreate shared copy context: EGL error 0x3000\nGPU copy fence complete: 0x911c\nSnapshot complete; source pin released.\nMetal command status: COMPLETED\nTRANSFER_GET=0\n'
        phone += f'A21_FRAME present={i} resource=1 after={i} completed_ms={i * 1000:.3f} duration_ms=2.000\n'
    phone += f'A21_HOLD live=YES last_present={frames + 1} quiet_s=120.100 completed={frames + 1}\n'
    phone += f'A21_SESSION_CLOSED session={session} displayed={frames + 1} cleanup_returned=YES reason=User cancelled display session\n'
    return ubuntu, phone


class DeviceEvidenceTests(unittest.TestCase):
    def test_seven_and_twelve_frames_still_require_human_visual_review(self):
        for frames in (7, 12):
            ubuntu, phone = fixture(frames)
            result = analyze(ubuntu, phone, frames, SHA, True)
            self.assertEqual(result['completed_presents'], frames + 1)
            self.assertEqual(result['device_visual_acceptance'], 'USER_REVIEW_REQUIRED')

    def test_receive_only_wrong_pixels_logs_order_readback_hold_cleanup_rejected(self):
        ubuntu, phone = fixture()
        for changed_ubuntu, changed_phone in (
            (ubuntu, phone.replace('A21_FRAME present=2 ', 'RECEIVED_ONLY present=2 ')),
            (ubuntu.replace('rgb=40,50,60', 'rgb=40,0,60'), phone),
            (ubuntu, phone.replace('after=2 processed=2', 'after=2 processed=1')),
            (ubuntu, phone.replace('TRANSFER_GET=0', 'TRANSFER_GET=1')),
            (ubuntu, phone.replace('quiet_s=120.100', 'quiet_s=29.999')),
            (ubuntu, phone.replace('live=YES', 'live=NO')),
            (ubuntu, phone.replace('cleanup_returned=YES', 'cleanup_returned=NO')),
            (ubuntu, phone.replace('Metal command status: COMPLETED', 'Metal command status: FAILED')),
            (ubuntu, phone.replace('GL error 0x0', 'GL error 0x502')),
            (ubuntu, phone.replace('EGL error 0x3000', 'EGL error 0x3004')),
            (ubuntu, phone.replace(SHA, 'b' * 40)),
        ):
            with self.assertRaises(ValueError):
                analyze(changed_ubuntu, changed_phone, 7, SHA, True)

    def test_new_session_identity_required_for_reconnect(self):
        ubuntu, phone = fixture(session='new')
        _, previous = fixture(session='old')
        self.assertTrue(analyze(ubuntu, phone, 7, SHA, True, previous)['fresh_session_after_cleanup_observed'])
        with self.assertRaises(ValueError):
            analyze(ubuntu, phone, 7, SHA, True, phone)
        with self.assertRaises(ValueError):
            analyze(ubuntu, phone, 7, SHA, True, previous.replace('cleanup_returned=YES', 'cleanup_returned=NO'))

    def test_30_second_default_does_not_claim_historical_120_second_hold(self):
        ubuntu, phone = fixture()
        ubuntu = ubuntu.replace('seconds=120.000', 'seconds=35.000')
        phone = phone.replace('quiet_s=120.100', 'quiet_s=30.100')
        result = analyze(ubuntu, phone, 7, SHA, True)
        self.assertEqual(result['required_hold_seconds'], 30)
        self.assertFalse(result['meets_120_second_hold'])
        with self.assertRaises(ValueError):
            analyze(ubuntu, phone, 7, SHA, True, min_hold_seconds=120)

    def test_explicit_longer_observation_and_historical_threshold(self):
        ubuntu, phone = fixture()
        for seconds in (30, 60, 120):
            result = analyze(ubuntu, phone, 7, SHA, True, min_hold_seconds=seconds)
            self.assertTrue(result['meets_120_second_hold'])
        for seconds in (0, 29, 3601, float('nan'), float('inf')):
            with self.assertRaises(ValueError):
                analyze(ubuntu, phone, 7, SHA, min_hold_seconds=seconds)
        with self.assertRaises(ValueError):
            analyze(ubuntu, phone.replace('quiet_s=120.100', 'quiet_s=119.999'), 7, SHA, min_hold_seconds=120)
        with self.assertRaises(ValueError):
            analyze(ubuntu.replace('seconds=120.000', 'seconds=29.000'), phone, 7, SHA)

    def test_declared_case_target_cannot_be_silently_weakened_by_checker_default(self):
        ubuntu, phone = fixture()
        ubuntu = 'A21_CASE frames=7 fps=1 hold_s=60 observation_s=60 resource_hold_s=65; UTC=test\n' + ubuntu
        phone = phone.replace('quiet_s=120.100', 'quiet_s=30.100')
        with self.assertRaises(ValueError):
            analyze(ubuntu, phone, 7, SHA)
        result = analyze(ubuntu, phone.replace('quiet_s=30.100', 'quiet_s=60.100'), 7, SHA)
        self.assertEqual(result['required_hold_seconds'], 60)
