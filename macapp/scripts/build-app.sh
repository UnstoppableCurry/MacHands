#!/usr/bin/env bash
# build-app.sh — 从 SwiftPM 的产物拼出 MacHands.app。没有 Xcode 工程。
#
#   swift build -c release     给我们一个裸 Mach-O
#   这个脚本                    把它包成一个真正的 .app:
#
#     MacHands.app/
#       Contents/
#         Info.plist          <- LSUIElement=true:只在菜单栏,没有 Dock 图标
#         PkgInfo
#         MacOS/MacHands      <- 可执行文件
#         Resources/AppIcon.icns   (可选)
#
# 它需要的一切(swift、plutil、codesign)都随 Xcode 命令行工具一起装。
#
#   ./scripts/build-app.sh                 不签名,本机跑一下
#   ./scripts/build-app.sh --sign adhoc    ad-hoc 签名(只在本机有效;
#                                          第一次打开要右键 → 打开)
#   ./scripts/build-app.sh --install       顺手拷进 /Applications
#
# 要发给别人,用 scripts/release.sh(Developer ID + 公证 + DMG)。
#
# 退出码:0 成功 · 1 构建/组装失败 · 2 参数用法错 · 3 平台不对 · 4 签名失败
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
APP_DIR=$(dirname "$HERE")
RES_DIR="$APP_DIR/Resources"

PRODUCT="MacHands"
APP_NAME="MacHands"
BUNDLE_ID="app.machands.MacHands"
MIN_MACOS="13.0"
OUT_DIR="$APP_DIR/dist"
VERSION=""
BUILD_NUM=""
DO_BUILD=1
DO_SIGN=0
SIGN_ID="-"
DO_INSTALL=0
DO_CLEAN=0
UNIVERSAL=0

if [ -t 1 ]; then
  R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; D=$'\033[2m'; B=$'\033[1m'; Z=$'\033[0m'
else
  R=""; G=""; Y=""; D=""; B=""; Z=""
fi
step() { printf '%s==>%s %s\n' "$B" "$Z" "$*"; }
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
用法: ./scripts/build-app.sh [选项]

  --sign [IDENTITY]  给 bundle 签名。IDENTITY 可以是:
                       adhoc(或省略)  ad-hoc 签名,只在本机有效
                       "Developer ID Application: 名字 (TEAMID)"
  --version X.Y.Z    marketing 版本      (默认:VERSION 文件,否则 0.1.0)
  --build N          CFBundleVersion     (默认:git 提交数,否则 1)
  --out DIR          .app 放哪儿          (默认:$OUT_DIR)
  --universal        同时编 arm64 与 x86_64
  --install          顺手拷进 /Applications
  --no-build         跳过 swift build,直接重新打包已有的二进制
  --clean            先清掉输出目录(给两次连 .build 一起清)
  -h, --help
EOF
}

CLEAN_LEVEL=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --version)   [ "${2:-}" ] || die 2 "--version 要一个值"; VERSION="$2"; shift 2 ;;
    --build)     [ "${2:-}" ] || die 2 "--build 要一个数字"; BUILD_NUM="$2"; shift 2 ;;
    --out)       [ "${2:-}" ] || die 2 "--out 要一个目录"; OUT_DIR="$2"; shift 2 ;;
    --universal) UNIVERSAL=1; shift ;;
    --sign)
      DO_SIGN=1
      case "${2:-}" in
        ""|-*)          : ;;
        adhoc|ad-hoc|-) SIGN_ID="-"; shift ;;
        *)              SIGN_ID="$2"; shift ;;
      esac
      shift ;;
    --install)   DO_INSTALL=1; shift ;;
    --no-build)  DO_BUILD=0; shift ;;
    --clean)     DO_CLEAN=1; CLEAN_LEVEL=$((CLEAN_LEVEL+1)); shift ;;
    -h|--help)   usage; exit 0 ;;
    *)           die 2 "不认识的选项:$1" "./scripts/build-app.sh --help" ;;
  esac
done

APP_BUNDLE="$OUT_DIR/$APP_NAME.app"

# --------------------------------------------------------------------------- #
step "检查工具链"

if [ "$(uname -s)" != "Darwin" ]; then
  die 3 "这个脚本要打的是 macOS 的 .app,只能在 Mac 上跑(uname -s = $(uname -s))。" \
        "把仓库拷到 Mac 上,然后:cd macapp && ./scripts/build-app.sh"
fi
command -v swift >/dev/null 2>&1 || die 1 "PATH 里没有 swift。" "装 Xcode 命令行工具:xcode-select --install"
xcode-select -p >/dev/null 2>&1 || die 1 "没有可用的 developer 目录(xcode-select -p 失败)。" \
        "xcode-select --install —— 如果已经装了 Xcode:sudo xcode-select -r"
[ -f "$APP_DIR/Package.swift" ] || die 1 "$APP_DIR 里没有 Package.swift。" "在完整的仓库里跑这个脚本。"

info "macOS $(sw_vers -productVersion 2>/dev/null || echo '?') · $(swift --version 2>/dev/null | head -1)"

# --------------------------------------------------------------------------- #
if [ -z "$VERSION" ]; then
  if [ -f "$APP_DIR/VERSION" ]; then VERSION=$(tr -d ' \t\n\r' < "$APP_DIR/VERSION"); fi
  [ -n "$VERSION" ] || VERSION="0.1.0"
fi
case "$VERSION" in
  *[!0-9.]*|""|.*|*.) die 2 "--version 要长得像 1.2.3(拿到的是 '$VERSION')" ;;
esac
if [ -z "$BUILD_NUM" ]; then
  BUILD_NUM=$(git -C "$APP_DIR" rev-list --count HEAD 2>/dev/null || true)
  [ -n "$BUILD_NUM" ] || BUILD_NUM=1
fi

if [ "$DO_CLEAN" = 1 ]; then
  step "清理"
  case "$OUT_DIR" in
    ""|/|/Applications|"$HOME"|*..*) die 1 "拒绝清理这个可疑的 --out 路径:$OUT_DIR" ;;
  esac
  if [ -d "$OUT_DIR" ]; then rm -rf "${OUT_DIR:?}"; info "删掉了 $OUT_DIR"; fi
  if [ "$CLEAN_LEVEL" -ge 2 ] && [ -d "$APP_DIR/.build" ]; then
    rm -rf "${APP_DIR:?}/.build"; info "删掉了 $APP_DIR/.build"
  fi
fi

# --------------------------------------------------------------------------- #
BUILD_FLAGS=(-c release --product "$PRODUCT")
if [ "$UNIVERSAL" = 1 ]; then
  BUILD_FLAGS+=(--arch arm64 --arch x86_64)
fi

if [ "$DO_BUILD" = 1 ]; then
    if [ "$UNIVERSAL" = 1 ]; then step "swift build -c release (universal)"; else step "swift build -c release"; fi
  ( cd "$APP_DIR" && swift build "${BUILD_FLAGS[@]}" ) \
    || die 1 "swift build 失败。" "往上翻编译错误;BUILD.md 里列了常见的几种"
else
  info "跳过 swift build(--no-build)"
fi

BIN_DIR=$( cd "$APP_DIR" && swift build "${BUILD_FLAGS[@]}" --show-bin-path 2>/dev/null ) \
  || die 1 "问不出 SwiftPM 把产物放哪儿了。" "去掉 --no-build 再试"
BIN="$BIN_DIR/$PRODUCT"
[ -x "$BIN" ] || die 1 "$BIN 这里没有可执行文件" \
  "确认 Package.swift 里声明了 .executable(name: \"$PRODUCT\", ...)"

info "二进制:$BIN  [$(lipo -archs "$BIN" 2>/dev/null || echo '?')]"

# --------------------------------------------------------------------------- #
step "图标"
ICNS="$RES_DIR/AppIcon.icns"
ICON_SRC="$RES_DIR/AppIcon-1024.png"
if [ ! -f "$ICNS" ] && [ -f "$ICON_SRC" ] && command -v iconutil >/dev/null 2>&1; then
  info "用 AppIcon-1024.png 生成 AppIcon.icns"
  TMPSET=$(mktemp -d)/AppIcon.iconset
  mkdir -p "$TMPSET"
  for size in 16 32 64 128 256 512; do
    sips -z $size $size "$ICON_SRC" --out "$TMPSET/icon_${size}x${size}.png" >/dev/null 2>&1 || true
    sips -z $((size*2)) $((size*2)) "$ICON_SRC" --out "$TMPSET/icon_${size}x${size}@2x.png" >/dev/null 2>&1 || true
  done
  iconutil -c icns "$TMPSET" -o "$ICNS" 2>/dev/null || warn "iconutil 没成;这次就不带图标了"
fi
if [ -f "$ICNS" ]; then
  info "用 $ICNS"
else
  ICNS=""
  info "没有图标,用系统默认的(不影响功能)"
fi

# --------------------------------------------------------------------------- #
step "组装 $APP_NAME.app"
mkdir -p "$OUT_DIR"

# 先在暂存目录里拼好再换过去:中途被打断也不会留下半个 .app 顶替一个好的。
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/machands-build.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
NEW="$STAGE/$APP_NAME.app"
mkdir -p "$NEW/Contents/MacOS" "$NEW/Contents/Resources"

install -m 0755 "$BIN" "$NEW/Contents/MacOS/$PRODUCT"
if [ -n "$ICNS" ]; then install -m 0644 "$ICNS" "$NEW/Contents/Resources/AppIcon.icns"; fi
printf 'APPL????' > "$NEW/Contents/PkgInfo"

PLIST_OUT="$NEW/Contents/Info.plist"
[ -f "$RES_DIR/Info.plist" ] || die 1 "缺 $RES_DIR/Info.plist"
install -m 0644 "$RES_DIR/Info.plist" "$PLIST_OUT"

if command -v plutil >/dev/null 2>&1; then
  plset() {
    plutil -replace "$1" "$2" "$3" "$PLIST_OUT" >/dev/null 2>&1 \
      || plutil -insert "$1" "$2" "$3" "$PLIST_OUT" >/dev/null 2>&1 \
      || warn "Info.plist 里设不了 $1"
  }
  plset CFBundleIdentifier         -string "$BUNDLE_ID"
  plset CFBundleExecutable         -string "$PRODUCT"
  plset CFBundleName               -string "$APP_NAME"
  plset CFBundleShortVersionString -string "$VERSION"
  plset CFBundleVersion            -string "$BUILD_NUM"
  plset LSMinimumSystemVersion     -string "$MIN_MACOS"
  if [ "$(plutil -extract LSUIElement raw -o - "$PLIST_OUT" 2>/dev/null)" != "true" ]; then
    warn "模板没设 LSUIElement=true —— 强制加上(菜单栏 App 不该出现在 Dock 里)"
    plset LSUIElement -bool true
  fi
  plutil -lint "$PLIST_OUT" >/dev/null || die 1 "生成出来的 Info.plist 不合法"
else
  warn "没有 plutil:模板原样使用,版本号可能是旧的"
fi

# 隔离属性会让 codesign 报 "resource fork ... not allowed",先剥掉。
xattr -cr "$NEW" 2>/dev/null || true

# --------------------------------------------------------------------------- #
if [ "$DO_SIGN" = 1 ]; then
  if [ "$SIGN_ID" = "-" ]; then
    step "签名(ad-hoc)"
    info "只在这台 Mac 上有效。别的 Mac 上 Gatekeeper 仍然会说「未识别的开发者」。"
    codesign --force --sign - --identifier "$BUNDLE_ID" "$NEW" \
      || die 4 "ad-hoc 签名失败" "试:xattr -cr '$NEW' && codesign --force --sign - '$NEW'"
  else
    step "签名:$SIGN_ID"
    SIGN_ARGS=(--force --options runtime --timestamp --sign "$SIGN_ID" --identifier "$BUNDLE_ID")
    ENT="$RES_DIR/MacHands.entitlements"
    if [ -f "$ENT" ] && grep -q '<key>' "$ENT"; then
      info "entitlements:$ENT"
      SIGN_ARGS+=(--entitlements "$ENT")
    fi
    codesign "${SIGN_ARGS[@]}" "$NEW" \
      || die 4 "用 '$SIGN_ID' 签名失败" "看看你有哪些证书:security find-identity -v -p codesigning"
  fi
  codesign --verify --strict --verbose=2 "$NEW" 2>&1 | sed 's/^/    /' || true
else
  info "没签名(要本机签名加 --sign adhoc)"
  info "未签名的 App 也能跑,但用 SMAppService 注册登录项时带签名更可靠。"
fi

# --------------------------------------------------------------------------- #
case "$APP_BUNDLE" in
  *"/$APP_NAME.app") : ;;
  *) die 1 "内部错误:拒绝覆盖 '$APP_BUNDLE'" ;;
esac
rm -rf "${APP_BUNDLE:?}"
mv "$NEW" "$APP_BUNDLE"
ok "$APP_BUNDLE  (v$VERSION build $BUILD_NUM)"
du -sh "$APP_BUNDLE" | sed 's/^/    /'

if [ "$DO_INSTALL" = 1 ]; then
  step "安装到 /Applications"
  TARGET="/Applications/$APP_NAME.app"
  if pgrep -f "$APP_NAME.app/Contents/MacOS/$PRODUCT" >/dev/null 2>&1; then
    die 1 "$APP_NAME 正在跑。" "从菜单栏图标里退出它,再重跑一次 --install"
  fi
  rm -rf "${TARGET:?}"
  cp -R "$APP_BUNDLE" "$TARGET" || die 1 "写不了 $TARGET" "/Applications 你有写权限吗?"
  ok "$TARGET"
  info "打开它:open -a '$APP_NAME'"
fi

printf '\n%s接下来:%s\n' "$B" "$Z"
printf '  1. 把 %s 拖进 /Applications(或者加 --install)\n' "$APP_BUNDLE"
printf '  2. 第一次打开:右键 → 打开(Gatekeeper 只问这一次)\n'
printf '  3. 菜单栏出现一只手 —— 按设计就是没有 Dock 图标\n'
printf '  4. 点「复制给 agent」,把那段文字贴给你的 agent\n'
