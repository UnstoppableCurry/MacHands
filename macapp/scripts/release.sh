#!/usr/bin/env bash
# release.sh — 一条命令做完一次官网发布。
#
#   1. 预检          证书、公证凭据、发布私钥、版本号、工作区干净
#   2. build-app.sh  Developer ID 签名 + 强化运行时 + 可信时间戳(universal)
#   3. ditto         打成 MacHands-<版本>.zip
#   4. notarytool    交公证 → stapler 把票据钉进 .app → 用钉好的 .app 重打 zip
#   5. spctl         必须 accepted,否则这里就停
#   6. make-appcast  算 sha256 + 用发布私钥签名 → appcast.json
#
# 为什么必须是 Developer ID(而不是 Apple Distribution / 3rd Party Mac Developer):
#   TCC(屏幕录制、辅助功能)按代码签名的"指定要求"认 App。
#   Developer ID 的指定要求只写死 team id + bundle id,跨版本不变 —— 升级后授权还在。
#   开发证书或未公证的包,每换一次二进制用户就要重新勾一遍权限。
#   详见 docs/RELEASE.md。
#
# 用法:
#   ./scripts/release.sh --sign "Developer ID Application: 你的名字 (TEAMID)" \
#                        --keychain-profile machands-notary \
#                        [--version 0.3.0] [--host https://machands.app] \
#                        [--notes-zh "…"] [--notes-en "…"] [--allow-dirty]
#
# 那个 keychain profile 只要建一次(密码不会出现在命令行上):
#   xcrun notarytool store-credentials machands-notary \
#     --apple-id you@example.com --team-id TEAMID --password <App 专用密码>
#
# 这个脚本**从不**接受 Apple ID 密码作为参数或环境变量:argv 通过 `ps` 全机器可见。
#
# 退出码:0 成功 · 1 构建/打包失败 · 2 参数用法错 · 3 平台不对 · 4 签名失败
#         5 公证失败 · 6 Gatekeeper 不放行 · 7 appcast 失败 · 8 bundle id 不对
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
APP_DIR=$(dirname "$HERE")
REPO_DIR=$(dirname "$APP_DIR")
APP_NAME="MacHands"
# 正式发布包的 bundle id 只能是这一个,不可配置。
# 起因:mini 上一度同时存在 5 份同 bundle id 的拷贝,一份旧版抢走了中继身份,
# 别的 agent 收到 "unknown method",系统权限面板出现同名条目,用户以为权限没生效。
# 开发副本请用 app.machands.MacHands.dev(build-app.sh --bundle-id),别走这个脚本。
EXPECT_BUNDLE_ID="app.machands.MacHands"
OUT_DIR="$APP_DIR/dist"
SIGN_ID=""
KEYCHAIN_PROFILE=""
VERSION=""
BUILD_NUM=""
HOST="https://machands.app"
NOTES_ZH=""
NOTES_EN=""
ALLOW_DIRTY=0
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
  --version X.Y.Z            marketing 版本(默认:macapp/VERSION)
  --build N                  CFBundleVersion(默认:git 提交数)
  --host URL                 官网地址,拼下载链接用(默认:$HOST)
  --notes-zh "…"             这一版的中文更新说明(进 appcast,App 里给用户看)
  --notes-en "…"             英文更新说明
  --out DIR                  产物目录(默认:$OUT_DIR)
  --allow-dirty              工作区有未提交改动也继续(默认拒绝)
  --skip-notarize            只签名打包,不公证(内部测试;产出的包别人打不开)
  -h, --help
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --sign)              [ "${2:-}" ] || die 2 "--sign 要一个证书名"; SIGN_ID="$2"; shift 2 ;;
    --keychain-profile)  [ "${2:-}" ] || die 2 "--keychain-profile 要一个名字"; KEYCHAIN_PROFILE="$2"; shift 2 ;;
    --version)           [ "${2:-}" ] || die 2 "--version 要一个值"; VERSION="$2"; shift 2 ;;
    --build)             [ "${2:-}" ] || die 2 "--build 要一个数字"; BUILD_NUM="$2"; shift 2 ;;
    --host)              [ "${2:-}" ] || die 2 "--host 要一个地址"; HOST="$2"; shift 2 ;;
    --notes-zh)          [ "${2:-}" ] || die 2 "--notes-zh 要一段文字"; NOTES_ZH="$2"; shift 2 ;;
    --notes-en)          [ "${2:-}" ] || die 2 "--notes-en 要一段文字"; NOTES_EN="$2"; shift 2 ;;
    --out)               [ "${2:-}" ] || die 2 "--out 要一个目录"; OUT_DIR="$2"; shift 2 ;;
    --allow-dirty)       ALLOW_DIRTY=1; shift ;;
    --bundle-id)         die 2 "release.sh 不接受 --bundle-id:正式发布包永远是 $EXPECT_BUNDLE_ID。" \
                             "要做开发副本用 ./scripts/build-app.sh --bundle-id app.machands.MacHands.dev,别走发布流程" ;;
    --skip-notarize)     SKIP_NOTARIZE=1; shift ;;
    -h|--help)           usage; exit 0 ;;
    *)                   die 2 "不认识的选项:$1" "./scripts/release.sh --help" ;;
  esac
done

# =========================================================================== #
step "1/6 预检"

[ "$(uname -s)" = "Darwin" ] || die 3 "发布流程只能在 Mac 上跑(uname -s = $(uname -s))。" \
  "把仓库拷到 Mac 上:cd macapp && ./scripts/release.sh …"
command -v xcrun >/dev/null 2>&1 || die 5 "没有 xcrun。" "装 Xcode 命令行工具:xcode-select --install"
command -v ditto >/dev/null 2>&1 || die 1 "没有 ditto(这真的是 macOS 吗?)"

# --- 证书 ---------------------------------------------------------------- #
[ -n "$SIGN_ID" ] || die 2 "缺 --sign。官网发布必须用 Developer ID Application 证书。" \
  'security find-identity -v -p codesigning 会列出你有哪些'

case "$SIGN_ID" in
  "Developer ID Application:"*) : ;;
  *)
    if [ "$SKIP_NOTARIZE" = 1 ]; then
      warn "「$SIGN_ID」不是 Developer ID Application —— 内部测试可以,别拿去发布。"
    else
      die 2 "「$SIGN_ID」不是 Developer ID Application 证书。" \
        "Apple Distribution 与 3rd Party Mac Developer 是上架 App Store 用的,签出来的包在别人机器上打不开、而且每次升级都会掉系统权限。去 developer.apple.com → Certificates 新建一张 Developer ID Application,步骤见 docs/RELEASE.md"
    fi ;;
esac

security find-identity -v -p codesigning 2>/dev/null | grep -qF "$SIGN_ID" \
  || die 4 "钥匙串里找不到「$SIGN_ID」。" \
     "security find-identity -v -p codesigning 会列出所有可用的;名字要一字不差(含括号里的 team id)"
ok "证书在钥匙串里"

# --- 公证凭据 ------------------------------------------------------------ #
if [ "$SKIP_NOTARIZE" = 0 ]; then
  [ -n "$KEYCHAIN_PROFILE" ] || die 2 "缺 --keychain-profile。" \
    "先建一次:xcrun notarytool store-credentials machands-notary --apple-id you@example.com --team-id TEAMID --password <App 专用密码>"
  if ! xcrun notarytool history --keychain-profile "$KEYCHAIN_PROFILE" >/dev/null 2>&1; then
    die 5 "钥匙串里没有名为「$KEYCHAIN_PROFILE」的公证凭据(或者它已失效)。" \
      "xcrun notarytool store-credentials $KEYCHAIN_PROFILE --apple-id you@example.com --team-id TEAMID --password <App 专用密码>"
  fi
  ok "公证凭据可用($KEYCHAIN_PROFILE)"
else
  warn "--skip-notarize:这次不公证,产出的包只能自己用"
fi

# --- 版本号 -------------------------------------------------------------- #
FILE_VERSION=""
[ -f "$APP_DIR/VERSION" ] && FILE_VERSION=$(tr -d ' \t\n\r' < "$APP_DIR/VERSION")
if [ -z "$VERSION" ]; then
  [ -n "$FILE_VERSION" ] || die 2 "macapp/VERSION 是空的,也没给 --version。"
  VERSION="$FILE_VERSION"
elif [ -n "$FILE_VERSION" ] && [ "$VERSION" != "$FILE_VERSION" ]; then
  die 2 "--version 是 $VERSION,但 macapp/VERSION 里写的是 $FILE_VERSION。" \
    "两处必须一致,否则 appcast 里的版本号和 App 自报的版本号对不上,更新会反复触发。先改 VERSION 文件"
fi
case "$VERSION" in *[!0-9.]*|""|.*|*.) die 2 "版本号要长得像 1.2.3(拿到的是 '$VERSION')" ;; esac

if [ -z "$BUILD_NUM" ]; then
  BUILD_NUM=$(git -C "$REPO_DIR" rev-list --count HEAD 2>/dev/null || true)
  [ -n "$BUILD_NUM" ] || BUILD_NUM=1
fi
ok "版本 $VERSION(build $BUILD_NUM)"

# --- 工作区 -------------------------------------------------------------- #
if git -C "$REPO_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  DIRTY=$(git -C "$REPO_DIR" status --porcelain 2>/dev/null | head -20)
  if [ -n "$DIRTY" ]; then
    if [ "$ALLOW_DIRTY" = 1 ]; then
      warn "工作区有未提交改动,按 --allow-dirty 继续。发出去的包将无法从 git 复现。"
      printf '%s\n' "$DIRTY" | sed 's/^/    /' >&2
    else
      printf '%s\n' "$DIRTY" | sed 's/^/    /' >&2
      die 2 "工作区不干净 —— 发出去的包应该能从一个提交复现。" \
        "先提交(或 git stash);真要带着改动发就加 --allow-dirty"
    fi
  else
    ok "工作区干净($(git -C "$REPO_DIR" rev-parse --short HEAD))"
  fi
fi

# --- 发布私钥与 OpenSSL(提前查,别等公证完了才发现签不了 appcast)-------- #
[ -f "$HOME/.machands/release-key.pem" ] || die 7 "没有发布私钥(~/.machands/release-key.pem)。" \
  "先跑一次:./scripts/keygen-release.sh —— 它会打印公钥,填进 Updater.swift 再编一版"
"$HERE/make-appcast.sh" --check || die 7 "appcast 的签名环境还不行(上面有原因)。" \
  "现在修比公证完再修省五分钟"

# =========================================================================== #
step "2/6 构建并签名(universal + 强化运行时)"

BUILD_ARGS=(--sign "$SIGN_ID" --hardened-runtime --universal
            --version "$VERSION" --build "$BUILD_NUM" --out "$OUT_DIR")
"$HERE/build-app.sh" "${BUILD_ARGS[@]}" \
  || die 4 "build-app.sh 没能出一个签好名的 .app。" \
     "先单独跑一次 ./scripts/build-app.sh 看是编译的问题还是签名的问题"

APP_BUNDLE="$OUT_DIR/$APP_NAME.app"
[ -d "$APP_BUNDLE" ] || die 1 "$APP_BUNDLE 不见了"

# --- bundle id 硬断言(plist 与签名两处都查)---------------------------- #
ACTUAL_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" \
            "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true)
[ "$ACTUAL_ID" = "$EXPECT_BUNDLE_ID" ] || die 8 \
  "打出来的 Info.plist 里 CFBundleIdentifier 是「${ACTUAL_ID:-空}」,应该是 $EXPECT_BUNDLE_ID。" \
  "正式发布包的 bundle id 不可改:改了就是另一个 App,用户已授权的屏幕录制/辅助功能全部作废,而且会和已装的那份在系统里同名打架"
SIGNED_ID=$(codesign -dv "$APP_BUNDLE" 2>&1 | sed -n 's/^Identifier=//p')
[ "$SIGNED_ID" = "$EXPECT_BUNDLE_ID" ] || die 8 \
  "签名里的 Identifier 是「${SIGNED_ID:-空}」,应该是 $EXPECT_BUNDLE_ID。" \
  "codesign 的 --identifier 和 Info.plist 必须一致,否则 TCC 认的是签名里那个"
ok "bundle id $EXPECT_BUNDLE_ID(plist 与签名一致)"

codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE" 2>&1 | sed 's/^/    /' \
  || die 4 "签名自检没过。" "codesign --verify --deep --strict -vvv '$APP_BUNDLE' 看详细原因"

DR=$(codesign -d -r- "$APP_BUNDLE" 2>/dev/null | sed -n 's/^designated => //p')
[ -n "$DR" ] && info "指定要求:$DR"
case "$DR" in
  *cdhash*) warn "指定要求里带 cdhash —— 这版升级后用户还是要重新授权。确认用的是 Developer ID 证书。" ;;
esac
if ! codesign -d --entitlements - "$APP_BUNDLE" 2>/dev/null | grep -q "apple-events"; then
  warn "签进去的 entitlements 里没有 apple-events —— agent 让 Mac 跑 osascript 会失败"
fi
ok "签名有效"

# =========================================================================== #
step "3/6 打包 $APP_NAME-$VERSION.zip"

# 必须用 ditto:`zip -r` 会毁掉 bundle 里的符号链接与扩展属性,
# 之后公证给出的错误信息会把人带偏一小时。
ZIP="$OUT_DIR/$APP_NAME-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP" || die 1 "ditto 打包失败"
ok "$ZIP  ($(wc -c < "$ZIP" | tr -d ' ') 字节)"

if [ "$SKIP_NOTARIZE" = 1 ]; then
  warn "跳过公证与 Gatekeeper 检查(--skip-notarize)"
else
  # ========================================================================= #
  step "4/6 公证(profile: $KEYCHAIN_PROFILE)"
  info "苹果那边一般几分钟;--wait 会一直等到有结果。"

  if ! xcrun notarytool submit "$ZIP" --keychain-profile "$KEYCHAIN_PROFILE" --wait; then
    die 5 "苹果拒绝了这个包。" \
      "看完整报告:xcrun notarytool log <submission-id> --keychain-profile $KEYCHAIN_PROFILE"
  fi
  ok "通过公证"

  # 票据钉在 .app 上(zip 钉不了),所以钉完要用钉好的 .app 重新打一次 zip。
  step "钉票据 → 重打 zip"
  xcrun stapler staple "$APP_BUNDLE" \
    || die 5 "票据钉不上 .app。" "票据可能还没发布,等一分钟再跑:xcrun stapler staple '$APP_BUNDLE'"
  xcrun stapler validate "$APP_BUNDLE" >/dev/null 2>&1 \
    || die 5 "钉上了但校验不过。" "xcrun stapler validate '$APP_BUNDLE'"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP" || die 1 "重打 zip 失败"
  ok "票据已钉进 .app,zip 已用钉好的版本重打"

  # ========================================================================= #
  step "5/6 Gatekeeper"
  SPCTL=$(spctl -a -vv -t exec "$APP_BUNDLE" 2>&1 || true)
  printf '%s\n' "$SPCTL" | sed 's/^/    /'
  case "$SPCTL" in
    *accepted*) ok "spctl:accepted —— 别人双击就能打开" ;;
    *) die 6 "spctl 不放行,这个包在别人机器上会被拦。" \
         "常见原因:证书不是 Developer ID、公证没成功、票据没钉上。上面几行有具体理由" ;;
  esac
fi

# =========================================================================== #
step "6/6 生成 appcast.json"

APPCAST="$OUT_DIR/appcast.json"
APPCAST_ARGS=(--zip "$ZIP" --version "$VERSION" --build "$BUILD_NUM"
              --host "$HOST" --out "$APPCAST")
[ -n "$NOTES_ZH" ] && APPCAST_ARGS+=(--notes-zh "$NOTES_ZH")
[ -n "$NOTES_EN" ] && APPCAST_ARGS+=(--notes-en "$NOTES_EN")
"$HERE/make-appcast.sh" "${APPCAST_ARGS[@]}" || die 7 "appcast 生成失败(上面有原因)"

# =========================================================================== #
HOST_CLEAN="${HOST%/}"
printf '\n%s发布物(两个文件,传到官网):%s\n' "$B" "$Z"
printf '  %-40s → %s/downloads/%s\n' "$ZIP" "$HOST_CLEAN" "$APP_NAME-$VERSION.zip"
printf '  %-40s → %s/appcast.json\n' "$APPCAST" "$HOST_CLEAN"
if command -v shasum >/dev/null 2>&1; then
  printf '\n  SHA256: %s\n' "$(shasum -a 256 "$ZIP" | awk '{print $1}')"
fi
printf '\n%s这一版之后:%s\n' "$B" "$Z"
printf '  · 老用户由 App 自己更新(读 %s/appcast.json,验签后原地替换)。\n' "$HOST_CLEAN"
printf '  · 因为用的是 Developer ID 证书、指定要求跨版本稳定,\n'
printf '    升级后**不需要**重新授权屏幕录制与辅助功能。\n'
printf '  · 新用户从 %s/download.html 下载。\n' "$HOST_CLEAN"
