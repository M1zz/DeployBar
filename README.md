# DeployBar

fastlane 없이 여러 iOS/macOS 앱을 **메뉴바에서 관리·배포**하는 순수 Swift macOS 앱.
Node·로컬 서버 불필요. 앱을 열면 끝, 종료하면 잔류 프로세스 0.

다국어 앱은 **버튼 하나로** 게이트 → 빌드 → 업로드 → *지원 언어 전부의* 릴리즈노트까지 끝난다.

## 열기 / 실행

```bash
open DeployBar.xcodeproj      # Xcode 에서 열고 ⌘R 로 실행
```

메뉴바 우측 상단에 🚀 아이콘이 뜬다. 클릭하면 앱 카드·상태·배포 버튼이 나온다.

> 첫 실행 시 서명은 Xcode 가 개발팀(QGAQ3AY3R3)으로 자동 처리한다.
> 다른 팀이면 프로젝트 설정 또는 `project.yml` 의 `DEVELOPMENT_TEAM` 을 바꾼다.

---

## 화면 읽는 법

기억할 게 없도록, **지금 뭐가 필요한지를 화면이 먼저 말한다.** 헤더의 `?` 버튼이 앱 안 사용법이다.

```
🟢 3 배포 가능   ⚠️ 12 막힘   ✨ 8 설정 필요           31개 앱   ← 상단 요약
────────────────────────────────────────────────────────
● 클립키보드   배포 준비완료                            [#] [배포▾] [📄] [⋯]
  v5.0.5(1) · 스토어 v5.0.4
  ⚠️ App Store 심사 대기 · 권장 2건 더        ▾        ← 누르면 펼쳐짐
     ✅ 올릴 변경 있음 — 마지막 배포 이후 커밋 12개
     ⚠️ 번역 구멍 2373건 — 인도네시아어 2361, 영어 8
     ⚠️ 언어 목록 미선언 — ko, en, id …          [자동 설정]
```

- **이름 아래 한 줄** = 지금 할 일. 누르면 항목별로 펼쳐진다.
- **`[자동 설정]`** = 버튼 한 번으로 끝나는 것 (deploy.env·검사 스크립트 생성, 경로 정정)
- **`→` 로 시작하는 주황색 줄** = 사람이 해야 하는 것 (커밋, 번역 채우기 …)
- **`[배포]` 가 잠겨 있으면** 마우스를 올려 보면 이유가 뜬다. 막는 항목은 ❌ 로 표시된다.

배포를 막는 것과 권장에 그치는 것을 구분한다.

| ❌ 배포가 잠김 | ⚠️ 배포는 되지만 권장 |
|---|---|
| 커밋되지 않은 변경 | 배포 전 검사 스크립트 없음 |
| 올릴 변경 없음 / 로컬이 스토어보다 낮음 | 배포 설정(deploy.env) 없음 |
| 버전 파일 경로 오류 | 언어 목록 미선언 |
| App Store 앱 확인 실패 | 번역 구멍 (게이트가 `warn` 일 때) |
| 번역 구멍 (게이트가 `strict` 일 때) | 심사 대기 중 재업로드 |

---

## 앱 쪽 규칙 — 관리 대상 앱이 갖춰야 할 것

`~/Documents/workspace/Auto/` 아래의 폴더 중 최상단에 `.xcodeproj`/`.xcworkspace` 가
있으면 자동으로 관리 대상이 된다. 그 위에 아래 규칙을 지키면 배포가 자동화된다.

| # | 규칙 | 없으면 | 강제성 |
|---|---|---|---|
| 1 | 앱 폴더 최상단에 Xcode 프로젝트 **하나** | 발견 자체가 안 되거나, 둘이면 엉뚱한 쪽을 씀 | **필수** |
| 2 | `deploy.env` — 배포 설정 | 폴더 이름을 scheme 으로 추정 (틀리면 실패) | 권장 |
| 3 | `Version.xcconfig` 에 `MARKETING_VERSION` + `CURRENT_PROJECT_VERSION` | `project.pbxproj` 를 정규식으로 직접 수정 (타겟이 여러 개면 위험) | 권장 |
| 4 | `scripts/predeploy.sh` — 배포 전 게이트 | 테스트 없이 배포됨 | 권장 |
| 5 | `.xcstrings` 의 모든 `LOCALES` 언어가 빠짐없이 번역 | 외국 사용자에게 한국어가 노출됨 | `LOCALIZATION_GATE` 에 따름 |

### `deploy.env` — 이 파일이 앱의 배포 규칙 전부

```sh
# 필수: archive 할 scheme
SCHEME=Rereminder

# 플랫폼 (ios | macos). 자동 판별이 맞으면 지워도 된다.
# 멀티플랫폼 타겟은 SDKROOT 만으로 구분되지 않아 명시해 두는 편이 안전하다.
PLATFORM=ios

# 권장: 버전·빌드번호의 단일 소스 (앱 폴더 기준 상대경로)
VERSION_XCCONFIG=Config/Version.xcconfig

# 권장: 배포 전 게이트. 실패하면 아카이브를 만들지 않는다.
PREDEPLOY_SCRIPT=scripts/predeploy.sh

# 다국어: App Store 에 등록한 언어. 이 목록이 곧
#   (1) 다국어 게이트의 검사 기준이고
#   (2) 릴리즈노트를 만들 언어다.
LOCALES=ko,en,ja

# strict — 번역 구멍이 하나라도 있으면 배포 중단 (다국어 앱 권장)
# warn   — 로그에만 남기고 진행 (기본값)
# off    — 검사 안 함
LOCALIZATION_GATE=strict
```

기존 앱의 `fastlane/.env` 도 그대로 읽는다(하위호환). 둘 다 있으면 `deploy.env` 가 이긴다.

### 자동 설정 — 규칙을 손으로 안 맞춰도 된다

체크리스트의 `[자동 설정]`, 카드의 `⋯ › 배포 설정 자동 정리`, 하단의 `전체 자동 설정` 이 모두 같은 일을 한다.

- `deploy.env` 가 없으면 그 앱에 맞게 만든다 (`fastlane/.env` 값이 있으면 옮겨 온다)
- 이미 있으면 **주석과 순서를 그대로 두고** 빠진 키만 채운다
- `VERSION_XCCONFIG` 경로가 틀렸으면 실제 위치를 찾아 고친다
- `scripts/predeploy.sh` 가 없으면 그 앱의 scheme·플랫폼에 맞춰 만든다
- 번역이 이미 완벽한 앱만 `LOCALIZATION_GATE=strict` 로 시작한다
  (구멍이 있는 앱을 갑자기 strict 로 바꾸면 다음 배포가 통째로 막혀 놀라게 된다)

사람이 쓴 값은 덮어쓰지 않고, 여러 번 눌러도 결과가 같다.
`⋯ › 설정 자세히 점검` 또는 CLI `--doctor` 로 규칙 하나하나를 볼 수 있다.

> 다국어 검사는 DeployBar 안에 내장돼 있으므로, 앱마다 `check_localization.py` 를 둘 필요가 없다.
> `predeploy.sh` 에는 그 앱만의 검사(테스트·금지 패턴)만 남기면 된다.

---

## 다국어 배포가 도는 방식

### 1. 배포 전 — 다국어 게이트

앱 폴더의 모든 `.xcstrings` 를 읽어 세 가지를 잡는다.

| 잡는 것 | 왜 |
|---|---|
| **미번역** — `LOCALES` 의 언어인데 값이 없음 | 소스 언어 문자열이 그대로 노출됨 |
| **미완료** — state 가 `new`/`stale`/`needs_review` | 원문이 바뀐 뒤 번역이 안 따라옴 |
| **한글 혼입** — 한국어 아닌 언어 값에 한글 | 영어 사용자가 한글을 봄 |

복수형·기기별 `variations` 안까지 본다. 소스 언어와 `shouldTranslate: false` 는 건너뛴다.
`LOCALIZATION_GATE=strict` 면 하나라도 있을 때 아카이브를 만들지 않는다.

### 2. 배포 후 — 언어별 릴리즈노트 자동 반영

```
git pull → 다국어 게이트 → predeploy.sh → 버전/빌드번호 → archive → export → altool
                                                                              ↓
        App Store 의 지원 언어 조회 → 언어별 릴리즈노트 생성 → 전 언어 업로드
```

문구를 만드는 순서:

1. **AI** — `config.env` 에 `ANTHROPIC_API_KEY` 가 있으면, 커밋 로그로 **한 번의 호출에** 모든 언어를
   현지화해 만든다(번역이 아니라 언어권별로 자연스럽게).
2. **온디바이스 번역** — 키가 없거나 일부 언어가 비면 Apple Translation(macOS 15+)으로 한국어 원문에서 채운다.
   같은 언어의 지역 변형(`en-US`/`en-GB`)은 한 번만 번역해 재사용한다.
3. **직접 입력** — 온디바이스 번역이 지원하지 않는 언어는 비워 두고 로그에 남긴다.
   `릴리즈노트` 창에서 언어별 칸에 직접 넣으면 된다. **빈 칸은 업로드하지 않으므로 기존 문구가 유지된다.**

`릴리즈노트` 창은 App Store 가 요구하는 언어 수만큼 편집칸을 만든다.
`빈 언어 채우기` 버튼으로 한국어 원문에서 나머지를 한 번에 번역한다.

---

## 프로젝트 구조

```
DeployBar/
├── project.yml              # XcodeGen 설정 (프로젝트의 단일 소스)
├── DeployBar.xcodeproj      # xcodegen generate 로 생성
└── DeployBar/               # 소스
    ├── App.swift            # @main, MenuBarExtra + 로그/노트 창, CLI 모드
    ├── ContentView.swift    # 앱 카드 대시보드
    ├── LogView.swift        # 배포 로그(실시간 스트리밍) + 온디바이스 번역 실행 지점
    ├── NotesView.swift      # 언어별 릴리즈노트 편집
    ├── Store.swift          # 상태/작업 관리 (ObservableObject)
    ├── Config.swift         # ASC 자격증명 로드 (fastlane-shared/asc.env 재사용)
    ├── ASCClient.swift      # App Store Connect API (CryptoKit ES256 JWT + URLSession)
    ├── AppRepo.swift        # 앱 레지스트리 + deploy.env 해석 + 플랫폼 판별
    ├── Locales.swift        # ASC 로케일 ↔ 표시이름 ↔ 번역 언어 매핑
    ├── Localization.swift   # .xcstrings 다국어 게이트
    ├── Readiness.swift      # "지금 배포하려면 뭐가 필요한가" 체크리스트
    ├── Scaffold.swift       # 배포 규칙 점검(doctor) + 자동 설정
    ├── GuideView.swift      # 앱 안 사용법
    ├── Status.swift         # 개발중/준비완료/완료 판정
    ├── Deployer.swift       # 게이트→빌드번호+1→archive→export→altool
    ├── ReleaseNotes.swift   # git 커밋→언어별 초안→ASC 업로드
    ├── GitInfo.swift · Shell.swift · Models.swift
    └── Assets.xcassets      # AppIcon
```

프로젝트를 다시 생성하려면: `xcodegen generate`

## 설정 (`~/Library/Application Support/DeployBar/`)

- `apps.json` — 관리 앱 목록 (폴더 자동 발견 결과 + 수동 등록분)
- `hidden.json` — 관리에서 잠시 뺀 앱
- `config.env` (선택) — `ANTHROPIC_API_KEY`(AI 릴리즈노트), `ANTHROPIC_MODEL`, ASC 키 재정의 등

ASC 키는 `~/Documents/workspace/fastlane-shared/asc.env` 재사용,
`.p8` 은 `~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8` 에서 탐색.

## CLI 모드

UI 없이 확인만 할 때 쓴다.

```bash
D=DeployBar.app/Contents/MacOS/DeployBar
$D --status              # 앱별 상태 + "지금 배포하려면 뭐가 필요한지" 체크리스트
$D --doctor              # 전체 앱의 배포 규칙 점검
$D --doctor 두번알림      # 앱 하나만
$D --template 두번알림    # 설치될 deploy.env·predeploy.sh 미리보기 (파일 안 씀)
$D --template 두번알림 --write   # 실제로 설정 (UI 의 [자동 설정] 과 동일)
$D --notes 두번알림       # 언어별 릴리즈노트 초안 미리보기 (업로드 안 함)
```

## 상태 뱃지

| 뱃지 | 조건 |
|---|---|
| ⚪️ 개발 중 | git 미커밋 변경 있음 |
| 🟡 배포 준비완료 | git clean + (로컬 버전 > 스토어 버전 \| 빌드 앞섬 \| 배포 태그 이후 새 커밋) |
| 🟢 배포 완료 | 로컬 ≤ 라이브 |

심사가 진행 중이면 그 상태(심사 대기·심사 중·거부됨 …)를 우선 표시한다.

## 한계

- App Store 심사 자동제출·스크린샷 자동화는 미포함.
- 릴리즈노트 반영은 **편집 가능한 버전**(제출 준비/거부됨)이 있을 때만 가능하다.
  업로드 직후 ASC 가 새 버전을 만들기 전이면 보류되고, 나중에 `릴리즈노트` 창에서 적용하면 된다.
- 배포는 Xcode 가 있는 이 Mac 에서만 동작.
