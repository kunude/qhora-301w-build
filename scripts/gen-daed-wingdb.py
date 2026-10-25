#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
把 configs/daed/*.dae 编译成 daed 的**出厂数据库** /etc/daed/wing.db。

为什么是这个做法
================
daed 2.x 没有配置文件：global / dns / routing / 分组全部存在
`<config-dir>/wing.db`（SQLite，db/db.go 里写死的文件名）。所以"开箱即用的
默认配置"只能是**这个 .db 文件本身**，刷完机 daed 一起来就读到，面板里
三段配置、代理组、选中状态都是现成的 —— 不需要在设备上跑任何脚本去"灌"。

表结构从 dae-wing 的 gorm model 反推（db/*.go），列类型按 gorm 的 sqlite
映射（uint→integer / string→text / bool→numeric）。这里**只建有初始数据的
五张表**，其余（nodes / subscriptions / group_nodes / systems …）留给 daed
启动时的 AutoMigrate 自己建 —— 少写一张就少一处结构不匹配的机会。

`systems.running` 故意不预置成 true：Run() 要求每个被 routing 引用的组
至少有一个节点（mutation_utils.go: `please add at least one node into
group`），出厂时还没有订阅、没有节点，强行 running=1 只会在开机日志里留
一条失败记录。填完订阅后再点"启动"。

用法
====
    python3 scripts/gen-daed-wingdb.py --out files-daed/etc/daed/wing.db

    # 换管理员账号（默认 admin / 见 --admin-pass 的默认值）
    DAED_ADMIN_PASS='xxxxxx' python3 scripts/gen-daed-wingdb.py --out ...

产物权限会被调成 0600：wing.db 里有管理员口令哈希和（可能是机密的）配置正文。
"""

from __future__ import annotations

import argparse
import hashlib
import os
import secrets
import sqlite3
import sys
import tempfile

# ── 默认值 ──────────────────────────────────────────────────────────────
# 管理员账号。口令走环境变量 DAED_ADMIN_PASS，缺省这个值只是为了"刷完能直接
# 登录进面板"。仓库是公开的 ⇒ 这个默认口令等于公开的，**首次登录后请改掉**。
DEFAULT_ADMIN_USER = "admin"
DEFAULT_ADMIN_PASS = "784512a."

# 三段配置在 daed 里各自的"缺省条目名"。daed 首次启动自动建的就是这三个名字
# （configs: global / dns: default / routings: default），这里沿用，免得面板里
# 多出一条叫别的名字的配置。
CONFIG_NAME = "global"
DNS_NAME = "default"
ROUTING_NAME = "default"

# 唯一的代理组：订阅里的节点全丢进来，min_moving_avg 自动挑最快的。
GROUP_NAME = "proxy"
GROUP_POLICY = "min_moving_avg"
GROUP_VERSION = 1

# ── 表结构：daed 2.1.1 实机 dump 出来的权威 DDL ─────────────────────────
# 别照着自己的理解改。下面每一句都是拿 `daed run --api-only` 在空目录里跑
# 一遍、再把 sqlite_master 里的建表语句原样抄下来的（glebarez/sqlite 驱动）。
#
# 两个坑，踩过一次：
#   ① 表名是 `dns`，不是 `dnss`（gorm 的复数化认为 dns 不可数）；
#   ② 主键是 `id integer` + 表级 `PRIMARY KEY (id)`，**没有 AUTOINCREMENT**。
#      自己写成 `integer PRIMARY KEY AUTOINCREMENT` 时列定义与 gorm 的期望
#      不一致，启动时 AutoMigrate 会走 AlterColumn 重建表，而 glebarez/sqlite
#      在"列名与表名同名"（dns.dns）时重建语句会拼错，直接：
#          SQL logic error: no such column: dns__temp
#      → Failed to init db → daed 起不来。
# 全量建 10 张表（含空表）也是为了让 AutoMigrate 一个字段都不用动。
DDL = [
    """CREATE TABLE `users` (`id` integer,`username` text NOT NULL UNIQUE,
        `password_hash` text NOT NULL,`jwt_secret` text NOT NULL,
        `json_storage` text NOT NULL DEFAULT "{}",`avatar` text,`name` text,
        PRIMARY KEY (`id`))""",
    """CREATE TABLE `configs` (`id` integer,`name` text NOT NULL DEFAULT "",
        `global` text NOT NULL,`selected` numeric NOT NULL,
        `version` integer NOT NULL DEFAULT 0,PRIMARY KEY (`id`))""",
    """CREATE TABLE `dns` (`id` integer,`name` text NOT NULL DEFAULT "",
        `dns` text NOT NULL,`selected` numeric NOT NULL,
        `version` integer NOT NULL DEFAULT 0,PRIMARY KEY (`id`))""",
    """CREATE TABLE `routings` (`id` integer,`name` text NOT NULL DEFAULT "",
        `routing` text NOT NULL,`selected` numeric NOT NULL,
        `version` integer NOT NULL DEFAULT 0,PRIMARY KEY (`id`))""",
    """CREATE TABLE `groups` (`id` integer,`name` text NOT NULL UNIQUE,
        `policy` text NOT NULL,`version` integer NOT NULL DEFAULT 0,
        `system_id` integer,PRIMARY KEY (`id`),
        CONSTRAINT `fk_systems_running_groups` FOREIGN KEY (`system_id`)
            REFERENCES `systems`(`id`))""",
    """CREATE TABLE `systems` (`id` integer,
        `running` numeric NOT NULL DEFAULT false,
        `running_config_version` integer NOT NULL DEFAULT 0,
        `running_dns_version` integer NOT NULL DEFAULT 0,
        `running_routing_version` integer NOT NULL DEFAULT 0,
        `running_group_version_sum` integer NOT NULL DEFAULT 0,
        `running_group_ids` text NOT NULL DEFAULT "",
        `running_config_id` integer,`running_dns_id` integer,
        `running_routing_id` integer,PRIMARY KEY (`id`),
        CONSTRAINT `fk_systems_running_config` FOREIGN KEY (`running_config_id`)
            REFERENCES `configs`(`id`),
        CONSTRAINT `fk_systems_running_dns` FOREIGN KEY (`running_dns_id`)
            REFERENCES `dns`(`id`),
        CONSTRAINT `fk_systems_running_routing` FOREIGN KEY (`running_routing_id`)
            REFERENCES `routings`(`id`))""",
    """CREATE TABLE `subscriptions` (`id` integer,`updated_at` datetime NOT NULL,
        `link` text NOT NULL,`cron_exp` text DEFAULT "10 */6 * * *",
        `cron_enable` numeric DEFAULT true,`status` text NOT NULL,
        `info` text NOT NULL,`tag` text UNIQUE,PRIMARY KEY (`id`))""",
    """CREATE TABLE `nodes` (`id` integer,`link` text NOT NULL,`name` text NOT NULL,
        `address` text NOT NULL,`protocol` text NOT NULL,`tag` text UNIQUE,
        `subscription_id` integer,PRIMARY KEY (`id`),
        CONSTRAINT `fk_subscriptions_node` FOREIGN KEY (`subscription_id`)
            REFERENCES `subscriptions`(`id`))""",
    """CREATE TABLE `group_nodes` (`group_id` integer,`node_id` integer,
        PRIMARY KEY (`group_id`,`node_id`),
        CONSTRAINT `fk_group_nodes_node` FOREIGN KEY (`node_id`)
            REFERENCES `nodes`(`id`),
        CONSTRAINT `fk_group_nodes_group` FOREIGN KEY (`group_id`)
            REFERENCES `groups`(`id`))""",
    """CREATE TABLE `group_subscriptions` (`group_id` integer,
        `subscription_id` integer,`name_filter_regex` text,
        PRIMARY KEY (`group_id`,`subscription_id`),
        CONSTRAINT `fk_group_subscriptions_subscription`
            FOREIGN KEY (`subscription_id`) REFERENCES `subscriptions`(`id`),
        CONSTRAINT `fk_groups_subscription_bindings` FOREIGN KEY (`group_id`)
            REFERENCES `groups`(`id`))""",
    """CREATE TABLE `group_policy_params` (`id` integer,`key` text NOT NULL,
        `value` text NOT NULL,`group_id` integer,PRIMARY KEY (`id`),
        CONSTRAINT `fk_groups_policy_params` FOREIGN KEY (`group_id`)
            REFERENCES `groups`(`id`))""",
    "CREATE INDEX `idx_groups_name` ON `groups`(`name`)",
    "CREATE INDEX `idx_users_username` ON `users`(`username`)",
]

SECTIONS = ("global", "dns", "routing")


def die(msg: str) -> None:
    print(f"[x] {msg}", file=sys.stderr)
    sys.exit(1)


def read_section(src_dir: str, name: str) -> str:
    """读 configs/daed/<name>.dae，并校验它是一段**完整**的 dae 块。

    daed 存的就是完整块（dns 的 Create 里是 `"dns {\\n" + 正文 + "\\n}"`），
    而 ParseConfig 是把三段直接拼起来交给 config_parser 的 —— 少一层大括号
    就解析不出 section，daed 启动即报错。所以这里必须卡死。
    """
    path = os.path.join(src_dir, f"{name}.dae")
    if not os.path.isfile(path):
        die(f"缺少 {path}")
    with open(path, encoding="utf-8") as fp:
        text = fp.read()
    # 统一成 \n，去掉末尾多余空白（daed 自己拼接时也会 \n 收尾）
    text = text.replace("\r\n", "\n").replace("\r", "\n").strip("\n")

    lines = [ln for ln in text.splitlines() if ln.strip()]
    if not lines or lines[0].strip() != f"{name} {{":
        die(f"{path} 的第一行必须是 `{name} {{`（daed 存完整块，不是块内正文）")
    if lines[-1].strip() != "}":
        die(f"{path} 的最后一行必须是 `}}`")
    return text


def hash_password(jwt_secret: str, password: str) -> str:
    """复刻 graphql/query.go 的 hashPassword：

        h := sha3.NewShake256(); h.Write(salt); h.Write(password)
        hex.EncodeToString(hash[:32])
    """
    h = hashlib.shake_256()
    h.update(jwt_secret.encode("utf-8"))
    h.update(password.encode("utf-8"))
    return h.digest(32).hex()


def build(db_path: str, src_dir: str, user: str, password: str) -> dict:
    sections = {name: read_section(src_dir, name) for name in SECTIONS}
    jwt_secret = secrets.token_hex(32)          # 与 daed 一致：32 字节 → 64 hex
    pw_hash = hash_password(jwt_secret, password)

    os.makedirs(os.path.dirname(os.path.abspath(db_path)) or ".", exist_ok=True)
    # 先写临时文件再 rename：构建脚本可能被重复调用，别留下半个 db。
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(os.path.abspath(db_path)) or ".",
                               prefix=".wing-", suffix=".db")
    os.close(fd)
    try:
        con = sqlite3.connect(tmp)
        try:
            cur = con.cursor()
            for stmt in DDL:
                cur.execute(stmt)
            cur.execute(
                "INSERT INTO `users` (`id`,`username`,`password_hash`,`jwt_secret`,"
                "`json_storage`,`avatar`,`name`) VALUES (1,?,?,?,'{}',NULL,NULL)",
                (user, pw_hash, jwt_secret),
            )
            # 三段配置：id=1 且 selected=1。daed 的 Run() 只认 selected=1 的那条。
            cur.execute(
                "INSERT INTO `configs` (`id`,`name`,`global`,`selected`,`version`)"
                " VALUES (1,?,?,1,1)",
                (CONFIG_NAME, sections["global"]),
            )
            cur.execute(
                "INSERT INTO `dns` (`id`,`name`,`dns`,`selected`,`version`)"
                " VALUES (1,?,?,1,1)",
                (DNS_NAME, sections["dns"]),
            )
            cur.execute(
                "INSERT INTO `routings` (`id`,`name`,`routing`,`selected`,`version`)"
                " VALUES (1,?,?,1,1)",
                (ROUTING_NAME, sections["routing"]),
            )
            # 唯一的代理组。policy 无参数，group_policy_params 保持空表。
            cur.execute(
                "INSERT INTO `groups` (`id`,`name`,`policy`,`version`,`system_id`)"
                " VALUES (1,?,?,?,NULL)",
                (GROUP_NAME, GROUP_POLICY, GROUP_VERSION),
            )
            con.commit()
            cur.execute("VACUUM")
        finally:
            con.close()
        os.replace(tmp, db_path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise

    try:
        os.chmod(db_path, 0o600)
    except OSError:
        pass

    return {
        "path": db_path,
        "user": user,
        "sections": {k: len(v.splitlines()) for k, v in sections.items()},
        "group": GROUP_NAME,
        "policy": GROUP_POLICY,
    }


def main() -> int:
    here = os.path.dirname(os.path.abspath(__file__))
    repo = os.path.dirname(here)

    ap = argparse.ArgumentParser(description="生成 daed 出厂 wing.db")
    ap.add_argument("--out", default=os.path.join(repo, "files-daed/etc/daed/wing.db"),
                    help="输出的 wing.db 路径（默认 files-daed/etc/daed/wing.db）")
    ap.add_argument("--src", default=os.path.join(repo, "configs/daed"),
                    help="三段 .dae 所在目录（默认 configs/daed）")
    ap.add_argument("--admin-user", default=os.environ.get("DAED_ADMIN_USER", DEFAULT_ADMIN_USER))
    ap.add_argument("--admin-pass", default=os.environ.get("DAED_ADMIN_PASS", DEFAULT_ADMIN_PASS))
    args = ap.parse_args()

    if len(args.admin_pass) < 6:
        die("管理员口令至少 6 位（daed 自己的 CreateUser 也是这个下限）")

    info = build(os.path.abspath(args.out), os.path.abspath(args.src),
                 args.admin_user, args.admin_pass)

    print(f"[+] wing.db 已生成：{info['path']}")
    print(f"    管理员      {info['user']} / {'*' * len(args.admin_pass)}（首次登录后请改）")
    print(f"    配置        {CONFIG_NAME}（selected）、dns {DNS_NAME}、routing {ROUTING_NAME}")
    print(f"    行数        " + ", ".join(f"{k}={v}" for k, v in info["sections"].items()))
    print(f"    代理组      {GROUP_NAME} / {GROUP_POLICY}")
    print("    运行状态    running=0（填完订阅、把订阅加进 proxy 组后，在面板点启动）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
