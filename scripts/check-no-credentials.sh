#!/usr/bin/env bash
#
# 出厂预置守卫：确认 files/ 与 files-<变体>/ 的 etc/config/ 里没有节点凭据或订阅链接。
#
# 为什么需要它：
#   这个仓库是**公开的**，编出来的固件也是公开产物。任何写进覆盖层的
#   节点地址、密码、UUID、REALITY 公钥、机场订阅链接（含 service id 与密钥），
#   都会随镜像一起公开出去 —— 谁下载固件，谁就拿到了你的订阅。
#   所以把这条规矩做成机器检查：构建前扫一遍预置配置，命中就中断构建，
#   把问题挡在 CI 里，而不是等镜像发出去之后才发现。
#
# 用法（由 prepare-build.sh 调用）：
#   BUILDER_DIR=<仓库根> bash scripts/check-no-credentials.sh
# 退出码：
#   0  干净（无命中）
#   1  有命中，明细逐行打到 stdout，格式 <文件>:<行号>: <字段> = '<值>'  <- <原因>
#
# 判定口径（宁可精确也不要误报，否则会挡住正常构建）：
#   · 凭据类字段名（任何段、值非空即命中）：uuid / password / psk / 各类 REALITY 密钥 /
#     tls_sni / tls_serverName / subscription_url
#   · address —— 只在 node / nodes 段检查（其他段的 address 可能是合法的网络配置，
#     比如 network 接口 IP）
#   · url     —— 只在 subscribe / subscribe_list / subscription 段检查
#     （ruleset / global_other 等段里的 url 是远程规则集地址，属于合法内容，不碰）
#   · 特征串兜底：分享链接协议头（vless:// vmess:// ss:// ssr:// trojan:// …）
#     以及常见机场域名特征（jmssub / getsub.php）
#
set -Eeuo pipefail

BUILDER_DIR="${BUILDER_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"

# 收集所有变体的出厂预置配置（files/、files-passwall2/、files-homeproxy/ …）
CONFIGS=()
for d in "$BUILDER_DIR"/files "$BUILDER_DIR"/files-*; do
  [[ -d "$d" ]] || continue
  while IFS= read -r f; do
    CONFIGS+=("$f")
  done < <(find "$d" -type f -path '*/etc/config/*' 2>/dev/null | sort)
done

if ((${#CONFIGS[@]} == 0)); then
  echo "（没有找到 files*/etc/config/ 下的预置文件，跳过检查）"
  exit 0
fi

# uci 配置文件扫描器。
# 注意：脚本内一律用 \047 表示单引号 —— 这样 awk 代码里不需要出现单引号，
# 也就不必在 bash 里做 ''\'' 这种转义，可读性和健壮性都好得多。
scan_config() {
  awk '
    /^[ \t]*#/ { next }
    /^[ \t]*config([ \t]|$)/ {
      seg = $2
      gsub(/^[\047"]/, "", seg)
      gsub(/[\047"]$/, "", seg)
      next
    }
    /^[ \t]*(option|list)([ \t]|$)/ {
      key = $2
      v = ""
      if (match($0, /\047[^\047]*\047/))
        v = substr($0, RSTART + 1, RLENGTH - 2)
      else if (match($0, /"[^"]*"/))
        v = substr($0, RSTART + 1, RLENGTH - 2)
      else
        v = $3
      if (v == "")
        next

      reason = ""
      if (key ~ /^(uuid|password|psk|private_key|auth_key|obfs_password|subscription_url)$/)
        reason = "凭据字段 " key
      else if (key ~ /^(reality_publicKey|reality_shortId|reality_public_key|reality_short_id|tls_reality_public_key|tls_reality_short_id|tls_sni|tls_serverName)$/)
        reason = "凭据字段 " key
      else if (key == "address" && seg ~ /^(node|nodes)$/)
        reason = "节点地址"
      else if (key == "url" && seg ~ /^(subscribe|subscribe_list|subscription)$/)
        reason = "订阅链接"

      if (reason != "") {
        printf ":%d: %s = %s  <- %s\n", NR, key, "\047" v "\047", reason
        next
      }

      if (v ~ /(jmssub|getsub\.php|vless:\/\/|vmess:\/\/|ss:\/\/|ssr:\/\/|trojan:\/\/|hysteria:\/\/|hysteria2:\/\/|hy2:\/\/|tuic:\/\/|anytls:\/\/)/)
        printf ":%d: %s = %s  <- 疑似分享链接 / 订阅特征串\n", NR, key, "\047" v "\047"
    }
  ' "$1"
}

hits=0
for f in "${CONFIGS[@]}"; do
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    printf '%s%s\n' "${f#"$BUILDER_DIR"/}" "$line"
    hits=$((hits + 1))
  done < <(scan_config "$f")
done

if ((hits > 0)); then
  echo
  echo "[x] 命中 ${hits} 处：出厂预置里不能出现节点凭据或订阅链接。"
  echo "    固件是公开产物 —— 谁下载镜像，谁就等于拿到这些内容。"
  echo "    处理办法：把值清空（字段本身留着没问题），由使用者在设备上填写。"
  exit 1
fi

echo "出厂预置检查通过：${#CONFIGS[@]} 个配置文件，未发现凭据 / 订阅链接。"
