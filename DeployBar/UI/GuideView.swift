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

                Section(title: "2. 40개 중에서 지금 볼 것만 남기기", icon: "line.3.horizontal.decrease.circle") {
                    Text("""
                    맨 위의 요약 칩(배포 가능 · 막힘 · 배포됨 · 설정 필요)은 그냥 숫자가 아니라 필터입니다. \
                    누르면 그 분류만 남고, 다시 누르거나 오른쪽 '5/31개' 를 누르면 해제됩니다.
                    """)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    Note("필터는 보이는 목록만 바꿉니다. 배포 순서와 [전체 배포] 대상은 늘 전체 기준이라 영향받지 않습니다.")
                }

                Section(title: "3. 배포 순서 정하기", icon: "arrow.up.arrow.down") {
                    Text("""
                    헤더의 ↑↓ 버튼을 누르면 순서 편집 모드가 됩니다. 드래그하거나 ▲▼ 로 옮기면 되고, \
                    바꾸는 즉시 저장됩니다. [전체 배포] 는 이 순서대로 위에서부터 진행합니다.
                    """)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    Note("카드의 '전체 배포 N번째' 배지가 이번에 몇 번째로 나갈지를 알려 줍니다. 막힌 앱은 번호를 받지 않습니다 — 순서에서 자동으로 빠집니다.")
                }

                Section(title: "4. 왼쪽 점 색이 뜻하는 것", icon: "circle.fill") {
                    Row(color: .purple, title: "심사 중", detail: "내가 제출했고 애플이 보는 중 — 지금 올리면 그 심사가 취소됩니다")
                    Row(color: .orange, title: "배포 잠김", detail: "❌ 가 있음 — 오른쪽 [🔒 잠김 N] 을 누르면 이유가 펼쳐집니다")
                    Row(color: .blue, title: "배포 가능 · 권장 남음", detail: "막는 건 없음. ⚠️ 가 있어도 배포는 됩니다")
                    Row(color: .green, title: "배포 가능 / 배포됨", detail: "전부 통과했거나, 이미 스토어와 같은 버전입니다")
                    Note("'제출 준비'·'거부됨' 은 아직 안 낸 상태라 배포해도 잃을 심사가 없습니다. 그래서 심사 중(보라)이 아니라 배포 가능으로 셉니다.")
                    Note("점은 '내 Mac 에서 지금 배포를 누를 수 있나' 만 말합니다. App Store 쪽 상태(제출 준비·심사 중 …)는 버전 줄 끝에 붙습니다 — 스토어가 '제출 준비' 여도 내 쪽은 커밋조차 안 돼 있을 수 있기 때문입니다.")
                    Note("같은 말을 두 번 하지 않으려고 글자 배지를 없앴습니다. 점 = 상태, 버튼 = 지금 할 수 있는 일, 요약 줄 = 무엇이 왜 막는지. 버전 올리기·자동 설정·점검은 ⋯ 안에 있습니다.")
                }

                Section(title: "5. '배포 준비 7/10' 이 뜻하는 것", icon: "checklist") {
                    Text("""
                    배포에 필요한 것은 앱마다 8~10가지입니다. 카드의 N/M 을 누르면 그 전부가 펼쳐집니다.                     통과한 것도 ✅ 로 남기므로, 아무것도 안 뜰 때 '검사를 안 한 건지 준비가 된 건지' 헷갈리지 않습니다.
                    """)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    Row(color: .orange, title: "❌ 배포 잠김", detail: "이게 하나라도 있으면 [배포] 버튼이 [🔒 잠김 N] 으로 바뀝니다")
                    Row(color: .blue, title: "⚠️ 권장", detail: "배포는 되지만 해 두면 사고가 줄어듭니다 — 대부분 [자동 설정] 한 번")
                    Row(color: .green, title: "✅ 통과", detail: "이 항목은 준비 끝")
                    Note("통과한 항목은 '✅ 통과한 N가지' 한 줄로 접혀 있습니다 — 눌러서 펼치면 다 볼 수 있습니다.")
                    Note("[해결 프롬프트] 를 누르면 남은 항목이 그대로 지시문이 되어 클립보드에 들어갑니다. Claude Code 등에 붙여넣으면 됩니다 — 잠긴 이유를 손으로 옮겨 적을 일이 없습니다. 항목 옆 작은 아이콘은 그 항목 하나만 복사합니다.")
                }

                Section(title: "6. 배포가 막히는 이유와 해결", icon: "exclamationmark.triangle.fill") {
                    Row(color: .orange, title: "커밋되지 않은 변경", detail: "커밋하면 됩니다")
                    Row(color: .orange, title: "올릴 변경 없음", detail: "[버전 올리기] 를 누르거나 새 커밋을 하세요")
                    Row(color: .orange, title: "버전 파일 경로 오류", detail: "[자동 설정] 이 실제 경로로 고쳐 줍니다")
                    Row(color: .orange, title: "번역 구멍", detail: "Xcode 에서 String Catalog 를 열어 빈 칸을 채우세요")
                    Row(color: .orange, title: "릴리즈노트 비어 있음", detail: "[릴리즈노트] 창에서 [빈 언어 채우기] 후 적용하세요")
                    Row(color: .orange, title: "App Store 앱 확인 실패", detail: "App Store Connect 에 그 번들 ID 로 앱이 있어야 합니다")
                }

                Section(title: "7. 새 앱을 배포 대상으로 만들기", icon: "wand.and.stars") {
                    Steps([
                        ("앱 폴더를 ~/Documents/workspace/Auto/ 아래에 둔다", "폴더 최상단에 .xcodeproj 가 있으면 자동으로 목록에 나타납니다."),
                        ("[전체 자동 설정] 또는 카드의 [자동 설정] 을 누른다", "deploy.env 와 scripts/predeploy.sh 를 그 앱에 맞게 만들어 줍니다. 이미 있는 파일은 건드리지 않습니다."),
                        ("배포 전 검사를 손본다", "scripts/predeploy.sh 에 그 앱의 테스트를 넣습니다. 테스트 타겟이 없으면 그 단계를 지우세요."),
                    ])
                    Note("다국어 검사는 DeployBar 안에 들어 있어서, 앱마다 검사 스크립트를 둘 필요가 없습니다.")
                }

                Section(title: "8. deploy.env — 앱의 배포 규칙 전부", icon: "doc.text") {
                    KeyRow("SCHEME", "archive 할 scheme", required: true)
                    KeyRow("PLATFORM", "ios | macos — 자동 판별이 틀릴 때만")
                    KeyRow("VERSION_XCCONFIG", "버전·빌드번호가 든 xcconfig 경로")
                    KeyRow("PREDEPLOY_SCRIPT", "배포 전 검사 스크립트 (실패하면 배포 중단)")
                    KeyRow("LOCALES", "App Store 언어 — 다국어 검사와 릴리즈노트의 기준")
                    KeyRow("LOCALIZATION_GATE", "strict(막음) · warn(알림만) · off")
                    Note("기존 fastlane/.env 도 그대로 읽습니다. 둘 다 있으면 deploy.env 가 우선입니다.")
                }

                Section(title: "9. 릴리즈노트 — 비어 있으면 배포가 막힙니다", icon: "doc.richtext") {
                    Note("'이 버전의 새로운 기능' 이 한 언어라도 비어 있으면 빌드를 만들기 전에 멈춥니다. 빈 노트로 나간 버전은 되돌릴 수 없어서, 업로드 뒤가 아니라 앞에서 막습니다. 빈 채로 내야 한다면 deploy.env 에 RELEASE_NOTES_GATE=warn 을 넣으세요.")
                    Text("""
                    배포가 끝나면 App Store 에 등록된 언어를 조회해 언어별 문구를 자동으로 올립니다.
                    문구는 ① AI(config.env 의 ANTHROPIC_API_KEY) → ② Apple 온디바이스 번역 → ③ 직접 입력 순서로 채워집니다.
                    빈 칸은 업로드하지 않으므로 기존 문구가 지워지지 않습니다.
                    """)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    Note("카드의 [문서] 아이콘을 누르면 언어별 편집창이 열립니다. [빈 언어 채우기] 로 한국어 원문에서 나머지를 번역합니다.")
                }

                Section(title: "10. 처음 한 번 해 둘 것", icon: "gearshape") {
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
