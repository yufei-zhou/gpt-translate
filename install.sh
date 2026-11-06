#!/bin/bash
# Installs GPT Translate, or updates it to the latest release:
#   curl -fsSL https://raw.githubusercontent.com/yufei-zhou/gpt-translate/main/install.sh | bash
set -euo pipefail

REPO="yufei-zhou/gpt-translate"
APP_NAME="GPT Translate.app"
ASSET="GPT-Translate.zip"
# Every release is signed with this certificate. A download signed any other way is refused, and because the
# signature never changes, macOS keeps the Input Monitoring and Keychain permissions across updates.
REQUIREMENT='identifier "io.github.yufei-zhou.GPTTranslate" and certificate leaf = H"adad713a7d3f384ad4c87419e1900d58c1df550f"'

DIR="${INSTALL_DIR:-/Applications}"
if [ ! -w "${DIR}" ]; then
  DIR="$HOME/Applications"
  mkdir -p "${DIR}"
fi
TARGET="${DIR}/$APP_NAME"

# /releases/latest redirects to the newest release's tag.
latest_url=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest")
tag="${latest_url##*/}"
version="${tag#v}"
if [[ ! "$tag" =~ ^v[0-9] ]]; then
  echo "找不到可用的版本。" >&2
  exit 1
fi

installed=""
if [ -d "$TARGET" ]; then
  installed=$(defaults read "$TARGET/Contents/Info" CFBundleShortVersionString 2>/dev/null || true)
fi
if [ "${installed}" = "${version}" ]; then
  echo "GPT Translate 已是最新版本（${version}）。"
  exit 0
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
echo "正在下载 GPT Translate ${version}…"
curl -fsSL -o "$tmp/$ASSET" "https://github.com/$REPO/releases/download/$tag/$ASSET"
ditto -x -k "$tmp/$ASSET" "$tmp"
if ! codesign --verify --strict -R="$REQUIREMENT" "$tmp/$APP_NAME" 2>/dev/null; then
  echo "签名校验失败，已取消安装。" >&2
  exit 1
fi

pkill -x GPTTranslate 2>/dev/null && sleep 1 || true
rm -rf "$TARGET"
ditto "$tmp/$APP_NAME" "$TARGET"
# curl doesn't mark downloads as quarantined, but clear it in case anything did.
xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true

if [ -n "${installed}" ]; then
  echo "已从 ${installed} 更新到 ${version}。"
else
  echo "已安装 GPT Translate ${version} 到 ${DIR}。"
fi
if [ "${NO_LAUNCH:-}" != 1 ]; then
  open "$TARGET"
fi
