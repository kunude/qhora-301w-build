#!/usr/bin/env bash
#
# 把 qhora-301w-build 推送到 GitHub。
#
# 用法：
#   scripts/push-to-github.sh <GitHub用户名> [提交邮箱] [仓库名]
#
# 示例：
#   scripts/push-to-github.sh octocat me@example.com qhora-301w-build
#
# 前置条件：
#   1. 已把 ~/.ssh/id_ed25519_github.pub 的内容添加到 GitHub → Settings → SSH and GPG keys
#   2. 已在 GitHub 上创建**空仓库**（不要勾选 README / .gitignore / license）
#      SSH 协议没有创建仓库的权限，这一步必须在网页上做。
#
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

die() { printf '\033[31m错误: %s\033[0m\n' "$*" >&2; exit 1; }
log() { printf '\033[36m==>\033[0m %s\n' "$*"; }

# ---------- 参数 ----------
GH_USER="${1:-}"
GH_EMAIL="${2:-}"
GH_REPO="${3:-qhora-301w-build}"

[[ -n "$GH_USER" ]] || die "缺少 GitHub 用户名。用法: $0 <GitHub用户名> [提交邮箱] [仓库名]"
[[ -n "$GH_EMAIL" ]] || GH_EMAIL="${GH_USER}@users.noreply.github.com"

# ---------- 1. 检查 SSH 密钥 ----------
KEY="$HOME/.ssh/id_ed25519_github"
[[ -f "$KEY" ]] || die "找不到 SSH 私钥 $KEY，请先执行 ssh-keygen -t ed25519 -f $KEY -N ''"

# ---------- 2. 检查 SSH 认证 ----------
log "测试到 GitHub 的 SSH 认证"
if ! SSH_MSG="$(ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -T git@github.com 2>&1)"; then
  if ! grep -q "successfully authenticated" <<<"$SSH_MSG"; then
    printf '%s\n' "$SSH_MSG" >&2
    die "SSH 认证失败。请确认已把公钥添加到 GitHub：
  $(cat "$KEY.pub")"
  fi
fi
log "SSH 认证通过"

# ---------- 3. 检查远程仓库是否已存在 ----------
REMOTE_URL="git@github.com:${GH_USER}/${GH_REPO}.git"
log "检查远程仓库 ${GH_USER}/${GH_REPO}"
if ! git ls-remote "$REMOTE_URL" >/dev/null 2>&1; then
  die "无法访问 $REMOTE_URL
  请在浏览器打开 https://github.com/new 创建**空**仓库：
    仓库名 : ${GH_REPO}
    可见性 : Public
    不要勾选 Add a README / .gitignore / license
  创建后重新运行本脚本。"
fi

# ---------- 4. 提交身份 ----------
log "配置提交身份: ${GH_USER} <${GH_EMAIL}>"
git config user.name "$GH_USER"
git config user.email "$GH_EMAIL"

# ---------- 5. 确保工作区已提交 ----------
if git rev-parse --verify HEAD >/dev/null 2>&1; then
  if [[ -n "$(git status --porcelain)" ]]; then
    log "检测到未提交的改动，追加提交"
    git add -A
    git commit -q -m "chore: 更新 QHora-301W 编译配置"
  fi
else
  [[ -n "$(git status --porcelain)" ]] || die "没有可提交的内容"
  log "创建首个提交"
  git add -A
  git commit -q -F - <<'MSG'
feat: 添加 QHora-301W (qnap_301w) 的 OpenWrt NSS EDMA 编译工作流

基于 JuliusBairaktaris/openwrt-nss-edma 的 nss-edma-rework 分支，
配合 nss-packages 的 edma-nss feed 构建 QHora-301W 固件。

- .github/workflows/build-qhora-301w.yml  GitHub Actions 主工作流
- configs/                                 target/设备/NSS 栈的 Kconfig 片段
- scripts/prepare-build.sh                 组装 .config 并校验关键符号
- files/etc/uci-defaults/                  首次启动配置

设备: qualcommax/ipq807x, qnap_301w (1GB 内存档位)
MSG
fi

# ---------- 6. 设置 remote 并推送 ----------
if git remote get-url origin >/dev/null 2>&1; then
  log "更新 origin -> $REMOTE_URL"
  git remote set-url origin "$REMOTE_URL"
else
  log "添加 origin -> $REMOTE_URL"
  git remote add origin "$REMOTE_URL"
fi

BRANCH="$(git symbolic-ref --short HEAD)"
log "推送 ${BRANCH} 到 origin"
git push -u origin "$BRANCH"

echo
log "完成！"
echo "  仓库地址: https://github.com/${GH_USER}/${GH_REPO}"
echo "  提交数  : $(git rev-list --count HEAD)"
echo
echo "下一步：打开仓库的 Actions 页面，选择 \"Build QHora-301W\" 工作流，"
echo "点击 Run workflow 开始编译。首次编译没有 ccache，耗时较长。"
