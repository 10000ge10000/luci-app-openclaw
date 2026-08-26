#!/bin/sh
# 菜单按键覆盖契约。
#
# 背景: 传统菜单是"echo 打印选项 + case 分支处理"两处独立维护，容易漂移。
# 实测发现两处功能因此完全打不开:
#   backup_restore_menu  打印 1..5，case 只有 1) 2) 3) c) d)
#     -> 选 4(查看备份列表) / 5(从最新备份恢复) 落到 *) "无效选择"，
#        真正的逻辑挂在从不显示的 c / d 上
#   reset_to_defaults    打印 1..4，case 只有 1) 2) 3) c)
#     -> 选 4(完全恢复出厂) 同样不可达
#
# 本测试对每个传统菜单函数比对"打印出来的按键集合"与"case 覆盖的按键集合"，
# 两者必须完全一致，避免再出现"按提示操作却提示无效选择"。
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
SH_CONFIG="$REPO_ROOT/root/usr/share/openclaw/oc-config.sh"

fail() {
	echo "FAIL: $1" >&2
	exit 1
}

[ -f "$SH_CONFIG" ] || fail "missing $SH_CONFIG"

# 待校验的菜单函数。这些函数都遵循 "echo -e \"  ${CYAN}N)${NC} ...\"" +
# "case \$choice in N) ... esac" 的结构。
MENUS="reset_to_defaults backup_restore_menu advanced_menu"

for fn in $MENUS; do
	grep -q "^${fn}()" "$SH_CONFIG" || fail "menu function ${fn}() not found"

	# 打印出来的按键: 形如 ${CYAN}4)${NC}
	printed=$(awk -v f="^${fn}\\\\(\\\\)" '
		$0 ~ f { inside = 1 }
		inside && /^\}$/ { inside = 0 }
		inside && match($0, /\{CYAN\}[0-9a-z]+\)/) {
			s = substr($0, RSTART + 6, RLENGTH - 7)
			print s
		}
	' "$SH_CONFIG" | sort -u | tr '\n' ' ')

	# case 覆盖的按键。
	# 注意各菜单的外层 case 缩进不同 (advanced_menu 的 case 嵌在 while 里，
	# 比另外两个深一层)，且分支内可能有嵌套 case (如 auto|lan|... / true|false)。
	# 因此先定位该函数第一个 "case ... in" 的缩进，只采集与之相同缩进 + 1 个
	# 制表符的标签行，避免把嵌套 case 的取值误判成菜单按键。
	handled=$(awk -v f="$fn" '
		index($0, f "()") == 1 { inside = 1 }
		inside && /^\}$/ { inside = 0 }
		inside && !depth_found && match($0, /^\t*case .* in$/) {
			# 记录外层 case 的制表符数量
			ct = 0
			while (substr($0, ct + 1, 1) == "\t") ct++
			label_prefix = ""
			for (i = 0; i <= ct; i++) label_prefix = label_prefix "\t"
			depth_found = 1
			next
		}
		inside && depth_found {
			# 只接受恰好位于外层 case 分支缩进的标签行
			if (index($0, label_prefix) == 1 && substr($0, length(label_prefix) + 1, 1) != "\t") {
				line = substr($0, length(label_prefix) + 1)
				if (match(line, /^[0-9a-z][0-9a-z|"]*\)/)) {
					sub(/\).*$/, "", line)
					n = split(line, parts, "|")
					for (i = 1; i <= n; i++) {
						gsub(/"/, "", parts[i])
						if (parts[i] != "") print parts[i]
					}
				}
			}
		}
	' "$SH_CONFIG" | sort -u | tr '\n' ' ')

	[ -n "$printed" ] || fail "${fn}: no printed menu keys detected (parser drift?)"
	[ -n "$handled" ] || fail "${fn}: no case labels detected (parser drift?)"

	# 打印了但没有分支处理 -> 用户按提示操作会得到"无效选择"
	for k in $printed; do
		case " $handled " in
			*" $k "*) ;;
			*) fail "${fn}: menu offers '$k' but no case branch handles it (option is unreachable)" ;;
		esac
	done

	# 有分支但从不显示 -> 隐藏功能，说明键位错位
	for k in $handled; do
		case " $printed " in
			*" $k "*) ;;
			*) fail "${fn}: case handles '$k' but the menu never offers it (orphaned branch)" ;;
		esac
	done
done

# 回归钉子: 这两个功能曾经挂在不显示的 c/d 上。
#
# 注意不要在 grep 模式里写 \t: BusyBox grep 会把它当制表符，
# 而 GNU grep (CI runner) 当作字面字符 t —— 同一个断言在两边结果相反。
# 这里用 awk 判断行首制表符，避免依赖 grep 的转义方言。
has_case_label() {
	awk -v fn="$1" -v key="$2" '
		index($0, fn "()") == 1 { inside = 1 }
		inside && /^\}$/ { inside = 0 }
		inside && $0 == "\t\t" key ")" { found = 1 }
		END { exit(found ? 0 : 1) }
	' "$SH_CONFIG"
}

has_case_label backup_restore_menu 4 \
	|| fail "backup menu option 4 (list backups) must be reachable"
has_case_label backup_restore_menu 5 \
	|| fail "backup menu option 5 (restore from latest) must be reachable"
has_case_label reset_to_defaults 4 \
	|| fail "reset menu option 4 (factory reset) must be reachable"

echo "ok"
