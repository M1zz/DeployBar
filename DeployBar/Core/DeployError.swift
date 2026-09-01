import Foundation

// 배포가 실패했을 때 "그래서 내가 뭘 해야 하나" 까지 들고 다니는 오류.
//
// 예전엔 실패가 문자열 한 줄이었다. 원인은 로그 창 어딘가에 흘러갔고,
// 사람이 수백 줄을 거슬러 올라가 첫 error: 를 찾아야 했다.
// Readiness 가 "배포 전에 뭐가 필요한가" 를 항목으로 답하듯,
// 이쪽은 "배포가 깨졌을 때 뭘 하면 되는가" 를 같은 결로 답한다.
struct DeployError: Error, LocalizedError {
    var app: String
    var path: String
    /// 어느 단계에서 깨졌나 — git pull · 배포 전 검사 · archive · 업로드 …
    var stage: String
    /// 무엇이 잘못됐나, 한 줄
    var title: String
    /// 지금 할 일, 순서대로. 여기가 이 타입의 존재 이유다.
    var todo: [String]
    /// 근거 — 도구가 뱉은 원문 몇 줄 (추측이 아니라는 증거)
    var detail: String = ""
    /// 버튼 한 번으로 되는 것이 있으면
    var fix: Fix? = nil

    var errorDescription: String? {
        var s = title
        if !todo.isEmpty { s += "\n" + todo.map { "→ \($0)" }.joined(separator: "\n") }
        if !detail.isEmpty { s += "\n" + detail }
        return s
    }

    /// 붙여넣기용 지시문 — 체크리스트의 [해결 프롬프트] 와 같은 결.
    var promptText: String {
        var s = "\(path) 의 App Store 배포가 '\(stage)' 단계에서 실패했어. 원인을 찾아 고쳐줘.\n\n"
        s += "## 실패한 것\n"
        s += "- 앱: \(app)\n"
        s += "- 단계: \(stage)\n"
        s += "- 증상: \(title)\n"
        if !detail.isEmpty {
            s += "\n## 도구가 뱉은 말\n```\n\(detail)\n```\n"
        }
        if !todo.isEmpty {
            s += "\n## 사람이 보기엔 이렇게 하면 될 것 같다 (참고만)\n"
            for t in todo { s += "- \(t)\n" }
        }
        s += """

        ## 지켜야 할 것
        - App Store 업로드는 하지 마 — 원인만 고쳐줘. 배포는 DeployBar 가 다시 돌린다.
          (확인이 필요하면 빌드까지만.)
        - deploy.env 를 고칠 땐 주석과 키 순서를 그대로 두고 필요한 값만 바꿔.
        - 다 끝나면 커밋까지 해줘. 커밋되지 않은 변경이 남으면 배포가 다시 막힌다.
        - 못 고치는 게 있으면 억지로 넘기지 말고 무엇이 왜 막혔는지 알려줘.
        """
        return s
    }
}
