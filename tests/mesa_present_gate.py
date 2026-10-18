#!/usr/bin/env python3
"""Real GL->Mesa->QUIC test; Linux endpoint inspects, never displays PRESENT."""
import argparse
import os
from pathlib import Path
import re
import signal
import socket
import subprocess
import tempfile
import time


def wait_socket(path, processes):
    # Cold software EGL/LLVM initialization on shared CI runners can exceed
    # ten seconds. Keep this bounded and separate from the 45s render timeout.
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        if any(p.poll() is not None for p in processes):
            raise RuntimeError("RemoteGPU gate process exited before socket ready")
        if Path(path).exists():
            return
        time.sleep(0.05)
    raise TimeoutError(path)


def run_case(stage, readback, native=False, dynamic_frames=0, fault=None, shared_scanout=False):
    stage = stage.resolve()
    env = os.environ.copy()
    processes = []
    with tempfile.TemporaryDirectory(prefix="rgpu-present-") as directory:
        root = Path(directory)
        logs = {}
        handles = []
        def start(name, command, process_env=None):
            log = root / (name + ".log")
            logs[name] = log
            handle = log.open("w")
            handles.append(handle)
            p = subprocess.Popen(command, stdout=handle, stderr=subprocess.STDOUT, env=process_env, start_new_session=True)
            processes.append(p)
            return p
        try:
            renderer_socket, proxy_socket, present_socket, oracle_socket = [str(root / n) for n in ("renderer.sock", "proxy.sock", "present.sock", "oracle.sock")]
            subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", "/CN=localhost", "-keyout", str(root / "key.pem"), "-out", str(root / "cert.pem")], check=True, capture_output=True)
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as reservation:
                reservation.bind(("127.0.0.1", 0))
                address = "127.0.0.1:" + str(reservation.getsockname()[1])
            renderer_env = dict(env)
            if shared_scanout:
                renderer_env["REMOTEGPU_TEST_SHARED_SCANOUT"] = "1"
            virgl_lib = stage / "virglrenderer/lib/x86_64-linux-gnu"
            renderer_env["LD_LIBRARY_PATH"] = str(virgl_lib) + ":" + env.get("LD_LIBRARY_PATH", "")
            renderer_command = ([str(stage / "bin/native-vtest-server"), renderer_socket] if native else
                                [str(stage / "virglrenderer/bin/virgl_test_server"), "--no-fork", "--use-egl-surfaceless", "--use-gles", "--socket-path=" + renderer_socket])
            if dynamic_frames:
                if not native or readback:
                    raise ValueError("Dynamic oracle requires native endpoint and no application readback")
                renderer_command += ["--verify-present-socket", oracle_socket, "--expected-frames", str(dynamic_frames)]
            renderer_process = start("renderer", renderer_command, renderer_env)
            proxy_process = start("proxy", [str(stage / "bin/remotegpu-proxy"), "-unix", proxy_socket, "-present-socket", present_socket, "-listen", address, "-cert", str(root / "cert.pem"), "-key", str(root / "key.pem"), "-pairing-token", "present-ci", "-stats-interval=10ms"])
            for path in (renderer_socket, proxy_socket, present_socket):
                wait_socket(path, processes)
            receiver_command = [str(stage / "bin/remotegpu-vtest-receiver"), "-connect", address, "-socket", renderer_socket, "-pairing-token", "present-ci", "-insecure-skip-verify", "-inspect-present"]
            if dynamic_frames:
                wait_socket(oracle_socket, processes)
                receiver_command += ["-verify-present-socket", oracle_socket]
            start("receiver", receiver_command)
            mesa_dri = next((stage / "mesa").rglob("dri"))
            app_env = dict(GALLIUM_DRIVER="virpipe", REMOTEGPU_VTEST_LEGACY="1", REMOTEGPU_PRESENT_SOCKET=present_socket, VTEST_SOCKET_NAME=proxy_socket, LIBGL_DEBUG="verbose", LIBGL_DRIVERS_PATH=str(mesa_dri), LD_LIBRARY_PATH=str(mesa_dri.parent) + ":" + env.get("LD_LIBRARY_PATH", ""))
            print("Mesa driver directory:", mesa_dri, flush=True)
            # The X server must keep its local software GLX backend. Only the
            # demo receives virpipe, otherwise Xvfb consumes the remote session.
            binary = "gl-remote-present" if dynamic_frames else "gl-present"
            command = ["xvfb-run", "--auto-servernum", "env"] + [f"{key}={value}" for key, value in app_env.items()] + [str(stage / "bin" / binary)]
            if readback:
                command.append("--readback")
            if dynamic_frames:
                command += ["--frames", str(dynamic_frames), "--fps", "24" if dynamic_frames == 7 else "12", "--hold-seconds", "2"]
                if fault:
                    command += ["--test-" + fault + "-frame", "3"]
                app = start("app", command, env)
                deadline = time.monotonic() + 45
                hold_seen = False
                while app.poll() is None and time.monotonic() < deadline:
                    renderer_log = logs["renderer"].read_text()
                    if fault and "ORACLE_MISMATCH app_frame=3 " in renderer_log:
                        os.killpg(app.pid, signal.SIGTERM)
                        break
                    if "ORACLE_HOLD_PASS" in renderer_log and not hold_seen:
                        app_log = logs["app"].read_text()
                        if "HOLD_BEGIN" not in app_log or "HOLD_END" in app_log:
                            raise AssertionError("Final frame was not verified during live session hold")
                        hold_seen = True
                    if renderer_process.poll() not in (None, 0):
                        break
                    time.sleep(0.02)
                try:
                    app.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    raise TimeoutError("Dynamic app failed to finish")
                result = subprocess.CompletedProcess(command, app.returncode, logs["app"].read_text(), "")
                renderer_process.wait(timeout=10)
                renderer_log = logs["renderer"].read_text()
                if fault:
                    if renderer_process.returncode != 1 or "ORACLE_MISMATCH app_frame=3 " not in renderer_log:
                        raise AssertionError("Negative fixture was not rejected by pixel oracle: " + renderer_log)
                else:
                    frames = re.findall(r"ORACLE_FRAME app_frame=(\d+) ", renderer_log)
                    if frames != [str(i) for i in range(dynamic_frames)] or not hold_seen or f"ORACLE_PASS frames={dynamic_frames} " not in renderer_log or renderer_process.returncode:
                        raise AssertionError("Native pixel/hold acceptance missing: " + renderer_log)
                    if shared_scanout:
                        reads = re.search(r"ORACLE_PASS frames=\d+ test_side_readbacks=(\d+)", renderer_log)
                        snapshots = renderer_log.count("TEST_GPU_SCANOUT resource=")
                        if not reads or int(reads[1]) != snapshots or snapshots <= dynamic_frames:
                            raise AssertionError("GPU snapshot test-side readback accounting incorrect: " + renderer_log)
            else:
                result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=45)
            print(result.stdout, end="")
            if result.returncode and not fault:
                raise RuntimeError(f"GL present demo failed ({result.returncode}): {result.stderr}")
            proxy_process.send_signal(signal.SIGUSR1)
            deadline = time.monotonic() + 5
            while "STAT_FLUSH completed" not in logs["proxy"].read_text():
                if time.monotonic() >= deadline:
                    raise TimeoutError("Proxy did not flush diagnostic counters")
                time.sleep(0.01)
            receiver_log = logs["receiver"].read_text()
            proxy_log = logs["proxy"].read_text()
            gets = sum(int(v) for v in re.findall(r"(?:\[| )4:(\d+)(?: |\])", proxy_log))
            submits = sum(int(v) for v in re.findall(r"(?:\[| )6:(\d+)(?: |\])", proxy_log))
            if dynamic_frames and (gets or submits == 0):
                raise AssertionError("Expected real SUBMIT_CMD and zero wire TRANSFER_GET: " + proxy_log)
            if fault:
                print(f"PASS: pixel oracle rejected {fault} fixture at app_frame=3; TRANSFER_GET={gets}")
                return
            presents = re.findall(r"INSPECT_PRESENT frame=(\d+) resource=(\d+) after=(\d+) processed=(\d+) size=64x64", receiver_log)
            if len(presents) < 3 or [int(p[0]) for p in presents] != list(range(1, len(presents) + 1)):
                raise AssertionError("Expected at least three consecutive 64x64 PRESENTs: " + receiver_log)
            if any(int(p[2]) > int(p[3]) for p in presents):
                raise AssertionError("PRESENT overtook vtest commands")
            if dynamic_frames and len(presents) not in (dynamic_frames, dynamic_frames + 1):
                raise AssertionError("Unexpected missing/extra dynamic PRESENTs")
            if readback:
                if gets == 0 or "PASS: application readback red pixel" not in result.stdout:
                    raise AssertionError("Application glReadPixels was suppressed")
            elif gets:
                raise AssertionError("Presentation issued TRANSFER_GET: " + proxy_log)
            print(f"PASS: present markers={len(presents)}, application_readback={readback}, TRANSFER_GET={gets}")
            if dynamic_frames:
                print(f"PASS A1 LINUX ONLY: frames={dynamic_frames} SUBMIT_CMD={submits} PRESENT={len(presents)} wire_TRANSFER_GET={gets}; receiver-local CPU oracle, NOT iPhone acceptance")
        finally:
            for p in reversed(processes):
                try:
                    os.killpg(p.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
            for p in reversed(processes):
                try:
                    p.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    p.kill()
                    p.wait()
            for handle in handles:
                handle.close()
            for name, path in logs.items():
                print(f"--- {name} diagnostics ---\n{path.read_text()}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("stage", type=Path)
    parser.add_argument("--native", action="store_true", help="Use the shared iOS native vtest decoder")
    parser.add_argument("--dynamic", action="store_true", help="A1 receiver-local pixel oracle, positive and deliberately corrupt/repeated-frame cases")
    parser.add_argument("--shared-scanout", action="store_true", help="A2.1 A1->QUIC->shared-context GPU snapshot display-row oracle (Linux only)")
    args = parser.parse_args()
    if args.shared_scanout:
        run_case(args.stage, False, True, 7, shared_scanout=True)
    elif args.dynamic:
        run_case(args.stage, False, True, 12)
        run_case(args.stage, False, True, 7)
        run_case(args.stage, False, True, 6, "corrupt")
        run_case(args.stage, False, True, 6, "repeat")
    else:
        run_case(args.stage, False, args.native)
        run_case(args.stage, True, args.native)
