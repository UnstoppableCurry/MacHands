#!/usr/bin/env bash
# release.sh — 做一个能直接发给别人的 MacHands.dmg。
#
#   1. build-app.sh --sign "Developer ID Application: …"   真签名 + hardened runtime
#   2. hdiutil                                            打成 DMG
#   3. xcrun notarytool submit --wait                     交给苹果公证
#   4. xcrun stapler staple                               把票据钉在 .app 与 .dmg 上
#   5. spctl                                              问一句「Gatekeeper 到底放不放行」
#
# 用法:
#   ./scripts/release.sh --sign "Developer ID Application: 你的名字 (TEAMID)" \
#                        --keychain-profile machands-notary [--version 0.1.0]
#
# 那个 keychain profile 只要建一次(密码不会出现在命令行上):
#   xcrun notarytool store-credentials machands-notary \
#     --apple-id you@example.com --team-id TEAMID
#
# 这个脚本**从不**接受 Apple ID 密码或 app-specific password 作为参数或环境变量:
# argv 通过 `ps` 全机器可见。
#
# 退出码:0 成功 · 1 构建失败 · 2 参数用法错 · 3 平台不对 · 4 签名失败 · 5 公证失败
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
APP_DIR=$(dirname "$HERE")
APP_NAME="MacHands"
OUT_DIR="$APP_DIR/dist"
SIGN_ID=""
KEYCHAIN_PROFILE=""
VERSION=""
SKIP_NOTARIZE=0

if [ -t 1 ]; then
  R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; D=$'\033[2m'; B=$'\033[1m'; Z=$'\033[0m'
else
  R=""; G=""; Y=""; D=""; B=""; Z=""
fi
step() { printf '\n%s==>%s %s\n' "$B" "$Z" "$*"; }
info() { printf '    %s%s%s\n' "$D" "$*" "$Z"; }
warn() { printf '%s!  %s%s\n' "$Y" "$*" "$Z" >&2; }
ok()   { printf '%s✓%s  %s\n' "$G" "$Z" "$*"; }
die()  {
  local code="$1"; shift
  printf '%s✗  %s%s\n' "$R" "$1" "$Z" >&2
  if [ "$#" -gt 1 ]; then printf '%s   → %s%s\n' "$D" "$2" "$Z" >&2; fi
  exit "$code"
}

usage() {
  cat <<EOF
用法: ./scripts/release.sh --sign "Developer ID Application: 名字 (TEAMID)" \\
                           --keychain-profile NAME [选项]

  --sign IDENTITY            Developer ID Application 证书(必填)
  --keychain-profile NAME    notarytool 的 keychain profile(必填,除非 --skip-notarize)
  --version X.Y.Z            marketing 版本(默认:VERSION 文件,否则 0.1.0)
  --out DIR                  产物目录(默认:$OUT_DIR)
  --skip-notarize            只签名 + 打 DMG,不交公证(内部测试用)
  -h, --help
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --sign)              [ "${2:-}" ] || die 2 "--sign 要一个证书名"; SIGN_ID="$2"; shift 2 ;;
    --keychain-profile)  [ "${2:-}" ] || die 2 "--keychain-profile 要一个名字"; KEYCHAIN_PROFILE="$2"; shift 2 ;;
    --version)           [ "${2:-}" ] || die 2 "--version 要一个值"; VERSION="$2"; shift 2 ;;
    --out)               [ "${2:-}" ] || die 2 "--out 要一个目录"; OUT_DIR="$2"; shift 2 ;;
    --skip-notarize)     SKIP_NOTARIZE=1; shift ;;
    -h|--help)           usage; exit 0 ;;
    *)                   die 2 "不认识的选项:$1" "./scripts/release.sh --help" ;;
  esac
done

# --------------------------------------------------------------------------- #
step "检查前提"

[ "$(uname -s)" = "Darwin" ] || die 3 "发布流程只能在 Mac 上跑。" "把仓库拷到 Mac 上再来"

if [ -z "$SIGN_ID" ]; then
  die 2 "缺 --sign。发给别人的包必须用 Developer ID 证书签。" \
        '看看你有哪些:security find-identity -v -p codesigning'
fi
case "$SIGN_ID" in
  "Developer ID Application:"*) : ;;
  *) warn "「$SIGN_ID」看起来不像 Developer ID Application 证书;公证很可能会被拒。" ;;
esac
if [ "$SKIP_NOTARIZE" = 0 ] && [ -z "$KEYCHAIN_PROFILE" ]; then
  die 2 "缺 --keychain-profile。" \
        "先建一次:xcrun notarytool store-credentials NAME --apple-id you@example.com --team-id TEAMID"
fi
command -v xcrun >/dev/null 2>&1 || die 5 "没有 xcrun。" "装 Xcode 命令行工具:xcode-select --install"
command -v hdiutil >/dev/null 2>&1 || die 1 "没有 hdiutil(这真的是 macOS 吗?)"

if ! security find-identity -v -p codesigning 2>/dev/null | grep -qF "$SIGN_ID"; then
  die 4 "钥匙串里找不到「$SIGN_ID」这个证书。" \
        "security find-identity -v -p codesigning 会列出所有可用的;名字要一字不差"
fi
ok "证书在,工具齐"

# --------------------------------------------------------------------------- #
step "构建并签名(universal)"

BUILD_ARGS=(--sign "$SIGN_ID" --universal --out "$OUT_DIR")
if [ -n "$VERSION" ]; then BUILD_ARGS+=(--version "$VERSION"); fi
"$HERE/build-app.sh" "${BUILD_ARGS[@]}" || die 4 "build-app.sh 没能出一个签好名的 .app。" \
    "先单独跑一次 ./scripts/build-app.sh 看是构建的问题还是签名的问题"

APP_BUNDLE="$OUT_DIR/$APP_NAME.app"
[ -d "$APP_BUNDLE" ] || die 1 "$APP_BUNDLE 不见了"

if [ -z "$VERSION" ]; then
  VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
            "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || echo "0.1.0")
fi
info "版本 $VERSION"

codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE" 2>&1 | sed 's/^/    /' \
  || die 4 "签名自检没过。" "codesign --verify --deep --strict -vvv '$APP_BUNDLE' 看详细原因"
if ! codesign -d --entitlements - "$APP_BUNDLE" 2>/dev/null | grep -q "apple-events"; then
  warn "签进去的 entitlements 里没有 apple-events —— agent 让 Mac 跑 osascript 会失败"
fi
ok "签名有效"

# --------------------------------------------------------------------------- #
step "打 DMG"

DMG="$OUT_DIR/$APP_NAME-$VERSION.dmg"
DSTAGE=$(mktemp -d "${TMPDIR:-/tmp}/machands-dmg.XXXXXX")
trap 'rm -rf "$DSTAGE"' EXIT
cp -R "$APP_BUNDLE" "$DSTAGE/"
ln -s /Applications "$DSTAGE/Applications"      # 拖进去就装的那个窗口
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$DSTAGE" -ov -format UDZO -quiet "$DMG" \
  || die 1 "hdiutil 失败。" "可能有一个旧的卷还挂着:hdiutil detach /Volumes/$APP_NAME"
ok "$DMG"

# --------------------------------------------------------------------------- #
if [ "$SKIP_NOTARIZE" = 1 ]; then
  warn "按要求跳过了公证。这个 DMG 在别人的 Mac 上会被 Gatekeeper 拦住。"
  printf '\n%s完成(未公证):%s %s\n' "$B" "$Z" "$DMG"
  exit 0
fi

step "提交公证(profile: $KEYCHAIN_PROFILE)"
info "苹果那边一般几分钟。--wait 会一直等到有结果。"

ZIP="$DSTAGE/$APP_NAME-$VERSION.zip"
# 必须用 ditto:`zip -r` 会毁掉 bundle 里的符号链接与扩展属性,
# 然后公证给出的错误信息会把人带偏一小时。
ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP" || die 5 "打不出提交用的 zip"

if ! xcrun notarytool submit "$ZIP" --keychain-profile "$KEYCHAIN_PROFILE" --wait; then
  die 5 "苹果拒绝了这个 .app。" \
        "看完整报告:xcrun notarytool log <submission-id> --keychain-profile $KEYCHAIN_PROFILE"
fi
ok ".app 通过公证"

step "钉票据(.app)"
xcrun stapler staple "$APP_BUNDLE" \
  || die 5 "票据钉不上 .app。" "票据可能还没发布,等一分钟再跑:xcrun stapler staple '$APP_BUNDLE'"

# .app 重新钉过票据,DMG 里的那份就旧了 —— 重新打一次。
step "用钉好票据的 .app 重打 DMG"
rm -rf "$DSTAGE/$APP_NAME.app"
cp -R "$APP_BUNDLE" "$DSTAGE/"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$DSTAGE" -ov -format UDZO -quiet "$DMG" \
  || die 1 "重打 DMG 失败"

step "提交公证(DMG)"
# 里面的 .app 钉过票据,不代表 DMG 本身也钉了;第一次打开时如果那台 Mac 离线,
# 没钉票据的 DMG 还是会被拦。
if ! xcrun notarytool submit "$DMG" --keychain-profile "$KEYCHAIN_PROFILE" --wait; then
  die 5 "苹果拒绝了这个 DMG。" \
        "看完整报告:xcrun notarytool log <submission-id> --keychain-profile $KEYCHAIN_PROFILE"
fi
xcrun stapler staple "$DMG" \
  || die 5 "票据钉不上 DMG。" "等一分钟再跑:xcrun stapler staple '$DMG'"
ok "DMG 已公证并钉好票据"

# --------------------------------------------------------------------------- #
step "最后一问:Gatekeeper 放行吗"
if spctl -a -vvv -t install "$APP_BUNDLE" 2>&1 | sed 's/^/    /'; then
  ok "spctl 说可以"
else
  warn "spctl 不高兴 —— 别人的 Mac 上还是会被拦。看上面几行。"
fi

printf '\n%s可以发布了:%s\n' "$B" "$Z"
printf '  %s\n' "$DMG"
if command -v shasum >/dev/null 2>&1; then
  printf '  SHA256: %s\n' "$(shasum -a 256 "$DMG" | awk '{print $1}')"
fi
printf '  别人双击就能打开,不用右键 → 打开。\n'
