# Opti Temporary Windows/WSL Worker

This repository contains only the public bootstrap appliance for isolated
Opti CPU rollout workers. It never contains Opti checkpoints, policies,
training history, host secrets, Tailscale OAuth credentials, auth keys, or
worker enrollment claims.

The Opti host GUI creates a checksum-pinned one-line PowerShell command. On a
dedicated Windows PC the command:

1. saves its one-use join bundle with Windows DPAPI protection;
2. enables WSL 2 and Virtual Machine Platform when missing;
3. schedules setup to resume and restarts Windows automatically;
4. imports a uniquely named Debian WSL distribution;
5. gives WSL every detected logical CPU and the maximum safe physical RAM;
6. starts Tailscale only inside that distribution;
7. consumes the one-use host claim and creates one rollout slot per usable CPU;
8. downloads the exact current worker payload from the Opti host over Tailscale;
9. runs without a taskbar or terminal window;
10. optionally follows a daily start/shutdown window in a selected time zone;
11. optionally prevents Windows sleep only while the worker is running; and
12. at expiration, drains, retires, logs out of Tailscale, unregisters the
    distribution, and removes its own files. No-expiration workers remain until
    the operator runs the included uninstaller.

The existing bootable Opti Worker ISO is a different appliance and is not
built, modified, or configured by this repository.

## Repository setup

Create an empty **public** GitHub repository, copy this folder into it, and
push it. The public repository contains no fleet secrets. Release downloads
must remain public so a new PC can fetch the generic WSL base before it joins
Tailscale.

Create and push a version tag such as `v0.1.0`. The release workflow builds a
fresh Debian root filesystem, installs the pinned CPU-only Python runtime,
produces SHA-256 checksums, validates the PowerShell and Python sources, and
publishes these fixed asset names:

- `Install-OptiTemporaryWorker.ps1`
- `Install-OptiTemporaryWorker.ps1.sha256`
- `Remove-OptiTemporaryWorker.ps1`
- `opti-temporary-worker-rootfs.tar.gz`
- `release-manifest.json`

The host retrieves the bootstrap checksum before it creates any one-use
credential. The generated PowerShell command verifies that exact checksum
before executing the downloaded script.

## Local validation

From PowerShell:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Validate-Project.ps1
```

Building the root filesystem requires Debian or Ubuntu with root privileges:

```bash
sudo ./linux/build-rootfs.sh ./artifacts
```

## Operational rules

- Setup must be started from an Administrator PowerShell session; the script
  can relaunch itself elevated if necessary.
- A first-time WSL install intentionally restarts Windows. Setup resumes after
  the same Windows user signs back in.
- WSL receives every logical CPU and all safely usable RAM; Windows retains
  only a small survival reserve so networking and the timed uninstaller stay
  responsive. Each logical CPU appears to the Opti host as an independent
  rollout slot.
- Existing `.wslconfig` content is backed up and restored during uninstall.
- Only the distribution name recorded in the installation state may be
  unregistered.
- Completed rollout packets are uploaded and acknowledged before their local
  copies are removed.
- A daily shutdown drains current rollouts, terminates the WSL VM, and preserves
  the machine identity and cached worker state for the next scheduled start.
- The background keep-awake request changes no Windows power-plan settings and
  is released as soon as the worker stops.
- If the PC is off at expiration, the cleanup task runs at the next login.
- If setup enabled WSL for the first time, expiration may restart Windows once
  to finish restoring the optional features to their original disabled state.
- The worker is CPU-only even when the PC has an NVIDIA GPU.
