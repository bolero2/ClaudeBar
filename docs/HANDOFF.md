# 작업 인수인계 (Handoff)

> 다른 세션에서 작업을 이어가기 위한 컨텍스트 요약. 최신화 시점: 2026-06-13.

## 프로젝트 개요

- macOS 메뉴바 네이티브 앱 (Swift / SwiftUI / SwiftPM, **외부 의존성 0**). 여러 Claude Code 세션을 한곳에서 관리.
- 핵심 가치: 세션 상태(진행/대기/종료)·위치·모델·컨텍스트를 메뉴바에서 한눈에, 클릭 한 번으로 터미널 점프/세션 복구.
- 동작 범위: 대부분 **읽기 전용**(`~/.claude` 파일). 예외 — MCP 토글(`~/.claude.json` 원자적 수정), `/compact`·`/clear` 터미널 주입, 공식 사용량(Keychain OAuth).
- 저장소: `bolero2/ClaudeBar` (※ **이름 변경 검토 중** — 동명 repo 존재, 아래 "미해결" 참고).

## 아키텍처 (`Sources/ClaudeBar/`)

- **App.swift** — `@main`, `NSStatusItem`+`NSPopover`, 전역 단축키(⌥⌘C), 알림 클릭 핸들링, 대시보드 윈도우(`.regular`↔`.accessory` 전환), Dock 아이콘. CLI 플래그: `--probe`/`--render`/`--dashboard`/`--raise`/`--mcp`/`--ratelimit`/`--notify-test`.
- **AppState.swift** — `@MainActor` 단일 상태 저장소. 세션 5s · 사용량/한도 60s 주기. `compact`/`clearSession`/`sendSlashCommand`, `activate`(resume 플래그 재구성), MCP 토글, 알림 평가, `appIcon`.
- **Core/** — `Models`, `Settings`(UserDefaults), `ConfigStore`(`~/.claude.json`), `Loc`(한/영 i18n), `Shell`, `ClaudePaths`, `Pricing`.
- **Services/** — `SessionScanner`, `ProcessProbe`(ps/lsof), `TerminalActivator`(AppleScript), `UsageService`(바이트 파서), `OfficialUsageService`, `TokenManager`(OAuth refresh), `MCPService`, `HotKeyManager`(Carbon), `NotificationService`.
- **Features/** — `RootView`(팝오버 380×500), `DashboardView`(풀 윈도우), 탭 뷰 5종, `Format`.
- **Diagnostics.swift** — `--probe` 자가점검, `--render` 스크린샷. **MockData.swift** — 공개 스크린샷용 가상 데이터.

## 완료 기능

- 세션 목록·상태·실시간 활동·권한 모드 뱃지(PLAN/ACCEPT/BYPASS)·검색/필터/즐겨찾기·세션별 컨텍스트(200K·1M 자동 추론).
- 클릭→터미널 점프(라이브) / 새 창 `claude --resume`(종료).
- `/compact`(기본·저장 템플릿·직접입력)·`/clear` 터미널 주입(대기 상태에서 동작).
- 대시보드 윈도우(하이브리드: 메뉴바 + 풀 윈도우, 같은 AppState 공유).
- 사용량(공식 한도 5h/7d + 리셋시간, 비용 추정, 프로젝트별, 일별 히스토그램), MCP on/off, 계정, 설정(언어/알림/임계치/터미널/로그인 시작), 알림(클릭→세션 점프), 전역 단축키, OAuth 자동 refresh.
- 앱 아이콘(로고 `.icns`), 배포(GitHub Releases + 태그 푸시 시 CI 자동 빌드).

## 이번 세션(2026-06-13)에 한 일

- `/compact`·`/clear` + 템플릿, 대시보드 윈도우, 앱 아이콘 번들, **resume 시 1M·권한 모드 복원 수정**, NSAlert 아이콘 수정.
- 전체 QA 리포트: `docs/test/2026-06-13.md` (13/13 통과).
- 상세 변경 내역: `docs/change-log/2026-06-13.md`.

## 미해결 / 주의사항

- **resume의 1M 복원 불확실**: `--model '<base>[1m]'`을 명시 전달하지만, Claude Code가 `--resume`에서 이 플래그를 존중하는지 문서/실동작이 어긋남 → 실기기 확인 필요. 권한 모드 복원은 확실.
- **알림 아이콘**: macOS는 Launch Services 등록 아이콘을 사용 → 앱을 `/Applications`에 설치/실행해야 로고가 표시됨(임의 경로 ad-hoc 실행 시 제네릭).
- **이름 변경 보류**: 'ClaudeBar' 동명 repo(사용량 전용 앱) 존재. 본 앱은 세션관리/compact/MCP 등 올라운더 지향 → 신규 네이밍 후보 논의 중. 변경 시 repo명·번들 ID(`com.claudebar.app`)·README·스크린샷·릴리즈 영향.
- **위젯 보류**: App Groups용 Apple Developer 서명 필요(ad-hoc 불가).
- **멀티 계정 전환**: 로드맵.

## 빌드 / 실행 / 검증

```bash
swift build                                   # 디버그 빌드
.build/release/ClaudeBar --probe              # 헤드리스 자가점검(실데이터)
./scripts/make-app.sh                         # ClaudeBar.app (release + ad-hoc 서명)
ClaudeBar --render <tab|dashboard> out.png mock <en|ko>   # 목업 스크린샷
git tag vX.Y.Z && git push origin vX.Y.Z      # 릴리즈 CI 트리거
```

GUI 앱이라 테스트 타깃 없음 — 순수 로직은 독립 Swift 하니스, 터미널/주입은 임시 터미널 격리 테스트, 렌더는 mock ImageRenderer로 검증.

## 작업 규칙 (반드시 준수)

- **공개 산출물 금지사항**: 스크린샷·커밋·문서·README에는 **목업 데이터만**. 유지보수자의 실제 계정/세션/경로/이메일/실명을 절대 포함하지 말 것. **공개 푸시 전 실제 식별자 스캔 필수.**
- 의미 있는 작업 후 `docs/change-log/YYYY-MM-DD.md` 작성 + `docs/change-log/README.md` 인덱스 갱신.
- 푸시 시 GitHub 계정 전환 필요(저장소 소유자 계정으로 push 후 기본 계정 원복).
