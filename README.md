<div align="center">

<img src="docs/images/logo.png" alt="Claude Bar" width="120" />

# Claude Bar

**여러 Claude Code 세션을 한눈에 관리하는 macOS 메뉴바 앱**<br/>
<sub>A native macOS menu bar app to manage multiple Claude Code sessions at a glance</sub>

<p>
  <img alt="macOS 13+" src="https://img.shields.io/badge/macOS-13%2B-000000?logo=apple&logoColor=white" />
  <img alt="Swift 5.9" src="https://img.shields.io/badge/Swift-5.9-F05138?logo=swift&logoColor=white" />
  <img alt="SwiftUI" src="https://img.shields.io/badge/UI-SwiftUI%20MenuBarExtra-0A84FF" />
  <img alt="dependencies: none" src="https://img.shields.io/badge/dependencies-none-success" />
  <img alt="License: MIT" src="https://img.shields.io/badge/License-MIT-yellow" />
</p>

<img src="docs/images/sessions.png" alt="Claude Bar — Sessions" width="340" />

</div>

---

여러 터미널에서 동시에 Claude Code를 돌릴 때, **어떤 세션이 진행 중인지 · 어디서 돌고 있는지 · 컨텍스트가 얼마나 찼는지**를 메뉴바에서 바로 확인하고, 클릭 한 번으로 해당 터미널로 점프하거나 종료된 세션을 복구합니다. 100% 네이티브 Swift, 외부 의존성 없음, **읽기 전용**으로 `~/.claude`만 들여다봅니다.

## ✨ 주요 기능

- 🖥️ **세션 관리** — 실행 중 / 대기 / 종료 상태, 작업 위치(cwd), git 브랜치, 사용 모델을 한 목록에서.
- 📊 **세션별 컨텍스트 한도** — 각 세션의 컨텍스트 사용량을 바로 표시. `200K` / `1M` 윈도우를 자동 추론(설정의 `[1m]` 모델 기록 + 관측 최대 컨텍스트).
- ⚡ **클릭 → 점프 / 복구**
  - 실행 중 세션 클릭 → 해당 **터미널 탭을 맨 앞으로**.
  - 종료된 세션 클릭 → **새 터미널 창**에서 `cd` 후 `claude --resume`로 그 세션 복구.
- 📈 **사용량** — 로컬 트랜스크립트 기준 최근 5시간 / 7일 토큰 집계 + **일별 히스토그램**(로컬 기준) + 모델별 누적.
- 🧩 **MCP** — 전역 및 프로젝트별 MCP 서버 목록과 활성 여부.
- 👤 **계정** — 현재 연동된 Claude 계정(이메일·조직·역할).
- 🔔 **컨텍스트 경고** — 라이브 세션이 윈도우의 80%를 넘으면 메뉴바 아이콘이 경고로 전환.
- 🔒 **로컬 전용** — 네트워크 호출 없음. `~/.claude`의 파일만 읽습니다.

## 📸 스크린샷

<table>
  <tr>
    <td align="center"><b>세션</b></td>
    <td align="center"><b>사용량</b></td>
  </tr>
  <tr>
    <td><img src="docs/images/sessions.png" width="300" alt="Sessions" /></td>
    <td><img src="docs/images/usage.png" width="300" alt="Usage" /></td>
  </tr>
  <tr>
    <td align="center"><b>MCP</b></td>
    <td align="center"><b>계정</b></td>
  </tr>
  <tr>
    <td><img src="docs/images/mcp.png" width="300" alt="MCP" /></td>
    <td><img src="docs/images/account.png" width="300" alt="Account" /></td>
  </tr>
</table>

## 🚀 설치 및 실행

> 요구 환경: **macOS 13+** · **Swift 5.9+** (개발 환경: macOS 26 / Swift 6.3)

### `.app` 번들로 빌드 (권장)

```bash
git clone https://github.com/bolero2/ClaudeBar.git
cd ClaudeBar
./scripts/make-app.sh      # release 빌드 + Info.plist + ad-hoc 서명 → ClaudeBar.app
open ClaudeBar.app         # 메뉴바에서 실행 (Dock 미표시)
```

`ClaudeBar.app`을 `/Applications`로 드래그하면 일반 앱처럼 설치됩니다.
로그인 시 자동 실행은 **시스템 설정 → 일반 → 로그인 항목**에 추가하세요.

> 🔑 세션 클릭 → 터미널 활성화 기능은 최초 1회 **자동화(AppleScript) 권한** 허용이 필요합니다
> (시스템 설정 → 개인정보 보호 및 보안 → 자동화 → ClaudeBar → Terminal).

### 개발용 직접 실행

```bash
swift build -c release
.build/release/ClaudeBar             # 메뉴바 실행
.build/release/ClaudeBar --probe     # UI 없이 데이터 자가 점검 (콘솔 출력)
```

## 🛠️ 동작 원리

순수 **읽기 전용**. `~/.claude` 아래 파일과 표준 시스템 도구만 사용합니다.

| 영역 | 데이터 소스 |
| --- | --- |
| 세션 목록 · 위치 · 모델 | `~/.claude/projects/<dir>/<sessionId>.jsonl` (폴더명 + JSONL tail) |
| 실행 상태 · 터미널 점프 | `ps` / `lsof`로 라이브 `claude` 프로세스 탐지 → tty 매칭 AppleScript |
| 세션별 컨텍스트 한도 | JSONL `usage`(input/cache/output) + `~/.claude.json`의 `[1m]` 모델 기록 |
| 사용량 (5h · 7d · 일별) | JSONL `usage` 레코드 시간창 집계 (바이트 파서 + mtime 캐시) |
| MCP · 계정 | `~/.claude.json` (`mcpServers`, `projects[]`, `oauthAccount`) |

> **개인정보/보안**: 프로세스 환경변수에는 `CLAUDE_API_KEY` 등 비밀이 포함되므로, 터미널 식별에 필요한 `TERM_PROGRAM` / `TERM_SESSION_ID`만 추출하고 나머지는 저장·로깅하지 않습니다.

## 🧱 아키텍처

```
Sources/ClaudeBar/
├─ App.swift            진입점(@main) · MenuBarExtra · Dock 숨김
├─ AppState.swift       관찰 가능한 상태 (세션 5s / 사용량 60s 갱신)
├─ Diagnostics.swift    --probe 자가 점검 · --render 스크린샷
├─ Core/                ClaudePaths · Models · ConfigStore · Shell
├─ Services/            SessionScanner · ProcessProbe · TerminalActivator · UsageService
└─ Features/            RootView + 탭별 View · Format
```

- **의존성 0** — SwiftUI / AppKit / Charts(모두 OS 기본 프레임워크)만 사용.
- **성능** — 30일치 트랜스크립트 집계를 바이트 레벨 파싱 + 파일 캐시로 약 0.3초에 처리.

## 🗺️ 로드맵

- [ ] 공식 `/usage` rate-limit(5h · 7day %) 엔드포인트 연동
- [ ] MCP 전역 토글 (켜기/끄기)
- [ ] 멀티 계정 전환
- [ ] 컨텍스트 경고 임계치 사용자 설정

## 📄 라이선스

[MIT](LICENSE) © bolero2

<sub>Claude Bar는 Anthropic의 비공식 커뮤니티 프로젝트입니다.</sub>
