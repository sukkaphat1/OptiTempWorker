#!/usr/bin/python3
"""Provision, update, run, drain, and retire an isolated WSL CPU fleet."""
from __future__ import annotations

from datetime import datetime, timedelta, timezone
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from typing import Any, Mapping
import urllib.error
import urllib.request
import uuid
import zipfile

JOIN = Path("/etc/opti-temporary-worker/join.json")
STATE_ROOT = Path("/var/lib/opti-temporary-worker")
STATE = STATE_ROOT / "machine.json"
HANDOFF = STATE_ROOT / "handoff.json"
DRAIN_REQUEST = STATE_ROOT / "drain.requested"
COMMON = Path("/opt/opti-worker-common")
SLOTS = Path("/opt/opti-worker-slots")
RUNTIME_PYTHON = Path("/opt/opti-runtime/.venv/bin/python")
LOG_ROOT = Path("/var/log/opti-temporary-worker")
UPDATE_ROOT = Path("/var/cache/opti-temporary-worker")
JOIN_FORMAT = "opti-temporary-wsl-join-v1"
MAX_SLOTS = 256
UPDATE_POLL_SECONDS = 60
DEFAULT_DRAIN_SECONDS = 600


class ControlError(RuntimeError):
    pass


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def read_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ControlError(f"cannot read {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise ControlError(f"{path} must contain a JSON object")
    return value


def atomic_json(path: Path, value: Mapping[str, Any], mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{uuid.uuid4().hex}.tmp")
    temporary.write_text(json.dumps(dict(value), sort_keys=True, separators=(",", ":")), encoding="utf-8")
    os.chmod(temporary, mode); os.replace(temporary, path)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def run(command: list[str], *, timeout: float = 300.0, check: bool = True,
        capture: bool = True, cwd: str | Path | None = None) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(command, text=True, capture_output=capture, timeout=timeout, cwd=cwd)
    if check and result.returncode:
        detail = (result.stderr or result.stdout or "unknown error").strip()[-2000:]
        raise ControlError(f"command failed ({result.returncode}): {' '.join(command[:3])}: {detail}")
    return result


class HostClient:
    def __init__(self, host_url: str, protocol: int = 2) -> None:
        self.host_url = str(host_url).rstrip("/")
        self.protocol = int(protocol)

    def request(self, method: str, path: str, *, body: Mapping[str, Any] | None = None,
                credential: Mapping[str, Any] | None = None, timeout: float = 120.0) -> tuple[bytes, Mapping[str, str]]:
        headers = {"X-Opti-Protocol": str(self.protocol), "Content-Type": "application/json"}
        if credential:
            headers["Authorization"] = f"OptiWorker {credential['worker_id']}:{credential['worker_secret']}"
        data = json.dumps(dict(body), separators=(",", ":")).encode("utf-8") if body is not None else None
        request = urllib.request.Request(self.host_url + path, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                return response.read(), dict(response.headers.items())
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")[:1000]
            raise ControlError(f"host returned HTTP {exc.code}: {detail}") from exc
        except urllib.error.URLError as exc:
            raise ControlError(f"cannot reach Opti host: {exc}") from exc

    def json(self, method: str, path: str, *, body: Mapping[str, Any] | None = None,
             credential: Mapping[str, Any] | None = None, timeout: float = 120.0) -> dict[str, Any]:
        payload, _ = self.request(method, path, body=body, credential=credential, timeout=timeout)
        try: value = json.loads(payload.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise ControlError("host returned invalid JSON") from exc
        if not isinstance(value, dict): raise ControlError("host returned non-object JSON")
        return value

    def health(self) -> dict[str, Any]:
        # Health intentionally needs no protocol header, so it can teach an
        # old bootstrap which protocol its exact host currently requires.
        request = urllib.request.Request(self.host_url + "/health", method="GET")
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                value = json.loads(response.read().decode("utf-8"))
        except Exception as exc:
            raise ControlError(f"cannot read Opti host health: {exc}") from exc
        if not isinstance(value, dict) or not value.get("ok"):
            raise ControlError("Opti host health response is invalid")
        self.protocol = int(value["protocol"])
        return value


def wait_for_tailscale(join: Mapping[str, Any], machine_name: str) -> None:
    run(["systemctl", "start", "tailscaled.service"], timeout=60)
    try:
        existing = run(["tailscale", "ip", "-4"], timeout=10, check=False)
        if existing.returncode == 0 and existing.stdout.strip(): return
    except OSError:
        pass
    key = str(join.get("tailscale_auth_key", ""))
    if not key.startswith("tskey-"):
        raise ControlError("one-use Tailscale key is missing")
    key_path = STATE_ROOT / "tailscale-auth.key"
    key_path.parent.mkdir(parents=True, exist_ok=True)
    key_path.write_text(key + "\n", encoding="ascii"); os.chmod(key_path, 0o600)
    deadline = time.monotonic() + 20 * 60
    try:
        while True:
            result = run([
                "tailscale", "up", "--reset", f"--auth-key=file:{key_path}",
                f"--hostname={machine_name}", "--accept-routes=false", "--accept-dns=true", "--timeout=90s",
            ], timeout=120, check=False)
            address = run(["tailscale", "ip", "-4"], timeout=10, check=False)
            if result.returncode == 0 and address.returncode == 0 and address.stdout.strip(): return
            if time.monotonic() >= deadline:
                detail = (result.stderr or result.stdout or "Tailscale did not assign an IP").strip()[-1000:]
                raise ControlError(f"Tailscale enrollment timed out: {detail}")
            time.sleep(10)
    finally:
        try: key_path.unlink()
        except FileNotFoundError: pass


def safe_extract(archive: Path, destination: Path) -> None:
    with zipfile.ZipFile(archive) as bundle:
        for member in bundle.infolist():
            relative = PurePosixPath(member.filename)
            if relative.is_absolute() or ".." in relative.parts:
                raise ControlError(f"unsafe update archive path: {member.filename}")
            mode = (member.external_attr >> 16) & 0o170000
            if mode == 0o120000:
                raise ControlError(f"update archive contains a symbolic link: {member.filename}")
            target = (destination / Path(*relative.parts)).resolve()
            if destination.resolve() not in target.parents and target != destination.resolve():
                raise ControlError(f"update archive escapes extraction root: {member.filename}")
        bundle.extractall(destination)


def verify_payload(payload: Path, required_build: str) -> dict[str, Any]:
    manifest = read_json(payload / "worker_manifest.json")
    if manifest.get("format") != "opti-worker-package-v1" or manifest.get("build_id") != required_build:
        raise ControlError("worker update manifest does not match the host build")
    files = manifest.get("files")
    if not isinstance(files, dict) or not files: raise ControlError("worker update manifest has no files")
    expected: set[str] = set()
    for name, expected_hash in files.items():
        relative = PurePosixPath(str(name))
        if relative.is_absolute() or ".." in relative.parts:
            raise ControlError(f"invalid manifest path: {name}")
        target = (payload / Path(*relative.parts)).resolve()
        if payload.resolve() not in target.parents or not target.is_file() or target.is_symlink():
            raise ControlError(f"manifest file is missing or unsafe: {name}")
        if sha256(target) != str(expected_hash): raise ControlError(f"manifest hash failed: {name}")
        expected.add(relative.as_posix())
    actual = {
        path.relative_to(payload).as_posix() for path in payload.rglob("*")
        if path.is_file() and path.name != "worker_manifest.json"
    }
    if actual != expected: raise ControlError("worker update file set differs from its manifest")
    return manifest


def install_update(client: HostClient, credential: Mapping[str, Any], required_build: str) -> None:
    UPDATE_ROOT.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="update-", dir=UPDATE_ROOT) as temporary_name:
        temporary = Path(temporary_name); archive = temporary / "worker.zip"
        payload, headers = client.request("GET", "/v1/update", credential=credential, timeout=300)
        archive.write_bytes(payload)
        expected_hash = str(headers.get("X-Content-SHA256", headers.get("x-content-sha256", "")))
        header_build = str(headers.get("X-Opti-Build-ID", headers.get("x-opti-build-id", "")))
        if header_build != required_build or sha256(archive) != expected_hash:
            raise ControlError("worker update download failed host build/hash verification")
        extracted = temporary / "extracted"; extracted.mkdir()
        safe_extract(archive, extracted)
        payload_root = extracted / "OptiWorkerSetup" / "payload"
        verify_payload(payload_root, required_build)
        candidate = Path(f"/opt/.opti-worker-common-{uuid.uuid4().hex}")
        rollback = Path(f"/opt/.opti-worker-rollback-{uuid.uuid4().hex}")
        shutil.move(str(payload_root), candidate)
        os.symlink(RUNTIME_PYTHON.parent.parent, candidate / ".venv", target_is_directory=True)
        for directory in ("models", "real_runs", "episodes", "bot_export", "replays", "logs"):
            (candidate / directory).mkdir(exist_ok=True)
        try:
            if COMMON.exists() or COMMON.is_symlink(): os.replace(COMMON, rollback)
            os.replace(candidate, COMMON)
            check = run([
                str(RUNTIME_PYTHON), "-c",
                "import torch,requests,psutil,rlgym_sim,RocketSim; "
                "from pathlib import Path; from multi_worker.common import current_build_id; "
                f"assert current_build_id(Path('/opt/opti-worker-common')) == '{required_build}'; "
                "assert not torch.cuda.is_available(); print('Opti WSL CPU runtime verified')",
            ], timeout=180, capture=True, cwd=COMMON)
            (LOG_ROOT / "last-selftest.log").write_text(check.stdout + check.stderr, encoding="utf-8")
            if rollback.exists(): shutil.rmtree(rollback)
        except Exception:
            failed = Path(f"/opt/.opti-worker-failed-{uuid.uuid4().hex}")
            if COMMON.exists(): os.replace(COMMON, failed)
            if rollback.exists(): os.replace(rollback, COMMON)
            shutil.rmtree(failed, ignore_errors=True)
            raise
        finally:
            shutil.rmtree(candidate, ignore_errors=True)


def rebuild_slots(machine: Mapping[str, Any]) -> None:
    credentials = machine.get("slots")
    if not isinstance(credentials, list) or not credentials:
        raise ControlError("temporary machine has no slot credentials")
    replacement = Path(f"/opt/.opti-worker-slots-{uuid.uuid4().hex}")
    replacement.mkdir(parents=True)
    try:
        for item in credentials:
            if not isinstance(item, dict): raise ControlError("temporary slot credential is invalid")
            index = int(item["slot_index"]); slot = replacement / f"slot-{index:03d}"
            shutil.copytree(COMMON, slot, symlinks=True, copy_function=os.link)
            packaged_state = slot / "worker_state"
            if packaged_state.exists() or packaged_state.is_symlink():
                if packaged_state.is_dir() and not packaged_state.is_symlink(): shutil.rmtree(packaged_state)
                else: packaged_state.unlink()
            persistent = STATE_ROOT / "slots" / f"slot-{index:03d}"
            persistent.mkdir(parents=True, exist_ok=True); os.chmod(persistent, 0o700)
            atomic_json(persistent / "credentials.json", {
                "format": "opti-worker-credentials-v1", "host_url": item["host_url"],
                "worker_id": item["worker_id"], "worker_secret": item["worker_secret"],
            })
            for marker in ("stop.requested", "worker.pid"):
                try: (persistent / marker).unlink()
                except FileNotFoundError: pass
            os.symlink(persistent, packaged_state, target_is_directory=True)
        old = Path(f"/opt/.opti-worker-slots-old-{uuid.uuid4().hex}")
        if SLOTS.exists(): os.replace(SLOTS, old)
        os.replace(replacement, SLOTS)
        shutil.rmtree(old, ignore_errors=True)
    finally:
        shutil.rmtree(replacement, ignore_errors=True)


def machine_name() -> str:
    name_path = STATE_ROOT / "machine-name"
    if name_path.is_file(): return name_path.read_text(encoding="ascii").strip()
    value = "opti-wsl-" + uuid.uuid4().hex[:12]
    name_path.parent.mkdir(parents=True, exist_ok=True)
    name_path.write_text(value + "\n", encoding="ascii"); os.chmod(name_path, 0o600)
    run(["hostname", value], check=False)
    Path("/etc/hostname").write_text(value + "\n", encoding="ascii")
    return value


def write_windows_lease(join: Mapping[str, Any], machine: Mapping[str, Any]) -> None:
    destination = str(join.get("windows_lease_path", ""))
    if not destination.startswith("/mnt/c/ProgramData/OptiTemporaryWorker/"):
        raise ControlError("Windows lease handoff path is outside the Opti installation root")
    atomic_json(Path(destination), {
        "format": "opti-temporary-worker-lease-v1", "machine_id": machine["machine_id"],
        "machine_name": machine["machine_name"], "expires_at": machine["expires_at"],
        "slot_count": len(machine["slots"]), "created_at": utc_now(),
    }, mode=0o600)


def provision() -> None:
    STATE_ROOT.mkdir(parents=True, exist_ok=True); LOG_ROOT.mkdir(parents=True, exist_ok=True)
    if JOIN.is_file():
        join = read_json(JOIN)
    elif STATE.is_file():
        existing_machine = read_json(STATE)
        embedded_handoff = existing_machine.get("handoff")
        if isinstance(embedded_handoff, dict): join = dict(embedded_handoff)
        elif HANDOFF.is_file(): join = read_json(HANDOFF)
        else: raise ControlError("temporary join handoff is missing")
    else:
        raise ControlError("temporary join bundle is missing")
    if join.get("format") != JOIN_FORMAT: raise ControlError("temporary join format is invalid")
    name = machine_name(); wait_for_tailscale(join, name)
    client = HostClient(str(join["host_url"])); health = client.health()
    if STATE.is_file():
        machine = read_json(STATE)
        if not HANDOFF.is_file() and isinstance(machine.get("handoff"), dict):
            atomic_json(HANDOFF, machine["handoff"])
    else:
        slots = max(1, min(int(os.cpu_count() or 1), MAX_SLOTS))
        machine = client.json("POST", "/v1/temporary-machine/claim", body={
            "token": str(join["claim_token"]), "machine_name": name, "slot_count": slots,
        })
        handoff = dict(join); handoff.pop("tailscale_auth_key", None); handoff.pop("claim_token", None)
        machine["handoff"] = handoff
        atomic_json(STATE, machine)
        atomic_json(HANDOFF, handoff)
        # The join file contains the only Tailscale key and one-use machine
        # claim. Destroy it immediately after both identities are durable.
        JOIN.unlink()
    credential = machine["slots"][0]
    required = str(health["build_id"])
    installed = ""
    try: installed = read_json(COMMON / "worker_manifest.json").get("build_id", "")
    except ControlError: pass
    if installed != required: install_update(client, credential, required)
    rebuild_slots(machine)
    try: DRAIN_REQUEST.unlink()
    except FileNotFoundError: pass
    # A non-secret handoff lets Windows schedule cleanup at the exact
    # host-issued deadline. Keep a minimal copy even after JOIN is destroyed.
    handoff = read_json(HANDOFF)
    write_windows_lease(handoff, machine)


def stop_slots(*, persistent: bool = True) -> None:
    if not STATE.is_file(): return
    # A user/expiration drain must survive a supervisor restart. Internal
    # maintenance (package update or crashed-slot recovery) only asks the
    # current slot processes to finish their uploads and must not permanently
    # put the whole machine into drain mode.
    if persistent:
        DRAIN_REQUEST.write_text(utc_now() + "\n", encoding="ascii")
    machine = read_json(STATE)
    for item in machine.get("slots", []):
        index = int(item["slot_index"])
        marker = STATE_ROOT / "slots" / f"slot-{index:03d}" / "stop.requested"
        marker.parent.mkdir(parents=True, exist_ok=True); marker.write_text("stop\n", encoding="ascii")


def resume_slots() -> None:
    """Clear a scheduled-window drain without changing machine identity."""
    if (STATE_ROOT / "retired").is_file():
        raise ControlError("a retired temporary worker cannot be resumed")
    try: DRAIN_REQUEST.unlink()
    except FileNotFoundError: pass
    if not STATE.is_file(): return
    machine = read_json(STATE)
    for item in machine.get("slots", []):
        index = int(item["slot_index"])
        marker = STATE_ROOT / "slots" / f"slot-{index:03d}" / "stop.requested"
        try: marker.unlink()
        except FileNotFoundError: pass


def retire() -> None:
    stop_slots()
    if STATE.is_file():
        machine = read_json(STATE); client = HostClient(str(machine["slots"][0]["host_url"]))
        try: client.health()
        except ControlError: pass
        for credential in machine.get("slots", []):
            try: client.json("POST", "/v1/retire", body={}, credential=credential, timeout=15)
            except ControlError: pass
    run(["tailscale", "logout"], timeout=30, check=False)
    (STATE_ROOT / "retired").write_text(utc_now() + "\n", encoding="ascii")


def spawn_slots(machine: Mapping[str, Any]) -> tuple[list[subprocess.Popen[bytes]], list[Any]]:
    processes: list[subprocess.Popen[bytes]] = []; logs: list[Any] = []
    cpu_count = max(1, int(os.cpu_count() or 1))
    for item in machine.get("slots", []):
        index = int(item["slot_index"]); root = SLOTS / f"slot-{index:03d}"
        marker = STATE_ROOT / "slots" / f"slot-{index:03d}" / "stop.requested"
        try: marker.unlink()
        except FileNotFoundError: pass
        log = (STATE_ROOT / "slots" / f"slot-{index:03d}" / "supervisor.log").open("ab", buffering=0)
        env = dict(os.environ)
        env.update({
            "CUDA_VISIBLE_DEVICES": "-1", "OPTI_DISABLE_AUTO_UPDATE": "1", "PYTHONUNBUFFERED": "1",
            "OMP_NUM_THREADS": "1", "MKL_NUM_THREADS": "1", "OPENBLAS_NUM_THREADS": "1",
            "NUMEXPR_NUM_THREADS": "1", "PYTHONDONTWRITEBYTECODE": "1",
        })
        cpu = (index - 1) % cpu_count
        def affinity(target: int = cpu) -> None:
            try: os.sched_setaffinity(0, {target})
            except (AttributeError, OSError): pass
        process = subprocess.Popen([
            str(RUNTIME_PYTHON), "-m", "multi_worker.worker_main", "--root", str(root), "--poll", "2",
        ], cwd=root, env=env, stdout=log, stderr=subprocess.STDOUT, preexec_fn=affinity)
        processes.append(process); logs.append(log)
    return processes, logs


def terminate_processes(processes: list[subprocess.Popen[bytes]], *, timeout: float) -> None:
    deadline = time.monotonic() + max(0.0, timeout)
    while time.monotonic() < deadline and any(process.poll() is None for process in processes):
        time.sleep(1)
    for process in processes:
        if process.poll() is None: process.send_signal(signal.SIGINT)
    time.sleep(2)
    for process in processes:
        if process.poll() is None: process.kill()
    for process in processes:
        try: process.wait(timeout=10)
        except subprocess.TimeoutExpired: pass


def run_fleet() -> None:
    if not STATE.is_file(): provision()
    machine = read_json(STATE); handoff = read_json(HANDOFF)
    client = HostClient(str(machine["slots"][0]["host_url"])); client.health()
    expires_text = str(machine.get("expires_at", "")).strip()
    expires = datetime.fromisoformat(expires_text) if expires_text else None
    drain_at = expires - timedelta(seconds=DEFAULT_DRAIN_SECONDS) if expires else None
    # A scheduled Windows shutdown leaves a durable drain marker. If systemd
    # races ahead of the Windows resume command on the next WSL boot, exit
    # cleanly and let the hidden keepalive restart us after resume clears it.
    if DRAIN_REQUEST.is_file(): return
    draining = False
    processes, logs = spawn_slots(machine)
    last_update = 0.0
    try:
        while True:
            now = datetime.now(timezone.utc)
            if ((drain_at is not None and now >= drain_at) or DRAIN_REQUEST.is_file()) and not draining:
                stop_slots(); draining = True
            if expires is not None and now >= expires:
                terminate_processes(processes, timeout=60); retire()
                expired_path = str(handoff.get("windows_expired_path", ""))
                if expired_path.startswith("/mnt/c/ProgramData/OptiTemporaryWorker/"):
                    Path(expired_path).write_text(utc_now() + "\n", encoding="ascii")
                return
            if not draining and time.monotonic() - last_update >= UPDATE_POLL_SECONDS:
                try:
                    health = client.health(); last_update = time.monotonic()
                    installed = str(read_json(COMMON / "worker_manifest.json").get("build_id", ""))
                    if str(health["build_id"]) != installed:
                        stop_slots(persistent=False); terminate_processes(processes, timeout=120)
                        for log in logs: log.close()
                        install_update(client, machine["slots"][0], str(health["build_id"]))
                        rebuild_slots(machine); processes, logs = spawn_slots(machine)
                except ControlError as exc:
                    with (LOG_ROOT / "update-errors.log").open("a", encoding="utf-8") as handle:
                        handle.write(f"{utc_now()} {exc}\n")
            if not draining:
                for index, process in enumerate(list(processes)):
                    if process.poll() is not None:
                        try: logs[index].close()
                        except OSError: pass
                        # Recreate the whole process set only at a clean
                        # assignment boundary; this prevents duplicate slots.
                        stop_slots(persistent=False); terminate_processes(processes, timeout=30)
                        for log in logs:
                            try: log.close()
                            except OSError: pass
                        rebuild_slots(machine); processes, logs = spawn_slots(machine)
                        break
            time.sleep(2)
    finally:
        for log in logs:
            try: log.close()
            except OSError: pass


def main() -> int:
    if os.geteuid() != 0: raise ControlError("Opti temporary worker control must run as root")
    action = sys.argv[1] if len(sys.argv) > 1 else "run"
    if action == "provision": provision()
    elif action == "run": run_fleet()
    elif action == "drain": stop_slots()
    elif action == "resume": resume_slots()
    elif action == "retire": retire()
    else: raise ControlError(f"unknown action: {action}")
    return 0


if __name__ == "__main__":
    try: raise SystemExit(main())
    except Exception as exc:
        LOG_ROOT.mkdir(parents=True, exist_ok=True)
        with (LOG_ROOT / "control-errors.log").open("a", encoding="utf-8") as handle:
            handle.write(f"{utc_now()} {type(exc).__name__}: {exc}\n")
        print(f"Opti temporary worker error: {exc}", file=sys.stderr)
        raise
