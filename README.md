# DeployBar

fastlane 없이 여러 iOS 앱을 **메뉴바에서 관리·배포**하는 순수 Swift macOS 앱.
Node·로컬 서버 불필요. 앱을 열면 끝, 종료하면 잔류 프로세스 0.

## 열기 / 실행

```bash
open DeployBar.xcodeproj      # Xcode 에서 열고 ⌘R 로 실행
```

메뉴바 우측 상단에 🚀 아이콘이 뜬다. 클릭하면 앱 카드·상태·배포 버튼이 나온다.

> 첫 실행 시 서명은 Xcode 가 개발팀(QGAQ3AY3R3)으로 자동 처리한다.
> 다른 팀이면 프로젝트 설정 또는 `project.yml` 의 `DEVELOPMENT_TEAM` 을 바꾼다.

## 프로젝트 구조

```
DeployBar/
├── project.yml              # XcodeGen 설정 (프로젝트의 단일 소스)
├── DeployBar.xcodeproj      # xcodegen generate 로 생성
└── DeployBar/               # 소스
    ├── App.swift            # @main, MenuBarExtra + 로그/노트 창, --status 헤드리스
    ├── ContentView.swift    # 앱 카드 대시보드
    ├── LogView.swift        # 배포 로그(실시간 스트리밍)
    ├── NotesView.swift      # 릴리즈노트 편집
    ├── Store.swift          # 상태/작업 관리 (ObservableObject)
    ├── Config.swift         # ASC 자격증명 로드 (fastlane-shared/asc.env 재사용)
    ├── ASCClient.swift      # App Store Connect API (CryptoKit ES256 JWT + URLSession)
    ├── AppRepo.swift        # 앱 레지스트리 + 프로젝트 설정 자동 해석
    ├── Status.swift         # 개발중/준비완료/완료 판정
    ├── Deployer.swift       # 게이트→빌드번호+1→archive→export→altool
    ├── ReleaseNotes.swift   # git 커밋→AI 초안→ASC 업로드
    ├── GitInfo.swift · Shell.swift · Models.swift
    └── Assets.xcassets      # AppIcon (아이콘 넣을 자리)
```

프로젝트를 다시 생성하려면: `xcodegen generate`

## 설정 (`~/Library/Application Support/DeployBar/`)

- `apps.json` — 관리 앱 목록 `{ "apps": [ { "name": "…", "path": "…" } ] }`. 첫 실행 시 4개 앱으로 시드됨.
- `config.env` (선택) — `ANTHROPIC_API_KEY`(AI 릴리즈노트), ASC 키 재정의 등.

ASC 키는 `~/Documents/workspace/fastlane-shared/asc.env` 재사용,
`.p8` 은 `~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8` 에서 탐색.

## CLI 모드

```bash
DeployBar.app/Contents/MacOS/DeployBar --status   # UI 없이 상태만 출력
```

## 상태 뱃지

| 뱃지 | 조건 |
|---|---|
| ⚪️ 개발 중 | git 미커밋 변경 있음 |
| 🟡 배포 준비완료 | git clean + 로컬 버전 > App Store 라이브 버전 |
| 🟢 배포 완료 | 로컬 ≤ 라이브 |

## 한계

- App Store 심사 자동제출·스크린샷 자동화는 미포함 (추가 여지).
- 배포는 Xcode 가 있는 이 Mac 에서만 동작.
