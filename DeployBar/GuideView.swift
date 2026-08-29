import SwiftUI

// 앱 안에서 보는 사용법. README 를 열지 않아도 "뭘 누르면 뭐가 되는지" 를 알 수 있게 한다.
struct GuideView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {

                Section(title: "1. 배포 한 번에 되는 순서", icon: "play.circle.fill") {
                    Steps([
                        ("코드를 커밋한다", "커밋 안 된 변경이 있으면 배포 버튼이 잠깁니다 — 작업 중인 코드가 섞이는 사고를 막습니다."),
                        ("카드의 [배포] 를 누른다", "git pull → 다국어 검사 → 배포 전 검사 → 빌드번호 +1 → archive → App Store 업로드 까지 자동입니다."),
                        ("릴리즈노트가 자동으로 올라간다", "App Store 에 등록된 언어를 조회해 언어별 문구를 만들어 전부 반영합니다."),
                    ])
                    Note("같은 버전에 새 빌드만 올리려면 [배포] 를 그냥 누르고, 버전을 올리려면 [배포 ▾] 에서 패치·마이너·메이저를 고릅니다.")
                }

                Section(title: "2. 배포 순서 정하기", icon: "arrow.up.arrow.down") {
                    Text("""
                    헤더의 ↑↓ 버튼을 누르면 순서 편집 모드가 됩니다. 드래그하거나 ▲▼ 로 옮기면 되고, \
                    바꾸는 즉시 저장됩니다. [전체 배포] 는 이 순서대로 위에서부터 진행합니다.
                    """)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    Note("카드의 '전체 배포 N번째' 배지가 이번에 몇 번째로 나갈지를 알려 줍니다. 막힌 앱은 번호를 받지 않습니다 — 순서에서 자동으로 빠집니다.")
                }

                Section(title: "3. 카드에 뜨는 색이 뜻하는 것", icon: "circle.fill") {
                    Row(color: .gray, title: "개발 중", detail: "커밋 안 된 변경이 있음 → 커밋하면 풀립니다")
                    Row(color: .orange, title: "배포 준비완료", detail: "올릴 것이 있고 커밋도 끝난 상태")
                    Row(color: .green, title: "배포 완료", detail: "로컬이 스토어와 같음 → 버전을 올리거나 새 커밋을 하세요")
                    Row(color: .blue, title: "심사 대기 / 심사 중 …", detail: "App Store 심사가 진행 중이면 그 상태를 먼저 보여 줍니다")
                    Note("이름 아래 한 줄이 '지금 할 일' 입니다. 누르면 항목별로 펼쳐집니다.")
                }

                Section(title: "4. 배포가 막히는 이유와 해결", icon: "exclamationmark.triangle.fill") {
                    Row(color: .orange, title: "커밋되지 않은 변경", detail: "커밋하면 됩니다")
                    Row(color: .orange, title: "올릴 변경 없음", detail: "[버전 올리기] 를 누르거나 새 커밋을 하세요")
                    Row(color: .orange, title: "버전 파일 경로 오류", detail: "[자동 설정] 이 실제 경로로 고쳐 줍니다")
                    Row(color: .orange, title: "번역 구멍", detail: "Xcode 에서 String Catalog 를 열어 빈 칸을 채우세요")
                    Row(color: .orange, title: "App Store 앱 확인 실패", detail: "App Store Connect 에 그 번들 ID 로 앱이 있어야 합니다")
                }

                Section(title: "5. 새 앱을 배포 대상으로 만들기", icon: "wand.and.stars") {
                    Steps([
                        ("앱 폴더를 ~/Documents/workspace/Auto/ 아래에 둔다", "폴더 최상단에 .xcodeproj 가 있으면 자동으로 목록에 나타납니다."),
                        ("[전체 자동 설정] 또는 카드의 [자동 설정] 을 누른다", "deploy.env 와 scripts/predeploy.sh 를 그 앱에 맞게 만들어 줍니다. 이미 있는 파일은 건드리지 않습니다."),
                        ("배포 전 검사를 손본다", "scripts/predeploy.sh 에 그 앱의 테스트를 넣습니다. 테스트 타겟이 없으면 그 단계를 지우세요."),
                    ])
                    Note("다국어 검사는 DeployBar 안에 들어 있어서, 앱마다 검사 스크립트를 둘 필요가 없습니다.")
                }

                Section(title: "6. deploy.env — 앱의 배포 규칙 전부", icon: "doc.text") {
                    KeyRow("SCHEME", "archive 할 scheme", required: true)
                    KeyRow("PLATFORM", "ios | macos — 자동 판별이 틀릴 때만")
                    KeyRow("VERSION_XCCONFIG", "버전·빌드번호가 든 xcconfig 경로")
                    KeyRow("PREDEPLOY_SCRIPT", "배포 전 검사 스크립트 (실패하면 배포 중단)")
                    KeyRow("LOCALES", "App Store 언어 — 다국어 검사와 릴리즈노트의 기준")
                    KeyRow("LOCALIZATION_GATE", "strict(막음) · warn(알림만) · off")
                    Note("기존 fastlane/.env 도 그대로 읽습니다. 둘 다 있으면 deploy.env 가 우선입니다.")
                }

                Section(title: "7. 릴리즈노트", icon: "doc.richtext") {
                    Text("""
                    배포가 끝나면 App Store 에 등록된 언어를 조회해 언어별 문구를 자동으로 올립니다.
                    문구는 ① AI(config.env 의 ANTHROPIC_API_KEY) → ② Apple 온디바이스 번역 → ③ 직접 입력 순서로 채워집니다.
                    빈 칸은 업로드하지 않으므로 기존 문구가 지워지지 않습니다.
                    """)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    Note("카드의 [문서] 아이콘을 누르면 언어별 편집창이 열립니다. [빈 언어 채우기] 로 한국어 원문에서 나머지를 번역합니다.")
                }

                Section(title: "8. 처음 한 번 해 둘 것", icon: "gearshape") {
                    Row(color: .secondary, title: "ASC 키",
                        detail: "~/Documents/workspace/fastlane-shared/asc.env 와 ~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8")
                    Row(color: .secondary, title: "AI 릴리즈노트 (선택)",
                        detail: "~/Library/Application Support/DeployBar/config.env 에 ANTHROPIC_API_KEY=…")
                    Row(color: .secondary, title: "온디바이스 번역 (선택)",
                        detail: "시스템 설정 › 일반 › 언어 및 지역 에서 번역할 언어를 내려받아 두면 키 없이도 번역됩니다")
                }
            }
            .padding(20)
        }
        .frame(minWidth: 520, minHeight: 560)
    }

    // ── 조각들 ──────────────────────────────────────────────────────────
    private struct Section<Content: View>: View {
        let title: String
        let icon: String
        @ViewBuilder let content: Content

        init(title: String, icon: String, @ViewBuilder content: () -> Content) {
            self.title = title; self.icon = icon; self.content = content()
        }
        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Label(title, systemImage: icon).font(.headline)
                content
            }
        }
    }

    private struct Steps: View {
        let items: [(String, String)]
        init(_ items: [(String, String)]) { self.items = items }
        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, it in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(i + 1)")
                            .font(.caption.weight(.bold))
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(Color.accentColor.opacity(0.18)))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(it.0).font(.callout.weight(.medium))
                            Text(it.1).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private struct Row: View {
        let color: Color, title: String, detail: String
        var body: some View {
            HStack(alignment: .top, spacing: 8) {
                Circle().fill(color).frame(width: 9, height: 9).padding(.top, 4)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.callout.weight(.medium))
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private struct KeyRow: View {
        let key: String, detail: String, required: Bool
        init(_ key: String, _ detail: String, required: Bool = false) {
            self.key = key; self.detail = detail; self.required = required
        }
        var body: some View {
            HStack(alignment: .top, spacing: 8) {
                Text(key)
                    .font(.system(size: 11, design: .monospaced))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: .textBackgroundColor)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if required {
                    Text("필수").font(.caption2.weight(.bold)).foregroundStyle(.orange)
                }
            }
        }
    }

    private struct Note: View {
        let text: String
        init(_ text: String) { self.text = text }
        var body: some View {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "lightbulb").font(.caption2).foregroundStyle(.yellow)
                Text(text).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.yellow.opacity(0.08)))
        }
    }
}
