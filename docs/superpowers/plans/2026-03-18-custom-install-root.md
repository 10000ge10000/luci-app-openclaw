# Custom Install Root Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let new OpenClaw installs choose a LuCI-specified storage root and keep all runtime files under that configured root.

**Architecture:** Add a persisted UCI install-root setting, a shared shell path helper, and a small Lua path helper so UI checks and runtime scripts all derive the same directories. Keep `/opt` as the default and preserve the existing `/openclaw/{node,global,data}` subtree under whichever root the user selects.

**Tech Stack:** LuCI Lua, POSIX shell, Node.js runtime scripts, OpenWrt UCI

---

### Task 1: Add failing path derivation tests

**Files:**
- Create: `tests/test_openclaw_paths.lua`
- Create: `luasrc/openclaw/paths.lua`

- [ ] **Step 1: Write the failing test**

Create Lua assertions for:
- default root -> `/opt`
- `/mnt/emmc/` -> `/mnt/emmc`
- derived paths under `<root>/openclaw`
- invalid relative paths fall back to `/opt`

- [ ] **Step 2: Run test to verify it fails**

Run: `lua /Users/lingyuzeng/project/luci-app-openclaw/tests/test_openclaw_paths.lua`
Expected: FAIL because `luasrc/openclaw/paths.lua` does not exist yet.

- [ ] **Step 3: Write minimal implementation**

Add a pure-Lua helper exposing normalization and derived-path functions.

- [ ] **Step 4: Run test to verify it passes**

Run: `lua /Users/lingyuzeng/project/luci-app-openclaw/tests/test_openclaw_paths.lua`
Expected: PASS

### Task 2: Add shared shell path helper

**Files:**
- Create: `root/usr/libexec/openclaw-paths.sh`
- Modify: `Makefile`

- [ ] **Step 1: Write the failing test**

Extend the Lua test or add a shell smoke command that expects the helper to emit normalized install root and derived directories.

- [ ] **Step 2: Run test to verify it fails**

Run: `sh -c '. /Users/lingyuzeng/project/luci-app-openclaw/root/usr/libexec/openclaw-paths.sh; oc_load_paths'`
Expected: FAIL because the helper does not exist yet.

- [ ] **Step 3: Write minimal implementation**

Implement helper functions for normalization, derived directories, and `/opt`-specific OverlayFS handling guards. Install the helper in the package Makefile.

- [ ] **Step 4: Run test to verify it passes**

Run: `sh -n /Users/lingyuzeng/project/luci-app-openclaw/root/usr/libexec/openclaw-paths.sh`
Expected: PASS

### Task 3: Wire LuCI dialog and APIs

**Files:**
- Modify: `luasrc/model/cbi/openclaw/basic.lua`
- Modify: `luasrc/controller/openclaw.lua`
- Modify: `root/etc/config/openclaw`

- [ ] **Step 1: Add failing coverage mindset**

Use the existing Lua path test as the guardrail for normalization and manually confirm current UI/API code still hard-codes `/opt`.

- [ ] **Step 2: Implement API and dialog changes**

Add:
- UCI-backed default install root
- dialog input and explanatory copy
- `check_system` support for `install_root`
- `setup` support for persisting the root and refusing live path switches

- [ ] **Step 3: Verify behavior**

Run:
- `lua -e 'assert(loadfile("/Users/lingyuzeng/project/luci-app-openclaw/luasrc/controller/openclaw.lua"))'`
- `lua -e 'assert(loadfile("/Users/lingyuzeng/project/luci-app-openclaw/luasrc/model/cbi/openclaw/basic.lua"))'`

Expected: PASS

### Task 4: Route runtime scripts through the configured root

**Files:**
- Modify: `root/usr/bin/openclaw-env`
- Modify: `root/etc/init.d/openclaw`
- Modify: `root/etc/profile.d/openclaw.sh`
- Modify: `root/etc/uci-defaults/99-openclaw`
- Modify: `root/usr/share/openclaw/oc-config.sh`

- [ ] **Step 1: Update scripts**

Source the shared shell helper, derive paths from UCI or `OPENCLAW_INSTALL_ROOT`, and keep the `/opt` workaround only for the default root.

- [ ] **Step 2: Verify syntax**

Run:
- `sh -n /Users/lingyuzeng/project/luci-app-openclaw/root/usr/bin/openclaw-env`
- `sh -n /Users/lingyuzeng/project/luci-app-openclaw/root/etc/init.d/openclaw`
- `sh -n /Users/lingyuzeng/project/luci-app-openclaw/root/etc/profile.d/openclaw.sh`
- `sh -n /Users/lingyuzeng/project/luci-app-openclaw/root/etc/uci-defaults/99-openclaw`
- `sh -n /Users/lingyuzeng/project/luci-app-openclaw/root/usr/share/openclaw/oc-config.sh`

Expected: PASS

### Task 5: Fix remaining controller/runtime path call sites and verify

**Files:**
- Modify: `luasrc/controller/openclaw.lua`
- Modify: `luasrc/model/cbi/openclaw/basic.lua`
- Modify: `README.md`

- [ ] **Step 1: Replace remaining hard-coded `/opt/openclaw` references used by user-facing flows**

Cover status, uninstall, backup/restore, error hints, and install dialog copy.

- [ ] **Step 2: Run full verification**

Run:
- `lua /Users/lingyuzeng/project/luci-app-openclaw/tests/test_openclaw_paths.lua`
- `lua -e 'assert(loadfile("/Users/lingyuzeng/project/luci-app-openclaw/luasrc/controller/openclaw.lua"))'`
- `lua -e 'assert(loadfile("/Users/lingyuzeng/project/luci-app-openclaw/luasrc/model/cbi/openclaw/basic.lua"))'`
- `rg -n "/opt/openclaw" /Users/lingyuzeng/project/luci-app-openclaw`

Expected:
- tests and syntax checks PASS
- remaining `/opt/openclaw` hits are limited to historical docs or intentional compatibility text

- [ ] **Step 3: Commit**

```bash
git -C /Users/lingyuzeng/project/luci-app-openclaw add .
git -C /Users/lingyuzeng/project/luci-app-openclaw commit -m "feat: support configurable install root"
```
