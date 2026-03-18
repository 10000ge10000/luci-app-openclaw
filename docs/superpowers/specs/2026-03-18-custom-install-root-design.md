# Custom Install Root Design

## Goal

Allow new OpenClaw installations to choose a user-specified storage root from the LuCI install dialog, use that path for pre-install disk checks, and store all runtime files under the chosen root instead of forcing `/opt`.

## Scope

- Add an install-root input to the LuCI install dialog with guidance for mounted eMMC paths such as `/mnt/emmc`.
- Persist the selected root in UCI so follow-up actions use the same location.
- Route installation, runtime startup, status checks, backup/restore, and uninstall through the configured root.
- Keep the behavior migration-free: changing the root does not move existing `/opt/openclaw` data.

## Non-Goals

- Automatic migration of an existing installation between storage roots.
- Support for relative paths or multiple active installation roots.
- Reworking historical docs that describe `/opt/openclaw` beyond the most user-facing references touched by this feature.

## Design

### Configuration model

Persist a new UCI option `openclaw.main.install_root`, defaulting to `/opt`. The value represents the parent mount path chosen by the user. Runtime directories continue to be derived in a fixed layout:

- `<install_root>/openclaw/node`
- `<install_root>/openclaw/global`
- `<install_root>/openclaw/data`

This preserves the existing internal layout while letting the outer storage location move to eMMC or other mounted storage.

### UI behavior

The install dialog will expose an "安装根目录 / 检测目录" input with inline guidance that users should enter the mounted storage path, for example `/mnt/emmc`, and that OpenClaw files will be created under `<path>/openclaw/`.

On confirm:

- The frontend sends the selected root to the system-check API.
- The frontend shows both the detection path and the actual install path in the log panel.
- The same root is sent to the setup API.

If the runtime is already installed and the requested root differs from the configured root, setup should refuse and instruct the user to uninstall first. That enforces the "new installs only" rule.

### Path resolution

Introduce a shared shell helper for runtime scripts plus a small Lua helper for controller code. Both normalize the configured install root by:

- Requiring an absolute path.
- Trimming trailing slashes except for `/`.
- Falling back to `/opt` when the value is empty or invalid.

Shell scripts consume the helper directly. Lua code uses the Lua helper so controller actions can derive paths without hard-coding `/opt/openclaw`.

### System check

The system-check API accepts an optional `install_root` parameter. It checks:

- Total physical memory against the existing 1024 MB threshold.
- Disk space on the requested root, or the nearest existing ancestor when the exact directory does not exist yet.

The API returns the normalized install root, actual OpenClaw install path, and the path used for `df`.

### Runtime changes

All runtime entry points should use the configured root:

- `openclaw-env`
- init script
- profile environment
- config TTY script
- controller actions for status, backup, restore, uninstall

The `/opt` OverlayFS workaround remains only when the configured install root is `/opt`.

## Verification

- Add lightweight tests for path normalization and derived path layout.
- Run the path tests locally.
- Run Lua syntax checks on modified Lua files.
- Run shell syntax checks on modified shell scripts.

## Risks

- Existing users can still repoint the setting without migration if they force a new install path after uninstalling. That is acceptable for this request but should be documented in UI copy.
- Backup/restore and uninstall touch many path call sites, so a missed hard-coded `/opt/openclaw` reference would cause partial regressions. Search-based verification is required before completion.
