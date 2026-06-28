# 자체 서명 코드 서명 인증서 (로컬 전용)

인앱 "업데이트" 버튼은 재빌드 → 재설치 → 재시작을 한다. 이때 **ad-hoc 서명**(`codesign --sign -`)은
빌드마다 코드 해시(cdhash)가 바뀌어 macOS Keychain이 "다른 앱"으로 보고, Claude Code 자격증명에
대한 "항상 허용" 권한이 무효화된다 → 업데이트할 때마다 keychain 접근 프롬프트가 다시 뜬다.

**고정된 자체 서명 인증서**로 서명하면 Designated Requirement가 일정하게 유지되어, 재빌드 후에도
keychain "항상 허용"이 그대로 유효하다 → 프롬프트가 사라진다.

- 비용: **무료** (자체 서명. 유료인 Developer ID는 외부 배포·공증용이라 로컬 전용엔 불필요)
- `build.sh`는 인증서가 있으면 자동 사용하고, **없으면 ad-hoc으로 폴백**한다(인증서 없어도 빌드는 동작).

## 1회 설정: 인증서 생성 (Keychain Access GUI, 약 1분)

1. **Keychain Access**(키체인 접근) 실행.
2. 메뉴 → **인증서 지원(Certificate Assistant)** → **인증서 생성(Create a Certificate…)**.
3. 입력:
   - **이름(Name)**: `ClaudeUsageMonitor Local`  ← `build.sh`의 `SIGN_IDENTITY`와 정확히 일치해야 함
   - **신원 유형(Identity Type)**: **자체 서명 루트(Self Signed Root)**
   - **인증서 유형(Certificate Type)**: **코드 서명(Code Signing)**
4. 생성 완료. (login 키체인에 저장됨)

> CLI 생성은 확장 필드(extendedKeyUsage=codeSigning) 설정이 까다로워 GUI를 권장한다.

확인:
```bash
security find-identity -v -p codesigning   # "ClaudeUsageMonitor Local" 이 목록에 보여야 함
```

## 적용

```bash
./build.sh        # 인증서가 있으면 자동으로 그것으로 서명 (로그에 "자체 서명 인증서 사용" 표기)
```

서명 주체 확인:
```bash
codesign -dvvv ~/Applications/ClaudeUsageMonitor.app 2>&1 | grep -E "Authority|Signature"
# Authority=ClaudeUsageMonitor Local  (ad-hoc 이면 "Signature=adhoc" 으로 나옴)
```

## 첫 실행 1회 허용

인증서로 서명한 빌드를 처음 실행하면 keychain 프롬프트가 한 번 뜬다 → **"항상 허용(Always Allow)"**.
이후 재빌드/업데이트에는 더 이상 뜨지 않는다(인증서 identity가 고정이므로).

## 다른 이름을 쓰고 싶다면

```bash
SIGN_IDENTITY="내 인증서 이름" ./build.sh
```

## 폴백 동작

인증서가 없으면 `build.sh`는 자동으로 ad-hoc(`-`) 서명으로 돌아간다. 빌드/실행은 정상이지만
업데이트마다 keychain 프롬프트가 다시 뜰 수 있다.
