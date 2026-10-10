#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 HomeProxy 的 generate_client.uc 补成 sing-box 1.13+ 兼容。

背景
----
HomeProxy 至今（immortalwrt/luci 2026-10-02）生成的 client 配置里仍写着
sing-box **1.13.0 已删除**的 inbound 字段：

    inbounds[].sniff / sniff_override_destination / set_system_proxy

sing-box 1.13+ 在 `sing-box check` 阶段直接 FATAL：

    legacy inbound fields are deprecated in sing-box 1.11.0 and removed in
    sing-box 1.13.0, checkout migration: .../migrate-legacy-inbound-fields-to-rule-actions

HomeProxy 的 init 据此 `return 1`，服务永远起不来（编得出来、刷得进去、跑不起来）。

官方迁移方案是把「在入站上嗅探」改成一条**路由规则动作**：

    { "action": "sniff" }

本脚本做两件事，且**幂等**：

  1. 删掉 inbound 里的 legacy 字段行（4 处、共 7 行）
  2. 把 generate_client.uc 里那段注释掉的占位

         /*
          * leave for sing-box 1.13.0
          * {
          *     action: 'sniff'
          * }
          */

     换成真正的规则对象 `{ action: 'sniff' }`（位置紧跟 hijack-dns 规则之后）

已在真实配置上实测（sing-box 官方 Windows 二进制 `check`）：

    · 1.14.3 + 原版      → FATAL（复现设备问题）
    · 1.14.3 + 本补丁    → OK
    · 1.12.25 + 本补丁   → OK（回归安全：`action: sniff` 自 1.11 起即可用）
    · 1.12.25 + 原版     → OK（基线）

用法
----
    python3 patch-homeproxy-for-singbox113.py <generate_client.uc 路径>

退出码 0 = 已打补丁（或本来就已经是打过补丁的状态）；非 0 = 失败。
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

# ── inbound 上的 legacy 字段（单行一条）────────────────────────────────
#   注意：只匹配**入站**里那几行。route rule 里同名的 `udp_disable_domain_unmapping`
#   是**合法**字段（1.14.3 option/rule_action.go:186），不能误删 —— 所以这里把
#   模式钉死在 HomeProxy 实际生成的那几种写法上。
LEGACY_LINE = re.compile(
    r"^[ \t]*("
    r"sniff[ \t]*:[ \t]*true[ \t]*,?"
    r"|sniff_override_destination[ \t]*:[ \t]*strToBool\(sniff_override\)[ \t]*,?"
    r"|set_system_proxy[ \t]*:[ \t]*false[ \t]*,?"
    r")[ \t]*\r?\n",          # 连同换行一起吃掉，避免留下一排空行
    re.MULTILINE,
)

# ── 默认规则块：hijack-dns + 上游注释掉的 sniff 占位 ────────────────────
DEFAULT_RULES = re.compile(
    r"(rules[ \t]*:[ \t]*\[[ \t]*\n"                 # rules: [
    r"[ \t]*\{[ \t]*\n"                              #   {
    r"[ \t]*inbound[ \t]*:[ \t]*'dns-in'[ \t]*,[ \t]*\n"
    r"[ \t]*action[ \t]*:[ \t]*'hijack-dns'[ \t]*\n"
    r"[ \t]*\}[ \t]*\n)"                             #   }   ← 要补成 },
    r"[ \t]*/\*.*?\*/[ \t]*\n"                       #   注释块（含 sniff 占位）
    r"([ \t]*\][ \t]*,)",                            # ],
    re.DOTALL,
)

SNIFF_RULE = "\t\t{\n\t\t\taction: 'sniff'\n\t\t}\n"

# `action: 'sniff'` —— 只在**非注释行**上算数。
# 上游那段注释占位里也写着 `* 	action: 'sniff'`，直接全文搜索会误判成"已打补丁"。
_SNIFF_RULE_LINE = re.compile(r"action[ \t]*:[ \t]*'sniff'")


def has_sniff_rule(text: str) -> bool:
    """是否存在**未被注释**的 `action: 'sniff'` 规则。"""
    for line in text.splitlines():
        s = line.strip()
        if not s or s.startswith(("*", "/*", "//")):
            continue
        if _SNIFF_RULE_LINE.search(s):
            return True
    return False


def patch(text: str) -> tuple[str, list[str]]:
    """返回 (补丁后的文本, 变更说明列表)。已经打过补丁则原样返回。"""
    notes: list[str] = []

    if has_sniff_rule(text) and not LEGACY_LINE.search(text):
        return text, ["already-patched"]

    def _repl(m: re.Match[str]) -> str:
        head = m.group(1)
        # 把 hijack-dns 那条规则的收尾 `}` 补上逗号（其后面要接新元素）
        head_fixed = re.sub(r"\}[ \t]*\n[ \t]*$", "},\n", head, count=1)
        notes.append("insert sniff rule")
        return head_fixed + SNIFF_RULE + m.group(2)

    text, n_rules = DEFAULT_RULES.subn(_repl, text, count=1)
    if n_rules != 1:
        raise SystemExit(
            "补丁失败：没找到 config.route 的默认 rules 块（上游可能改了结构）。\n"
            "请人工核对 generate_client.uc 里 `rules: [` ... `hijack-dns` ... `]` 那段。"
        )

    text, n_legacy = LEGACY_LINE.subn("", text)
    notes.append(f"drop {n_legacy} legacy inbound line(s)")
    if n_legacy == 0:
        raise SystemExit(
            "补丁失败：没有删掉任何 legacy inbound 字段行。\n"
            "上游可能已经自己适配了 sing-box 1.13+，或把字段挪到了别处。\n"
            "请重新评估是否还需要这个补丁。"
        )

    # ── 自检 ────────────────────────────────────────────────────────────
    left = LEGACY_LINE.findall(text)
    if left:
        raise SystemExit(f"补丁失败：仍有 legacy 字段残留 {left!r}")
    if not has_sniff_rule(text):
        raise SystemExit("补丁失败：`action: 'sniff'` 规则没插进去")

    return text, notes


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__)
        return 2

    path = Path(argv[1])
    if not path.is_file():
        print(f"::error::找不到文件：{path}", file=sys.stderr)
        return 1

    original = path.read_text(encoding="utf-8")
    patched, notes = patch(original)

    if patched == original:
        print(f"跳过（已是打过补丁的状态）：{path}")
        return 0

    # newline="\n" 必须显式给：否则 Windows 上会把 \n 翻成 \r\n，
    # 一个 ucode 脚本被改成 CRLF 虽然多半还能跑，但 diff 会整篇变红、审不动。
    path.write_text(patched, encoding="utf-8", newline="\n")
    print(f"已打补丁：{path}")
    for n in notes:
        print(f"  · {n}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
