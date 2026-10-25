#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
核对一份 daed 的 wing.db 是不是"能开箱用"的出厂库。

被两处调用，保证同一套判据：
  · scripts/prepare-build.sh 的 6a-2 —— 覆盖层里的那份（构建前）
  · .github/workflows/build-*-daed.yml —— 从镜像里解包出来的那份（构建后）

查四件事：三段配置各有一条且 selected=1（而且存的是**完整块**，不是块内
正文）、proxy 组存在且策略不是 fixed、恰好一个管理员、库里没有订阅/节点链路。

    python3 scripts/check-daed-wingdb.py files/etc/daed/wing.db
"""
import re
import sqlite3
import sys


def main() -> int:
    if len(sys.argv) != 2:
        print("用法: check-daed-wingdb.py <wing.db>", file=sys.stderr)
        return 2
    path = sys.argv[1]
    try:
        con = sqlite3.connect(path)
        cur = con.cursor()
    except sqlite3.Error as e:
        print(f"[x] 打不开 {path}: {e}", file=sys.stderr)
        return 1

    errors = []

    # ① 三段配置：各一条 selected=1，且是完整块。
    #    daed 的 Create 存的是 "dns {\n" + 正文 + "\n}"，而 ParseConfig 把三段
    #    直接拼起来交给 config_parser —— 少一层大括号就解析不出 section。
    for table, col, want in (
        ("configs", "global", "global"),
        ("dns", "dns", "dns"),
        ("routings", "routing", "routing"),
    ):
        try:
            rows = cur.execute(
                f"select name,{col} from {table} where selected=1").fetchall()
        except sqlite3.Error as e:
            errors.append(f"{table} 表读不出来（{e}）—— 表名/结构不对？")
            continue
        if len(rows) != 1:
            errors.append(f"{table} 里 selected=1 的条目有 {len(rows)} 条，应该正好 1 条")
            continue
        name, body = rows[0]
        if not body.lstrip().startswith(want + " {"):
            errors.append(f"{table}.{col}（{name}）不是完整的 `{want} {{` 块，daed 会解析失败")

    # ② 组：routing 里 fallback: proxy，所以必须有 proxy；且不能是 fixed
    #    （fixed 只允许一个节点，订阅拉进来多个时 Run() 直接拒绝）。
    try:
        groups = dict(cur.execute("select name,policy from `groups`").fetchall())
    except sqlite3.Error as e:
        groups = {}
        errors.append(f"groups 表读不出来（{e}）")
    if groups:
        if "proxy" not in groups:
            errors.append("没有 proxy 组 —— routing 的 `fallback: proxy` 会报 groups not defined")
        elif groups["proxy"] == "fixed":
            errors.append("proxy 组策略是 fixed —— 订阅里多于一个节点时 daed 会拒绝运行")

    # ③ 管理员：有且只有一个（没有就进不了面板，多个说明库被灌过两次）。
    try:
        n = cur.execute("select count(*) from users").fetchone()[0]
        if n != 1:
            errors.append(f"users 表有 {n} 行，应该正好 1 个管理员")
    except sqlite3.Error as e:
        errors.append(f"users 表读不出来（{e}）")

    # ④ 安全闸：固件是公开产物，库里不许出现订阅链接 / 分享链接。
    pat = re.compile(
        r"(vless|vmess|ss|ssr|trojan|hysteria2?|tuic|anytls)://"
        r"|https?://[^\s'\"]*?(token|sub|subscribe)=",
        re.I,
    )
    for table, col in (("configs", "global"), ("dns", "dns"), ("routings", "routing")):
        try:
            rows = cur.execute(f"select {col} from {table}").fetchall()
        except sqlite3.Error:
            continue
        for (body,) in rows:
            for line in (body or "").splitlines():
                if line.lstrip().startswith("#"):
                    continue
                if pat.search(line):
                    errors.append(f"{table}.{col} 里有订阅/分享链接：{line.strip()[:90]}")
    con.close()

    if errors:
        for e in errors:
            print(f"[x] {e}", file=sys.stderr)
        return 1
    print(f"[+] {path} 核对通过：三段配置 selected + proxy 组 + 1 个管理员，无订阅/节点链接")
    return 0


if __name__ == "__main__":
    sys.exit(main())
