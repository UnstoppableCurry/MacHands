#!/usr/bin/env bash
# make-appcast.sh — 把一个发布用的 zip 变成 appcast.json(App 的自动更新读它)。
#
#   sha256(zip)  ->  用发布私钥对这串十六进制签名  ->  写进 appcast.json
#
# App 里的 Updater 拿到 appcast.json 后:下载 zip、自己算一遍 sha256、
# 用内置公钥验签。三者对不上就拒绝安装 —— 官网被人改了也换不动用户的 App。
#
# 用法:
#   ./scripts/make-appcast.sh --zip dist/MacHands-0.3.0.zip \
#                             --version 0.3.0 --build 21 \
#                             --host https://machands.app \
#                             [--notes-zh "…"] [--notes-en "…"] \
#                             [--out dist/appcast.json] [--stdout] [--check]
#
# 退出码:0 成功 · 1 环境/文件问题 · 2 参数用法错 · 3 没有发布私钥
set -euo pipefail

KEY_FILE="$HOME/.machands/release-key.pem"
ZIP=""
VERSION=""
BUILD_NUM=""
HOST=""
NOTES_ZH=""
NOTES_EN=""
MIN_OS="13.0"
OUT=""
TO_STDOUT=0
CHECK_ONLY=0

if [ -t 1 ]; then
  R=$'\033[31m'; G=$'\033[32m'; D=$'\033[2m'; B=$'\033[1m'; Z=$'\033[0m'
else
  R=""; G=""; D=""; B=""; Z=""
fi
step() { printf '\n%s==>%s %s\n' "$B" "$Z" "$*" >&2; }
info() { printf '    %s%s%s\n' "$D" "$*" "$Z" >&2; }
ok()   { printf '%s✓%s  %s\n' "$G" "$Z" "$*" >&2; }
die()  {
  local code="$1"; shift
  printf '%s✗  %s%s\n' "$R" "$1" "$Z" >&2
  if [ "$#" -gt 1 ]; then printf '%s   → %s%s\n' "$D" "$2" "$Z" >&2; fi
  exit "$code"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --zip)       [ "${2:-}" ] || die 2 "--zip 要一个文件路径"; ZIP="$2"; shift 2 ;;
    --version)   [ "${2:-}" ] || die 2 "--version 要一个值"; VERSION="$2"; shift 2 ;;
    --build)     [ "${2:-}" ] || die 2 "--build 要一个数字"; BUILD_NUM="$2"; shift 2 ;;
    --host)      [ "${2:-}" ] || die 2 "--host 要一个地址"; HOST="$2"; shift 2 ;;
    --notes-zh)  [ "${2:-}" ] || die 2 "--notes-zh 要一段文字"; NOTES_ZH="$2"; shift 2 ;;
    --notes-en)  [ "${2:-}" ] || die 2 "--notes-en 要一段文字"; NOTES_EN="$2"; shift 2 ;;
    --min-os)    [ "${2:-}" ] || die 2 "--min-os 要一个版本"; MIN_OS="$2"; shift 2 ;;
    --out)       [ "${2:-}" ] || die 2 "--out 要一个文件路径"; OUT="$2"; shift 2 ;;
    --stdout)    TO_STDOUT=1; shift ;;
    --check)     CHECK_ONLY=1; shift ;;
    -h|--help)   sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)           die 2 "不认识的选项:$1" "./scripts/make-appcast.sh --help" ;;
  esac
done

find_openssl() {
  local candidates=()
  [ -n "${MACHANDS_OPENSSL:-}" ] && candidates+=("$MACHANDS_OPENSSL")
  candidates+=(/opt/homebrew/opt/openssl@3/bin/openssl
               /usr/local/opt/openssl@3/bin/openssl
               /opt/homebrew/bin/openssl
               /usr/local/bin/openssl)
  command -v openssl >/dev/null 2>&1 && candidates+=("$(command -v openssl)")
  local c
  for c in "${candidates[@]}"; do
    [ -x "$c" ] || continue
    case "$("$c" version 2>/dev/null)" in
      OpenSSL\ 3*|OpenSSL\ 4*) printf '%s' "$c"; return 0 ;;
    esac
  done
  return 1
}

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else die 1 "既没有 shasum 也没有 sha256sum"; fi
}

# JSON 字符串转义:反斜杠、引号、换行。发布说明就这点花样。
json_escape() {
  printf '%s' "$1" \
    | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\r//g' -e 's/\t/\\t/g' \
    | awk 'BEGIN{ORS=""} {if (NR>1) printf "\\n"; print}'
}

# --check:只确认"到时候签得动"(OpenSSL 3 + 私钥在),不产出任何东西。
# release.sh 在预检阶段调它 —— 免得公证等了五分钟,回来才发现 appcast 签不了。
if [ "$CHECK_ONLY" = 1 ]; then
  SSL=$(find_openssl) || die 1 "找不到 OpenSSL 3(系统自带的 LibreSSL 签不了 Ed25519)。" \
    "brew install openssl@3 —— 或者把路径放进 MACHANDS_OPENSSL"
  [ -f "$KEY_FILE" ] || die 3 "没有发布私钥($KEY_FILE)。" "先跑一次:./scripts/keygen-release.sh"
  TMPC=$(mktemp -d "${TMPDIR:-/tmp}/machands-check.XXXXXX"); trap 'rm -rf "$TMPC"' EXIT
  printf 'check' > "$TMPC/m"
  "$SSL" pkeyutl -sign -inkey "$KEY_FILE" -rawin -in "$TMPC/m" -out "$TMPC/s" 2>/dev/null \
    || die 1 "这把发布私钥签不动东西。" "$SSL pkey -in $KEY_FILE -text -noout 看它是不是 Ed25519"
  ok "appcast 签名环境就绪($("$SSL" version | cut -d' ' -f1-2))"
  exit 0
fi

[ -n "$ZIP" ]       || die 2 "缺 --zip"
[ -n "$VERSION" ]   || die 2 "缺 --version"
[ -n "$BUILD_NUM" ] || die 2 "缺 --build"
[ -n "$HOST" ]      || die 2 "缺 --host(例如 https://machands.app)"
[ -f "$ZIP" ]       || die 1 "$ZIP 不存在"
case "$VERSION" in *[!0-9.]*|""|.*|*.) die 2 "--version 要长得像 1.2.3(拿到的是 '$VERSION')" ;; esac
case "$BUILD_NUM" in *[!0-9]*|"") die 2 "--build 要是个整数(拿到的是 '$BUILD_NUM')" ;; esac
case "$HOST" in
  http://*|https://*) : ;;
  *) die 2 "--host 要带协议头(https://…)" ;;
esac
HOST="${HOST%/}"   # 去掉结尾的斜杠,免得拼出 //downloads

# --------------------------------------------------------------------------- #
SSL=$(find_openssl) || die 1 "找不到 OpenSSL 3(系统自带的 LibreSSL 签不了 Ed25519)。" \
  "brew install openssl@3 —— 或者把路径放进 MACHANDS_OPENSSL"
[ -f "$KEY_FILE" ] || die 3 "没有发布私钥($KEY_FILE)。" "先跑一次:./scripts/keygen-release.sh"

# --------------------------------------------------------------------------- #
step "算 sha256"
SHA=$(sha256_of "$ZIP")
SIZE=$(wc -c < "$ZIP" | tr -d ' ')
info "$(basename "$ZIP")  $SIZE 字节"
info "sha256 $SHA"

step "签名(Ed25519,签的是上面那串十六进制)"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/machands-appcast.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
printf '%s' "$SHA" > "$TMP/msg"
"$SSL" pkeyutl -sign -inkey "$KEY_FILE" -rawin -in "$TMP/msg" -out "$TMP/sig" 2>/dev/null \
  || die 1 "签名失败。" "私钥可能不是 Ed25519:$SSL pkey -in $KEY_FILE -text -noout"
# base64url:和 SPEC §2 全仓一致,App 用 Base64URL.decode 解
SIG=$(base64 < "$TMP/sig" | tr -d '\n' | tr '+/' '-_' | tr -d '=')

# 立刻用公钥验一遍。发布当天最不想遇到的就是"签了但验不过"。
"$SSL" pkey -in "$KEY_FILE" -pubout -out "$TMP/pub.pem" 2>/dev/null
"$SSL" pkeyutl -verify -pubin -inkey "$TMP/pub.pem" -rawin -in "$TMP/msg" -sigfile "$TMP/sig" >/dev/null 2>&1 \
  || die 1 "自检没过:签出来的名字自己都验不过。" "别把这个 appcast 传上去"
PUB=$("$SSL" pkey -in "$KEY_FILE" -pubout -outform DER 2>/dev/null \
      | tail -c 32 | base64 | tr -d '\n' | tr '+/' '-_' | tr -d '=')
ok "签名 64 字节(base64url),自检通过"
info "公钥 $PUB  ← App 里 Updater.releasePublicKey 必须是这个"

# --------------------------------------------------------------------------- #
URL="$HOST/downloads/MacHands-$VERSION.zip"
PUBLISHED=$(date -u +%Y-%m-%dT%H:%M:%SZ)

JSON=$(cat <<JSONEOF
{
  "version": "$VERSION",
  "build": $BUILD_NUM,
  "url": "$URL",
  "sha256": "$SHA",
  "sig": "$SIG",
  "notes_zh": "$(json_escape "$NOTES_ZH")",
  "notes_en": "$(json_escape "$NOTES_EN")",
  "min_os": "$MIN_OS",
  "published": "$PUBLISHED"
}
JSONEOF
)

if [ "$TO_STDOUT" = 1 ]; then
  printf '%s\n' "$JSON"
  exit 0
fi

[ -n "$OUT" ] || OUT="$(dirname "$ZIP")/appcast.json"
printf '%s\n' "$JSON" > "$OUT" || die 1 "写不了 $OUT"
ok "$OUT"
printf '\n%s上传到官网:%s\n' "$B" "$Z" >&2
printf '  %s        → %s/appcast.json\n' "$OUT" "$HOST" >&2
printf '  %s  → %s\n' "$ZIP" "$URL" >&2
