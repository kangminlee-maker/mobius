#!/bin/bash
# MobiusApp 실행파일 → dist/Mobius.app 번들 조립 + ad-hoc 서명
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP=dist/Mobius.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
# 주의: 기본 APFS는 대소문자 구분이 없어 "Mobius"와 "mobius"가 같은 파일로 충돌한다.
# 앱 실행파일은 MobiusApp으로 두고 CLI를 mobius로 유지한다
# (SettingsView의 Bundle.main.url(forAuxiliaryExecutable: "mobius")가 이 이름에 의존).
cp .build/release/MobiusApp "$APP/Contents/MacOS/MobiusApp"
cp .build/release/mobius "$APP/Contents/MacOS/mobius"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>MobiusApp</string>
  <key>CFBundleIdentifier</key><string>dev.mobius.app</string>
  <key>CFBundleName</key><string>Mobius</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <!-- LSUIElement 미사용: macOS 26 Tahoe에서 LSUIElement 앱의 MenuBarExtra 아이콘이
       등록되지 않는 회귀가 있어(실측 확인), AppDelegate의 setActivationPolicy(.accessory)로 대체 -->
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
# 고정 인증서가 있으면 그걸로 서명 (Keychain "항상 허용"이 리빌드 후에도 유지됨).
# 없으면 ad-hoc 폴백 — Scripts/setup-signing.sh 로 인증서를 만들 수 있다.
if security find-identity -v -p codesigning | grep -q "Mobius Dev Signing"; then
  codesign --force -s "Mobius Dev Signing" "$APP"
else
  codesign --force -s - "$APP"
fi
echo "OK: $APP (open $APP 으로 실행)"
