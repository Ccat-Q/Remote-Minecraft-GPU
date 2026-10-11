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
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if any(p.poll() is not None for p in processes):
            raise RuntimeError("RemoteGPU gate process exited before socket ready")
        if Path(path).exists():
            return
        time.sleep(0.05)
    raise TimeoutError(path)


def run_case(stage, readback):
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
            p = subprocess.Popen(command, stdout=handle, stderr=subprocess.STDOUT, env=process_env)
            processes.append(p)
            return p
        try:
            renderer_socket, proxy_socket, present_socket = [str(root / n) for n in ("renderer.sock", "proxy.sock", "present.sock")]
            subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", "/CN=localhost", "-keyout", str(root / "key.pem"), "-out", str(root / "cert.pem")], check=True, capture_output=True)
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as reservation:
                reservation.bind(("127.0.0.1", 0))
                address = "127.0.0.1:" + str(reservation.getsockname()[1])
            renderer_env = dict(env)
            virgl_lib = stage / "virglrenderer/lib/x86_64-linux-gnu"
            renderer_env["LD_LIBRARY_PATH"] = str(virgl_lib) + ":" + env.get("LD_LIBRARY_PATH", "")
            start("renderer", [str(stage / "virglrenderer/bin/virgl_test_server"), "--no-fork", "--use-egl-surfaceless", "--use-gles", "--socket-path=" + renderer_socket], renderer_env)
            proxy_process = start("proxy", [str(stage / "bin/remotegpu-proxy"), "-unix", proxy_socket, "-present-socket", present_socket, "-listen", address, "-cert", str(root / "cert.pem"), "-key", str(root / "key.pem"), "-pairing-token", "present-ci", "-stats-interval=10ms"])
            for path in (renderer_socket, proxy_socket, present_socket):
                wait_socket(path, processes)
            start("receiver", [str(stage / "bin/remotegpu-vtest-receiver"), "-connect", address, "-socket", renderer_socket, "-pairing-token", "present-ci", "-insecure-skip-verify", "-inspect-present"])
            mesa_dri = next((stage / "mesa").rglob("dri"))
            app_env = dict(GALLIUM_DRIVER="virpipe", REMOTEGPU_VTEST_LEGACY="1", REMOTEGPU_PRESENT_SOCKET=present_socket, VTEST_SOCKET_NAME=proxy_socket, LIBGL_DEBUG="verbose", LIBGL_DRIVERS_PATH=str(mesa_dri), LD_LIBRARY_PATH=str(mesa_dri.parent) + ":" + env.get("LD_LIBRARY_PATH", ""))
            print("Mesa driver directory:", mesa_dri, flush=True)
            # The X server must keep its local software GLX backend. Only the
            # demo receives virpipe, otherwise Xvfb consumes the remote session.
            command = ["xvfb-run", "--auto-servernum", "env"] + [f"{key}={value}" for key, value in app_env.items()] + [str(stage / "bin/gl-present")]
            if readback:
                command.append("--readback")
            result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=45)
            print(result.stdout, end="")
            if result.returncode:
                raise RuntimeError(f"GL present demo failed ({result.returncode}): {result.stderr}")
            proxy_process.send_signal(signal.SIGUSR1)
            deadline = time.monotonic() + 5
            while "STAT_FLUSH completed" not in logs["proxy"].read_text():
                if time.monotonic() >= deadline:
                    raise TimeoutError("Proxy did not flush diagnostic counters")
                time.sleep(0.01)
            receiver_log = logs["receiver"].read_text()
            presents = re.findall(r"INSPECT_PRESENT frame=(\d+) resource=(\d+) after=(\d+) processed=(\d+) size=64x64", receiver_log)
            if len(presents) < 3 or [int(p[0]) for p in presents] != list(range(1, len(presents) + 1)):
                raise AssertionError("Expected at least three consecutive 64x64 PRESENTs: " + receiver_log)
            if any(int(p[2]) > int(p[3]) for p in presents):
                raise AssertionError("PRESENT overtook vtest commands")
            proxy_log = logs["proxy"].read_text()
            gets = sum(int(v) for v in re.findall(r"(?:\[| )4:(\d+)(?: |\])", proxy_log))
            if readback:
                if gets == 0 or "PASS: application readback red pixel" not in result.stdout:
                    raise AssertionError("Application glReadPixels was suppressed")
            elif gets:
                raise AssertionError("Presentation issued TRANSFER_GET: " + proxy_log)
            print(f"PASS: present markers={len(presents)}, application_readback={readback}, TRANSFER_GET={gets}")
        finally:
            for p in reversed(processes):
                if p.poll() is None:
                    p.terminate()
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
    args = parser.parse_args()
    run_case(args.stage, False)
    run_case(args.stage, True)
