# CLAUDE.md — ClaudeDeck 인수인계

> 새 세션을 위한 전체 컨텍스트. 작업 전 이 문서를 먼저 읽을 것.

## 0. ⚡ 작업 원칙 (RULE — 최우선, 절대 위반 금지)

### 0-1. 정직성: 실측값만 보고
- 거짓말 금지. 추정·추론 금지. 상상 금지. 가정 금지.
- 허구·허위사실 기반 작업·보고·공유 금지.
- "~될 것 같아서, ~될 것이다" 같은 불확실한 사실에 근거하지 않기.
- 보고하는 모든 수치는 이 세션의 실행 로그에 있는 실측값만. 되면 된다고, 안 되면 안 된다고 보고.
- 예측이 꼭 필요하면 반드시 "미측정/추정"을 명시. "검증했다"는 말은 해당 축을 분리해 실제 확인한 경우에만.

### 0-2. 문서·보고서: 인간이 재현 가능한 실행 명령어 필수
- 문서·보고서 작성 시 "인간이 직접 재현 가능하게끔 관련 실행 명령어 기재"를 꼭, 반드시 할 것.
- 매 문서에 포함: ①전제(커밋 해시·이미지·데이터 경로) ②실행 명령(복사→실행 가능한 전체 커맨드) ③출력 해석 ④검증 앵커(정상 기준 수치).
- 명령어는 실제로 실행해 본 것만 기재. 에이전트 위임 시에도 이 요건을 프롬프트에 명시.

### 0-3. 이 문서의 갱신 (living document)
- 다음 시점에 **즉시 이 문서를 갱신**: 주요 결정 확정/번복, 실측으로 기존 기록 반증, 지뢰 발견, 스코프 변경, 마일스톤 완료.
- 틀린 기록은 지우지 말고 "정정(날짜): ~는 틀렸다, 실측 결과 ~" 형태로 남긴다(같은 실수 방지).
- 사용자가 "이건 중요하니까 규칙으로"라고 말한 것은 **그 자리에서 이 0장에 추가**한다.
- 세션/마일스톤 종료 시 §8(완료/미완료 TODO)을 현행화한다.

### 0-4. 보안 (프로젝트 시작 시 반드시 구체화할 것)
- 민감 데이터(개인정보·얼굴·내부 데이터) 외부 업로드 금지 — 대상 경로를 §5에 명시하고 .gitignore 처리.
- 토큰/키는 git config·추적파일에 저장 금지, 인라인 1회 사용, 노출 시 즉시 폐기·회전.
- **이 repo 구체화 (2026-07-22)**: 공개 OSS repo이므로 실제 세션 데이터가 찍힌 스크린샷 커밋 금지.
  - 루트의 모든 PNG(`/*.png` — error-*.png, toolbar-modal.png 등 디버그 스크린샷): gitignore 처리됨. 커밋 금지.
  - `docs/test/*-assets/` (QA 스크린샷 — 실제 세션/계정 정보 포함 가능): gitignore 처리됨. 커밋 금지.
  - `docs/images/`는 **MockData 기반 스크린샷만** 허용 (README에 "Screenshots use mock data" 명시). 실데이터 스크린샷을 여기에 넣지 말 것.
  - 런타임에 읽는 `~/.claude/` (transcript·OAuth 계정정보)와 Keychain OAuth 토큰 내용을 문서/로그/커밋에 옮겨 적지 말 것.

## 1. 프로젝트 개요
- **목표 한 문장**: 여러 Claude Code 세션의 상태·위치·컨텍스트를 macOS 메뉴바에서 한눈에 보고, 클릭 한 번으로 터미널 점프/복구/입력 주입까지 하는 네이티브 앱.
- **성격**: 개인 OSS 사이드 프로젝트 (발주처 없음, 이해관계자는 소유자 bolero2 본인).
- **요구사항 출처**: 본인의 실사용 필요. 마감·성능 요구치 등 특별한 제약 없음 (2026-07-22 인터뷰).
- **성공 기준**: 개인 만족 + GitHub 공개 배포(스타·사용자 확보).
- **배포**: GitHub Releases (`bolero2/ClaudeDeck`), 태그 푸시 시 CI 자동 빌드.

## 2. 저장소 구조
100% 네이티브 Swift / SwiftUI / SwiftPM, **외부 의존성 0**. 타깃 macOS 13+.

| 경로 | 내용 |
| --- | --- |
| `Sources/ClaudeDeck/App.swift` | `@main`. NSStatusItem+NSPopover, 전역 단축키(⌥⌘C), 대시보드 윈도우, CLI 플래그(`--probe`/`--render`/`--dashboard`/`--raise`/`--mcp`/`--ratelimit`/`--notify-test`) |
| `Sources/ClaudeDeck/AppState.swift` | `@MainActor` 단일 상태 저장소. 세션 5s · 사용량/한도 60s 폴링, 원격 병합, 주입/토글/알림 |
| `Sources/ClaudeDeck/Core/` | `Models`, `Settings`(UserDefaults), `ConfigStore`(`~/.claude.json`), `Loc`(한/영 i18n), `Shell`, `ClaudePaths`, `Pricing` |
| `Sources/ClaudeDeck/Services/` | `SessionScanner`(JSONL tail 파싱), `ProcessProbe`(ps/lsof), `TerminalActivator`(AppleScript), `UsageService`(바이트 파서), `OfficialUsageService`+`TokenManager`(OAuth), `RemoteScanner`+`SSHConfig`(원격 SSH 세션), `MCPService`, `HotKeyManager`, `NotificationService`, `StatusCache`, `UpdateService` |
| `Sources/ClaudeDeck/Features/` | `RootView`(팝오버 380×500), `DashboardView`, 탭 뷰(Session/Usage/MCP/Account/Settings), `PromptQueueView`, `Format` |
| `Sources/ClaudeDeck/Diagnostics.swift` | `--probe` 자가점검, `--render` 스크린샷 |
| `Sources/ClaudeDeck/MockData.swift` | 공개 스크린샷용 가상 데이터 |
| `scripts/make-app.sh` | release 빌드 → Info.plist → ad-hoc sign → `ClaudeDeck.app` 생성 |
| `scripts/claudedeck-statusline.sh` | 라이브 세션 컨텍스트 캐시용 statusLine 헬퍼 |
| `docs/` | `HANDOFF.md`(세션 인수인계), `change-log/`(일자별), `test/`(QA 리포트), `images/`(mock 스크린샷) |
| `Package.swift` | swift-tools 5.9, 단일 executableTarget |

## 3. 핵심 결정 & 근거
- **외부 의존성 0의 네이티브 Swift** (2026-06-12): 배포 단순화(zip 하나), 빌드 재현성. SwiftPM 단일 타깃.
- **읽기 전용 원칙 + 명시적 예외** (2026-06-12~13): 기본은 `~/.claude` 파일 읽기만. 예외 3종 — MCP 토글(`~/.claude.json` 원자적 수정), 터미널 입력 주입(`/compact`·`/clear`·예약 큐), 공식 사용량 조회(Keychain OAuth).
- **statusLine 캐시 우회** (2026-06-13~15, 실측 근거): Claude Code 2.1.x는 라이브 세션 transcript를 디스크에 안 쓰고 정상 종료 시에만 flush함을 실측 확인(활발한 세션 2분간 `find -mmin -2` 0건). 라이브 컨텍스트/모델은 statusLine 헬퍼가 캐시한 값을 읽음.
- **원격 SSH 세션은 무설치 인라인 프로브** (2026-06-15): 원격에 아무것도 설치하지 않고 `ssh <host> python3 -`로 프로브를 stdin 주입, ControlMaster로 지연 축소. 상세: `docs/change-log/2026-06-15.md`.
- **repo 이름 변경 보류** (2026-06-13): 동명 repo(사용량 전용 앱) 존재. 변경 시 번들 ID(`com.claudedeck.app`)·README·릴리즈 영향 → 후보 논의 중.

## 4. 실행 방법
전제: 커밋 `10fd5b3`, macOS 26.5 / Swift 6.3 (arm64). 아래 명령은 2026-07-22 이 세션에서 실행 확인.

```bash
swift build -c release        # Build complete! (증분 0.13s — 클린 빌드는 미측정)
```

과거 세션에서 실행·검증된 명령 (README·change-log 기록):

```bash
./scripts/make-app.sh                  # release 빌드 + ad-hoc sign → ClaudeDeck.app
open ClaudeDeck.app                    # 메뉴바 실행 (Dock 아이콘 없음)
.build/release/ClaudeDeck --probe      # headless 자가점검 (콘솔 출력)
```

테스트: 별도 테스트 타깃 없음. QA는 `--probe`/`--render` + 수동 시나리오 → `docs/test/` 리포트로 기록.

## 5. 데이터 / 산출물 / 보안

| 경로 | gitignore | 비고 |
| --- | --- | --- |
| 루트 `/*.png` (error-*.png, toolbar-modal.png 등) | ✅ | ⚠️ 실제 세션 데이터 스크린샷 — 커밋 금지 |
| `docs/test/*-assets/` | ✅ | ⚠️ QA 스크린샷, 실세션/계정 정보 포함 가능 — 커밋 금지 |
| `docs/images/` | 추적됨 | MockData 기반 스크린샷만 허용 |
| `.build/`, `*.app/`, `ClaudeDeck.zip` | ✅ | 빌드 산출물 |
| `~/.claude/` · Keychain OAuth 토큰 | (repo 외부) | ⚠️ 런타임 읽기 대상. 내용을 문서/로그에 옮겨 적지 말 것 |

## 6. 외부 문서 맵
외부 문서 없음(Confluence/Jira/Notion 미사용, 2026-07-22 인터뷰) — repo 내 문서가 전부:
- `README.md` / `README-kr.md` — 기능·설치·동작 원리
- `docs/HANDOFF.md` — 세션 간 인수인계 (최신화: 2026-06-13, 이 문서와 역할 중복 → 이후 이 CLAUDE.md로 일원화 권장)
- `docs/change-log/` — 일자별 상세 변경 내역 (인덱스: README.md)
- `docs/test/` — QA 리포트

## 7. ⚠️ 지뢰 / 주의사항
- **Claude Code 2.1.x는 라이브 transcript를 flush하지 않음** (2026-06-15 실측): Command+Q 강제 종료 시 대화가 영구 유실되고 `ai-title` 스텁(117B)만 남음 → `--resume` 불가. 라이브 세션 데이터를 JSONL에서 직접 읽으려 하지 말 것(statusLine 캐시 사용).
- **resume 시 1M 컨텍스트 복원 불확실**: `--model '<base>[1m]'`을 명시 전달하지만 Claude Code가 `--resume`에서 이를 존중하는지 문서/실동작이 어긋남 → 실기기 확인 필요. 권한 모드 복원은 확실.
- **알림 아이콘**: macOS는 Launch Services 등록 아이콘 사용 → `/Applications` 설치 후 실행해야 로고 표시(임의 경로 ad-hoc 실행 시 제네릭 아이콘).
- **첫 실행 권한**: 터미널 점프는 Automation(AppleScript) 권한, 공식 사용량은 Keychain 접근 허용 필요.
- **ad-hoc 서명**: notarize 안 됨 → 배포 zip은 `xattr -dr com.apple.quarantine` 안내 필수.

## 8. 완료 / 미완료(TODO)
완료 (상세: `docs/change-log/`):
- v1 4탭(세션·사용량·MCP·계정) + 설정, 세션 상태/활동/권한모드/컨텍스트(200K·1M 자동 판정), 터미널 점프/resume, 알림, 전역 단축키, OAuth 자동 refresh (06-12)
- `/compact`·`/clear` 주입 + 템플릿, 예약 프롬프트 큐(화면 감시 자동 주입), 대시보드 윈도우, 앱 아이콘, CI 릴리즈 (06-13)
- 원격(SSH) 세션 표시·접속(무설치 인라인 프로브), 강제 종료 세션 복구불가 감지+폴백, 안전 종료(/exit), 라이브 BYPASS/1M 표시 (06-15)

미완료 / TODO:
- 같은 호스트 다중 SSH 세션의 정확한 탭 매칭(현재 호스트 단위), 원격 슬래시 주입, IP 직접 접속 시 별칭 매칭 (06-15 범위 밖 항목)
- resume 1M 복원 실기기 검증 (§7)
- repo 이름 변경 여부 결정 (§3)
- `docs/test/2026-06-15.md` + assets, `.claude/`, 이 CLAUDE.md가 미커밋 상태 → 정리 후 커밋

## 9. 환경
- macOS 26.5 (Build 25F71), arm64 (Apple Silicon)
- Swift 6.3 (swiftlang-6.3.0.123.5) / swift-tools 5.9 / 배포 타깃 macOS 13+
- git: `bolero2 <41134624+bolero2@users.noreply.github.com>`, 원격 `https://github.com/bolero2/ClaudeDeck.git`, 기본 브랜치 `main`
- GPU 불필요. Xcode 프로젝트 없음(SwiftPM 전용, `*.xcodeproj`는 gitignore)
