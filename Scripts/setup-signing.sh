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
