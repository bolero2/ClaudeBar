import Foundation

/// Lightweight localization. Korean source strings act as keys; English is
/// looked up in a table. The current language is read from UserDefaults so this
/// works from any thread/actor. Views rebuild on language change because the
/// root view is keyed by the language (see `ClaudeBarApp`).
func L(_ ko: String) -> String {
    isEnglish ? (Loc.en[ko] ?? ko) : ko
}

var isEnglish: Bool {
    (UserDefaults.standard.string(forKey: AppSettings.Key.language) ?? Loc.systemDefault) == "en"
}

enum Loc {
    /// Default language from the system locale (used until the user picks one).
    static var systemDefault: String {
        (Locale.current.language.languageCode?.identifier == "ko") ? "ko" : "en"
    }

    static let en: [String: String] = [
        // Tabs / chrome
        "세션": "Sessions", "사용량": "Usage", "계정": "Account", "설정": "Settings",
        "새로고침": "Refresh", "끝내기": "Quit",
        "새 세션 시작 (디렉토리 선택)": "New session (choose directory)",
        "컨텍스트": "Context", "업데이트": "Updated",

        // Sessions
        "실행 중": "Running", "최근 세션": "Recent", "즐겨찾기": "Favorites",
        "즐겨찾기 추가": "Add to favorites", "즐겨찾기 제거": "Remove from favorites",
        "전체": "All", "종료": "Ended", "프로젝트 검색": "Search projects",
        "세션을 찾을 수 없습니다.": "No sessions found.",
        "검색 결과가 없습니다.": "No results.",
        "터미널 앞으로": "Bring terminal to front",
        "세션 종료 (kill)": "Kill session",
        "새 터미널에서 복구": "Resume in a new terminal",
        "Finder에서 열기": "Reveal in Finder", "경로 복사": "Copy path",
        "클릭: 해당 터미널 탭을 앞으로": "Click: bring its terminal tab to front",
        "클릭: 새 터미널에서 이 세션 복구 (claude --resume)":
            "Click: resume in a new terminal (claude --resume)",

        // Status / modes
        "진행 중": "Working", "대기": "Waiting", "종료됨": "Ended",

        // Usage
        "사용 한도": "Usage limits", "5시간 세션": "5-hour session",
        "7일 (전체)": "7-day (all)", "7일 (Sonnet)": "7-day (Sonnet)",
        "7일 (Opus)": "7-day (Opus)", "사용": "used", "남음": "left", "리셋": "reset",
        "최근 5시간": "Last 5h", "최근 7일": "Last 7d",
        "입력": "Input", "출력": "Output", "캐시읽기": "Cache read", "캐시생성": "Cache write",
        "오늘": "Today", "토큰": "tokens", "프로젝트별 (7일)": "By project (7d)",
        "모델별 누적": "By model", "사용량을 집계하는 중…": "Aggregating usage…",
        "Top 모델": "Top model",
        "공식 사용 한도를 가져오지 못했습니다 · 아래는 로컬 집계":
            "Couldn't fetch official limits · local estimate below",
        "위는 공식 한도 · 아래 토큰/비용은 로컬 트랜스크립트 기반(비용은 API 단가 환산 추정)":
            "Above: official limits · below: local transcript estimate (cost at API rates)",

        // MCP
        "전역 MCP": "Global MCP", "프로젝트별 MCP": "Project MCP",
        "전역 MCP 서버가 없습니다.": "No global MCP servers.",
        "항상 켜짐": "Always on", "클릭: 끄기": "Click to turn off", "클릭: 켜기": "Click to turn on",
        "토글은 새로 시작하는 세션부터 적용됩니다. (실행 중 세션은 영향 없음)":
            "Toggles apply to newly started sessions (running sessions are unaffected).",

        // Account
        "활성": "Active", "조직": "Organization", "역할": "Role", "결제": "Billing",
        "연동된 계정이 없습니다.": "No linked account.",
        "멀티 계정 전환은 다음 버전에서 지원됩니다.": "Multi-account switching is coming soon.",

        // Settings
        "알림": "Notifications", "입력 대기 알림": "Waiting-for-input alerts",
        "컨텍스트 임박 알림": "Context-limit alerts", "사용 한도 임박 알림": "Usage-limit alerts",
        "임계치": "Thresholds", "컨텍스트 경고": "Context warning", "사용 한도 경고": "Usage warning",
        "터미널": "Terminal", "새 세션 / 복구에 사용": "For new sessions / resume",
        "자동": "Auto", "시스템": "System", "로그인 시 자동 실행": "Launch at login",
        "언어": "Language", "새 세션": "New session",
        "새 세션 · 권한 건너뛰기": "New session · skip permissions",
        "Claude Code를 시작할 디렉토리를 선택하세요": "Choose a directory to start Claude Code in",

        // Notifications
        "입력 대기 중": "Waiting for input", "컨텍스트 한도 임박": "Context limit approaching",
        "사용 한도 임박": "Usage limit approaching",
        "세션이 입력을 기다립니다.": "session is waiting for input.",
    ]
}
