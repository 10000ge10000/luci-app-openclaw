#!/bin/sh
# 备份 下载 / 上传 / 恢复 契约 (#111)。
#
# 锁定的安全边界:
#   - 恢复只解压备份中的状态目录子树到当前状态目录，不再把整个 payload 解压到 /
#   - 上传归档严格校验 (仅普通文件、仅状态目录子树)
#   - 文件名白名单校验后才进入 shell，命令参数全部 shellquote
#   - 指定文件恢复失败时不静默回退到「最新备份」
#   - backup create 带 NODE_ICU_DATA，且以归档实际落盘判断成败
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
CONTROLLER="$REPO_ROOT/luasrc/controller/openclaw.lua"
BASIC="$REPO_ROOT/luasrc/model/cbi/openclaw/basic.lua"

fail() {
	echo "FAIL: $1" >&2
	exit 1
}

body=$(awk '/^function action_backup\(\)/,/^end$/' "$CONTROLLER")
[ -n "$body" ] || fail "action_backup not found"

grep -Fq 'pcall(require, "openclaw.backup")' "$CONTROLLER" || fail "controller must load openclaw.backup"
printf '%s\n' "$body" | grep -Fq 'oc_backup.validate_listing' || fail "restore/upload must validate archive structure"
printf '%s\n' "$body" | grep -Fq 'info.member' || fail "restore must extract only the validated state subtree"
if printf '%s\n' "$body" | grep -Fq -- "-C / "; then
	fail "restore must never extract backup payload into /"
fi
if printf '%s\n' "$body" | grep -Fq "payload_prefix"; then
	fail "legacy whole-payload extraction must be removed"
fi
printf '%s\n' "$body" | grep -Fq 'oc_backup.is_uploaded(restore_name)' || fail "uploaded backups must use strict validation on restore"
printf '%s\n' "$body" | grep -Fq 'validate_listing(names_text, verbose_text, true)' || fail "upload_finish must validate strictly"
printf '%s\n' "$body" | grep -Fq 'NODE_ICU_DATA=' || fail "backup CLI calls must set NODE_ICU_DATA (musl small-icu Node crashes without it)"
printf '%s\n' "$body" | grep -Fq '备份创建失败' || fail "backup create must report failure when no archive is produced"
if printf '%s\n' "$body" | grep -Fq -e '-- fallback 到最新'; then
	fail "restoring a named backup must not silently fall back to the latest backup"
fi

for act in download upload_begin upload_chunk upload_finish; do
	printf '%s\n' "$body" | grep -Fq "action == \"$act\"" || fail "action_backup must support $act"
done
printf '%s\n' "$body" | grep -Fq 'oc_backup.MAX_UPLOAD_BYTES' || fail "upload must enforce a size limit"
printf '%s\n' "$body" | grep -Fq 'offset ~= st.size' || fail "upload chunks must be strictly sequential"

# 所有拼进 shell 的路径必须 shellquote；不得再出现裸拼 backup 路径的 tar 调用
if printf '%s\n' "$body" | grep -nE '"tar [^"]*" \.\. (restore_path|filepath|part)'; then
	fail "tar invocations must shellquote file paths"
fi

# 前端入口
grep -Fq 'function ocDownloadBackup(' "$BASIC" || fail "backup dialog must offer download"
grep -Fq 'function ocUploadBackup(' "$BASIC" || fail "backup dialog must offer upload"
grep -Fq 'action=upload_chunk' "$BASIC" || fail "upload must be chunked"
grep -Fq 'd.textContent=' "$BASIC" || fail "backup messages from the server must be written with textContent"

# 打包: 新模块必须进入三条打包路径
grep -Fq 'luasrc/openclaw/backup.lua' "$REPO_ROOT/Makefile" || fail "Makefile must install openclaw/backup.lua"

echo "ok"
