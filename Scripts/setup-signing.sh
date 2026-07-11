#!/bin/bash
# Mobius 고정 서명 인증서 생성/등록 (1회 실행)
#
# 왜 필요한가: ad-hoc 서명(-s -)은 빌드마다 정체성이 바뀌어 Keychain "항상 허용"이
# 다음 빌드에서 무효가 된다. 자체 서명 인증서로 서명하면 정체성이 고정되어
# 항목당 1회 허용 후 다시는 묻지 않는다.
set -euo pipefail

NAME="Mobius Dev Signing"

if security find-identity -v -p codesigning | grep -q "$NAME"; then
  echo "이미 존재: $NAME — 새로 만들 필요 없음"
  exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# 인증서(키 포함)는 이미 import됐는데 신뢰 등록만 실패한 경우(비GUI 실행 등) —
# 여기서 새 인증서를 또 만들면 같은 이름이 중복되어 codesign이 ambiguous로 실패한다
# (2026-07-11 실제 발생). 기존 인증서로 신뢰 등록만 재시도한다.
if security find-certificate -c "$NAME" >/dev/null 2>&1; then
  echo "인증서는 있으나 codesign 신뢰 미등록 — 신뢰 등록만 재시도 (관리자 암호 창 1회)"
  security find-certificate -c "$NAME" -p > "$TMP/cert.pem"
  osascript -e "do shell script \"security add-trusted-cert -d -r trustRoot -p codeSign -k /Library/Keychains/System.keychain '$TMP/cert.pem'\" with administrator privileges"
  echo "완료: '$NAME' 신뢰 등록"
  security find-identity -v -p codesigning | grep "$NAME" || true
  exit 0
fi

# 1. 코드서명 용도 자체 서명 인증서 생성
/usr/bin/openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -days 3650 -nodes -subj "/CN=$NAME" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1

# 2. p12로 묶어 로그인 키체인에 import (codesign이 키를 쓸 수 있게 -T 지정)
/usr/bin/openssl pkcs12 -export -out "$TMP/mobius.p12" -inkey "$TMP/key.pem" \
  -in "$TMP/cert.pem" -passout pass:mobius-signing >/dev/null 2>&1
security import "$TMP/mobius.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
  -P mobius-signing -T /usr/bin/codesign

# 3. 인증서를 코드서명 용도로 신뢰 (관리자 권한 필요 — GUI 암호 창 1회)
osascript -e "do shell script \"security add-trusted-cert -d -r trustRoot -p codeSign -k /Library/Keychains/System.keychain '$TMP/cert.pem'\" with administrator privileges"

echo "완료: '$NAME' 인증서 생성/신뢰 등록"
security find-identity -v -p codesigning | grep "$NAME" || true
