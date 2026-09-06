#!/usr/bin/env bash
# keygen-release.sh — 生成"发布签名密钥"(Ed25519)。一台机器上只做一次,一辈子只做一次。
#
# 这把钥匙和苹果的证书是两回事:
#
#   苹果证书    证明"这个 .app 是 wang tianxin 签的",Gatekeeper 与 TCC 认它。
#   发布密钥    证明"这个 zip 就是我们发布的那一个",App 内的自动更新认它。
#               中间人换掉 zip、或者官网被人写了东西,App 会拒绝安装。
#
# 私钥只留在这台机器上:~/.machands/release-key.pem(600)。
# 它不进仓库、不进 CI、不打印到屏幕上。丢了就只能换公钥重新发一版。
#
# 用法:
#   ./scripts/keygen-release.sh            生成(已存在则拒绝)
#   ./scripts/keygen-release.sh --show     只打印现有公钥
#
# 退出码:0 成功 · 1 环境不满足 · 2 参数用法错 · 3 私钥已存在
set -euo pipefail

KEY_DIR="$HOME/.machands"
KEY_FILE="$KEY_DIR/release-key.pem"
SHOW_ONLY=0

if [ -t 1 ]; then
  R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; D=$'\033[2m'; B=$'\033[1m'; Z=$'\033[0m'
else
  R=""; G=""; Y=""; D=""; B=""; Z=""
fi
# 说明文字一律走 stderr,stdout 只留公钥 —— 这样 PUB=$(keygen-release.sh --show) 是干净的。
step() { printf '\n%s==>%s %s\n' "$B" "$Z" "$*" >&2; }
info() { printf '    %s%s%s\n' "$D" "$*" "$Z" >&2; }
warn() { printf '%s!  %s%s\n' "$Y" "$*" "$Z" >&2; }
ok()   { printf '%s✓%s  %s\n' "$G" "$Z" "$*" >&2; }
die()  {
  local code="$1"; shift
  printf '%s✗  %s%s\n' "$R" "$1" "$Z" >&2
  if [ "$#" -gt 1 ]; then printf '%s   → %s%s\n' "$D" "$2" "$Z" >&2; fi
  exit "$code"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --show) SHOW_ONLY=1; shift ;;
    -h|--help)
      sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) die 2 "不认识的选项:$1" "./scripts/keygen-release.sh --help" ;;
  esac
done

# --------------------------------------------------------------------------- #
# macOS 自带的是 LibreSSL,它的 pkeyutl 不认 -rawin,签不了 Ed25519。
# 所以要找一个真正的 OpenSSL 3。
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

SSL=$(find_openssl) || die 1 "找不到 OpenSSL 3(系统自带的 LibreSSL 签不了 Ed25519)。" \
  "brew install openssl@3 —— 或者把路径放进 MACHANDS_OPENSSL"
info "openssl:$SSL  ($("$SSL" version))"

print_pubkey() {
  local pub
  # base64url(和 SPEC §2 全仓一致;App 里 Base64URL.decode 认它)
  pub=$("$SSL" pkey -in "$KEY_FILE" -pubout -outform DER 2>/dev/null \
        | tail -c 32 | base64 | tr -d '\n' | tr '+/' '-_' | tr -d '=')
  [ -n "$pub" ] || die 1 "从 $KEY_FILE 里读不出公钥" "文件可能坏了;它应该是一段 PRIVATE KEY 的 PEM"
  printf '%s' "$pub"
}

if [ "$SHOW_ONLY" = 1 ]; then
  [ -f "$KEY_FILE" ] || die 3 "还没有发布密钥($KEY_FILE 不存在)。" "先跑一次:./scripts/keygen-release.sh"
  printf '%s\n' "$(print_pubkey)"
  exit 0
fi

# --------------------------------------------------------------------------- #
step "生成发布签名密钥(Ed25519)"

if [ -f "$KEY_FILE" ]; then
  die 3 "$KEY_FILE 已经有了 —— 不覆盖。" \
        "换钥匙意味着旧版本 App 认不出新包、全部用户要手动重装一次。真要换就先自己把它挪走。"
fi

mkdir -p "$KEY_DIR"
chmod 700 "$KEY_DIR"
umask 077
"$SSL" genpkey -algorithm ed25519 -out "$KEY_FILE" 2>/dev/null \
  || die 1 "生成失败。" "$SSL genpkey -algorithm ed25519 —— 单独跑一次看它说什么"
chmod 600 "$KEY_FILE"
ok "私钥:$KEY_FILE (600,只有你能读)"

PUB=$(print_pubkey)

# 自检:签一段再验一遍,免得发布当天才发现钥匙是坏的。
TMP=$(mktemp -d "${TMPDIR:-/tmp}/machands-keygen.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
printf 'selftest' > "$TMP/m"
"$SSL" pkeyutl -sign -inkey "$KEY_FILE" -rawin -in "$TMP/m" -out "$TMP/s" 2>/dev/null \
  || die 1 "这把钥匙签不动东西。" "换个 OpenSSL 再来:$SSL version"
"$SSL" pkey -in "$KEY_FILE" -pubout -out "$TMP/pub.pem" 2>/dev/null
"$SSL" pkeyutl -verify -pubin -inkey "$TMP/pub.pem" -rawin -in "$TMP/m" -sigfile "$TMP/s" >/dev/null 2>&1 \
  || die 1 "自检没过:签了但验不过。" "别用这把钥匙发布"
ok "自检通过(签 → 验)"

# --------------------------------------------------------------------------- #
printf '\n%s公钥(base64url,32 字节原始值):%s\n\n' "$B" "$Z" >&2
printf '%s\n' "$PUB"
printf '\n%s接下来:%s\n' "$B" "$Z" >&2
printf '  1. 把它填进 macapp/Sources/MacHands/Updater.swift 的 releasePublicKey\n' >&2
printf '  2. 重新编一版 App —— 只有内置了这个公钥的版本,才认得出以后发布的包\n' >&2
printf '  3. 备份 %s(比如密码管理器)。丢了 = 所有用户要手动重装一次\n' "$KEY_FILE" >&2
printf '  4. 想再看一次公钥:./scripts/keygen-release.sh --show\n' >&2
