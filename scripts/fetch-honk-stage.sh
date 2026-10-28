#!/usr/bin/env bash
#
# 为 kenzok8/small 里的 honk / luci-app-honk 配方补齐**构建元数据**。
#
# ── 为什么需要这个脚本 ─────────────────────────────────────────
# small 里那两个 Makefile 是"骨架"，真正的下载地址与哈希在三个由 CI 生成、
# **不随仓库提交**的文件里（它们用 `-include` 挂进来，缺了就是全空）：
#
#   feeds/small/honk/Makefile
#       -include $(CURDIR)/generated-stage.mk      ← 资产名 + PKG_SOURCE_URL + 哈希
#       $(CURDIR)/generated-provenance.json        ← 安装段直接 INSTALL_DATA，缺了必挂
#   feeds/small/luci-app-honk/Makefile
#       -include $(CURDIR)/generated-doona-stage.mk ← doona 面板包 + 哈希
#
# 缺文件的后果不是"编出来但功能不全"，而是：
#   · generated-stage.mk 缺失 → HONK_HASH_* 取默认值 SKIP，PKG_SOURCE_URL 还停在
#     一个**已经不存在**的 `staging` 标签上（实测 404），make download 直接失败；
#   · generated-provenance.json 缺失 → 装包阶段 INSTALL_DATA 找不到源文件，
#     报错位置离真正的原因很远。
#
# 这三个文件在 kenzok8/openwrt-honk 的 `source-<run_id>` 发布里，每次 CI 出一份。
# 所以这里按「small 里写死的 CORE_COMMIT」去发布列表里找**资产名对得上**的那个
# release —— 不是简单取最新：small 的 commit 与最新 release 之间可能差一拍，
# 取错会让 HONK_ASSET 指向一个不存在的文件名。找不到就报错，不猜。
#
# ── 用法 ──────────────────────────────────────────────────────
#   bash scripts/fetch-honk-stage.sh \
#       --pkg-dir  <openwrt>/feeds/small/honk \
#       --luci-dir <openwrt>/feeds/small/luci-app-honk
#
# 可选环境变量：
#   GH_TOKEN      GitHub API token（Actions 里传 github.token，否则受 60 次/小时限制）
#   HONK_REPO     默认 kenzok8/openwrt-honk
#   HONK_ARCH     默认 aarch64（QHora-301W 是 aarch64_cortex-a53）
#   HONK_TAG      直接指定 release 标签，跳过 API 搜索（排障用）
#
set -Eeuo pipefail

REPO="${HONK_REPO:-kenzok8/openwrt-honk}"
ARCH="${HONK_ARCH:-aarch64}"
TAG="${HONK_TAG:-}"
PKG_DIR=""
LUCI_DIR=""

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

while (($#)); do
  case "$1" in
    --pkg-dir)  PKG_DIR="${2:?--pkg-dir 需要参数}";  shift 2 ;;
    --luci-dir) LUCI_DIR="${2:?--luci-dir 需要参数}"; shift 2 ;;
    --tag)      TAG="${2:?--tag 需要参数}";          shift 2 ;;
    -h|--help)  sed -n '3,40p' "$0"; exit 0 ;;
    *) die "不认识的参数：$1" ;;
  esac
done

[[ -n "$PKG_DIR"  && -f "$PKG_DIR/Makefile"   ]] || die "honk 配方目录不对：${PKG_DIR:-（未指定）}"
[[ -n "$LUCI_DIR" && -f "$LUCI_DIR/Makefile"  ]] || die "luci-app-honk 配方目录不对：${LUCI_DIR:-（未指定）}"
command -v python3 >/dev/null 2>&1 || die "需要 python3 解析 GitHub API 返回的 JSON"

# small 里写死的 honk 核心 commit。资产名里带它，所以它是**唯一**的匹配依据：
# 不看版本号（small 的 PKG_VERSION 是日期，与 release 标签无关）。
CORE_COMMIT="$(sed -n 's/^CORE_COMMIT:=//p' "$PKG_DIR/Makefile" | head -n1 | tr -d '[:space:]')"
[[ "$CORE_COMMIT" =~ ^[0-9a-f]{40}$ ]] \
  || die "从 $PKG_DIR/Makefile 读不到合法的 CORE_COMMIT（拿到 '${CORE_COMMIT:-空}'）—— 配方结构变了？"

WANT_ASSET="honk-core-${CORE_COMMIT}-${ARCH}.tar.gz"
STAGE_FILES="generated-stage.mk generated-provenance.json generated-doona-stage.mk"
log "honk 核心 commit：$CORE_COMMIT（期望资产 $WANT_ASSET）"

# ── 1. 找 release ─────────────────────────────────────────────
# 判据是「这个 release 里同时有目标架构的核心包和那三个生成文件」，
# 不是「标签是 source-*」就够了：source-* 也会按架构分别出资产。
if [[ -z "$TAG" ]]; then
  command -v curl >/dev/null 2>&1 || die "需要 curl 访问 GitHub API"
  TAG="$(python3 - "$REPO" "$WANT_ASSET" "$CORE_COMMIT" "${GH_TOKEN:-}" <<'PY'
import json, sys, urllib.request

repo, want_asset, want_commit, token = sys.argv[1:5]
need = {"generated-stage.mk", "generated-provenance.json", "generated-doona-stage.mk"}

def fetch(page):
    url = f"https://api.github.com/repos/{repo}/releases?per_page=100&page={page}"
    req = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json",
                                               "User-Agent": "qhora-build"})
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)

try:
    for page in (1, 2):
        for rel in fetch(page):
            if rel.get("draft"):
                continue
            tag = rel.get("tag_name") or ""
            if not tag.startswith("source-"):
                continue
            names = {a.get("name", "") for a in rel.get("assets", [])}
            if want_asset in names and need <= names:
                print(tag)
                raise SystemExit(0)
except Exception as e:  # noqa: BLE001 - 统一转成"找不到"，由 shell 层报错
    print(f"API_ERROR: {e}", file=sys.stderr)
    raise SystemExit(1)
raise SystemExit(1)
PY
)" || die "在 $REPO 的 release 里找不到同时含 $WANT_ASSET 与生成文件的 source-* 发布
      （small 的 CORE_COMMIT 可能刚 bump、CI 还没出包；稍后重试，或用 HONK_TAG 指定标签）"
  [[ -n "$TAG" ]] || die "在 $REPO 的 release 里找不到含 $WANT_ASSET 的 source-* 发布"
fi

BASE="https://github.com/$REPO/releases/download/$TAG"
log "honk 发布：$TAG"

# ── 2. 取三个生成文件 ─────────────────────────────────────────
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK" 2>/dev/null || true' EXIT

for f in $STAGE_FILES; do
  curl -fsSL --retry 3 --retry-delay 2 --max-time 120 -o "$WORK/$f" "$BASE/$f" \
    || die "下载 $BASE/$f 失败"
  [[ -s "$WORK/$f" ]] || die "下载到的 $f 是空文件"
done

# ── 3. 校验：宁可在这里炸，也别让 make download 在 20 分钟后炸 ──
grep -q "^HONK_ASSET_AARCH64:=$WANT_ASSET$" "$WORK/generated-stage.mk" \
  || die "generated-stage.mk 里的 AARCH64 资产名不是 $WANT_ASSET —— release 与 small 的 commit 对不上"
grep -qE '^HONK_HASH_AARCH64:=[0-9a-f]{64}$' "$WORK/generated-stage.mk" \
  || die "generated-stage.mk 里没有合法的 HONK_HASH_AARCH64（64 位 hex）"
grep -q "^PKG_SOURCE_URL:=.*/download/$TAG/\{0,1\}$" "$WORK/generated-stage.mk" \
  || die "generated-stage.mk 的 PKG_SOURCE_URL 不是指向 $TAG"

DOONA_SRC="$(sed -n 's/^PKG_SOURCE:=//p' "$WORK/generated-doona-stage.mk" | head -n1 | tr -d '[:space:]')"
[[ "$DOONA_SRC" =~ ^doona-[0-9a-f]+-[0-9a-f]+\.tar\.gz$ ]] \
  || die "generated-doona-stage.mk 里的 PKG_SOURCE 不像 doona 包：'${DOONA_SRC:-空}'"
grep -qE '^PKG_HASH:=[0-9a-f]{64}$' "$WORK/generated-doona-stage.mk" \
  || die "generated-doona-stage.mk 里没有合法的 PKG_HASH（64 位 hex）"
python3 -m json.tool "$WORK/generated-provenance.json" >/dev/null 2>&1 \
  || die "generated-provenance.json 不是合法 JSON"

# 资产真的在（HEAD 会 302 到 objects.githubusercontent.com，-L 跟过去）
for a in "$WANT_ASSET" "$DOONA_SRC"; do
  code="$(curl -s -o /dev/null -L -w '%{http_code}' -I --max-time 60 "$BASE/$a" || true)"
  [[ "$code" == "200" ]] || die "资产取不到（HTTP $code）：$BASE/$a"
  log "  资产可用：$a"
done

# ── 4. 落位 ───────────────────────────────────────────────────
rm -f "$PKG_DIR/generated-stage.mk" "$PKG_DIR/generated-provenance.json" \
      "$LUCI_DIR/generated-doona-stage.mk"
cp -f "$WORK/generated-stage.mk"        "$PKG_DIR/generated-stage.mk"
cp -f "$WORK/generated-provenance.json" "$PKG_DIR/generated-provenance.json"
cp -f "$WORK/generated-doona-stage.mk"  "$LUCI_DIR/generated-doona-stage.mk"

log "已落位：honk/generated-stage.mk、honk/generated-provenance.json、luci-app-honk/generated-doona-stage.mk"
log "  honk 核心：$CORE_COMMIT（$(sed -n 's/^HONK_HASH_AARCH64:=//p' "$WORK/generated-stage.mk")）"
log "  doona 面板：$DOONA_SRC"
# 供调用方（prepare-build.sh）把版本发成注解，不必自己再解析一遍。
printf 'HONK_STAGE_TAG=%s\nHONK_STAGE_COMMIT=%s\nHONK_STAGE_DOONA=%s\n' \
  "$TAG" "$CORE_COMMIT" "$DOONA_SRC" > "${HONK_STAGE_ENV:-/dev/null}"
