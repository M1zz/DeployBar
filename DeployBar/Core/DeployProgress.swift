import Foundation

// 배포가 지금 **어디까지 왔는지**.
//
// 예전엔 배포가 로그 한 줄기였다. 3분쯤 아무것도 안 움직이면
// "돌고 있는 건가, 멈춘 건가, 끝났는데 내가 못 본 건가" 를 알 방법이
// 스크롤을 올려 마지막 줄을 읽는 것뿐이었다. 로그는 '무슨 일이 있었나' 는 잘 말하지만
// '얼마나 남았나' 는 말하지 않는다.
//
// 그래서 배포를 정해진 단계의 줄로 만든다. 시작하는 순간 **전체 계획이 다 보이고**,
// 각 단계가 대기 → 진행 → 완료(또는 건너뜀 / 실패) 로 바뀐다.
// 실패하면 어느 칸에서 멈췄는지가 그 자리에 남는다.

enum DeployStage: Int, CaseIterable, Identifiable, Codable {
    case notesPrefill   // 릴리즈노트 미리 채우기 (게이트에 걸리기 전에)
    case prepare        // 프로젝트·빌드 설정 확인
    case pull           // 원격 받기
    case l10n           // 다국어 검사
    case notes          // 릴리즈노트 검사
    case gate           // 배포 전 검사
    case version        // 버전·빌드번호
    case archive        // 빌드
    case export         // 서명·추출
    case upload         // 업로드
    case confirm        // 도착 확인
    case tag            // 태그
    case notesApply     // 릴리즈노트 반영

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .notesPrefill: return "릴리즈노트 준비"
        case .prepare:    return "프로젝트 확인"
        case .pull:       return "원격 받기"
        case .l10n:       return "다국어 검사"
        case .notes:      return "릴리즈노트 검사"
        case .gate:       return "배포 전 검사"
        case .version:    return "버전·빌드번호"
        case .archive:    return "빌드"
        case .export:     return "서명·추출"
        case .upload:     return "업로드"
        case .confirm:    return "도착 확인"
        case .tag:        return "태그"
        case .notesApply: return "릴리즈노트 반영"
        }
    }

    /// 진행 중일 때 한 줄로 무슨 일을 하는지. 오래 걸리는 칸일수록 이 설명이 중요하다 —
    /// 3분을 기다리는 사람에게 "archive" 라는 낱말 하나는 아무 말도 해 주지 않는다.
    var hint: String {
        switch self {
        case .notesPrefill: return "레포에 써 둔 글이나 커밋에서 빈 언어를 미리 채우는 중"
        case .prepare:    return "scheme·번들ID·플랫폼을 읽는 중"
        case .pull:       return "원격의 최신 커밋을 받아오는 중"
        case .l10n:       return ".xcstrings 의 번역 구멍을 세는 중"
        case .notes:      return "App Store 의 '이 버전의 새로운 기능' 을 확인하는 중"
        case .gate:       return "predeploy.sh — 테스트·검사가 통과해야 다음으로 갑니다"
        case .version:    return "App Store 의 마지막 빌드번호를 보고 다음 번호를 정하는 중"
        case .archive:    return "xcodebuild archive — 가장 오래 걸리는 칸입니다 (보통 2~5분)"
        case .export:     return "아카이브에 서명해서 ipa/pkg 로 꺼내는 중"
        case .upload:     return "altool 로 App Store Connect 에 올리는 중"
        case .confirm:    return "정말 도착했는지 App Store Connect 에 되묻는 중"
        case .tag:        return "이번 배포 지점에 git 태그를 다는 중"
        case .notesApply: return "언어별 릴리즈노트를 만들어 App Store 에 반영하는 중"
        }
    }

    /// 진행 막대에서 차지하는 몫 ≈ 대개 걸리는 시간(초).
    /// 칸 수로 균등하게 나누면 archive 하나에서 막대가 3분간 멈춘 것처럼 보인다 —
    /// 실제로 걸리는 만큼 자리를 주어야 막대가 거짓말을 하지 않는다.
    var weight: Double {
        switch self {
        case .notesPrefill: return 15
        case .prepare:    return 4
        case .pull:       return 3
        case .l10n:       return 1
        case .notes:      return 3
        case .gate:       return 25
        case .version:    return 4
        case .archive:    return 180
        case .export:     return 40
        case .upload:     return 70
        case .confirm:    return 20
        case .tag:        return 1
        case .notesApply: return 20
        }
    }
}

enum StageState: String, Codable {
    case pending    // 아직
    case running    // 지금
    case done       // 됨
    case skipped    // 할 필요가 없어서 지나감 (실패가 아니다 — 구분해서 보여 준다)
    case failed     // 여기서 멈췄다

    var isFinished: Bool { self == .done || self == .skipped || self == .failed }
}

struct StageStep: Identifiable {
    let stage: DeployStage
    var state: StageState = .pending
    /// 그 칸에 대해 덧붙일 한 줄 ("건너뜀 — 원격 추적 브랜치 없음", "build 3 으로 올림" 등).
    /// 로그를 안 펼쳐도 무슨 일이 있었는지 알 수 있게.
    var note: String?
    var startedAt: Date?
    var endedAt: Date?

    var id: Int { stage.rawValue }

    /// 끝난 칸은 걸린 시간, 도는 칸은 지금까지 걸린 시간.
    func elapsed(now: Date = Date()) -> TimeInterval? {
        guard let s = startedAt else { return nil }
        return (endedAt ?? now).timeIntervalSince(s)
    }
}

extension TimeInterval {
    /// "12초" · "1분 12초" — 초 단위까지 보여 준다. 오래 도는 칸에서 사람이 보는 건
    /// 정확한 숫자가 아니라 "숫자가 아직 움직이나" 다.
    var stageClock: String {
        let t = Int(rounded())
        return t < 60 ? "\(t)초" : "\(t / 60)분 \(t % 60)초"
    }
}

/// 배포 한 번의 진행 상태. Job 이 들고 있고, Deployer 가 칸을 옮긴다.
struct DeployProgress {
    var steps: [StageStep] = DeployStage.allCases.map { StageStep(stage: $0) }
    /// 이번 배포에서 아예 지나갈 칸 (check 모드 등). 진행 막대 분모에서 빼지 않고
    /// skipped 로 채워 넣는다 — 계획이 도중에 줄어들면 막대가 뒤로 가는 것처럼 보인다.

    private func index(_ s: DeployStage) -> Int? { steps.firstIndex { $0.stage == s } }

    mutating func begin(_ s: DeployStage) {
        guard let i = index(s) else { return }
        steps[i].state = .running
        steps[i].startedAt = Date()
        steps[i].endedAt = nil
    }

    mutating func finish(_ s: DeployStage, _ state: StageState, note: String? = nil) {
        guard let i = index(s) else { return }
        // 시작을 못 본 칸도 결과는 남긴다 (건너뛴 칸은 begin 없이 곧장 skipped 로 온다)
        if steps[i].startedAt == nil { steps[i].startedAt = Date() }
        steps[i].state = state
        steps[i].endedAt = Date()
        if let note { steps[i].note = note }
    }

    /// 지금 돌고 있는 칸을 실패로 닫고, 아직 시작 못 한 칸은 그대로 대기로 남긴다.
    /// (대기 칸을 실패로 칠하면 "여기서 멈췄다" 가 어디인지 안 보인다)
    mutating func failCurrent(note: String?) {
        guard let i = steps.firstIndex(where: { $0.state == .running }) else { return }
        steps[i].state = .failed
        steps[i].endedAt = Date()
        if let note { steps[i].note = note }
    }

    /// 남은 대기 칸을 전부 건너뜀으로 (check 모드처럼 여기서 끝나는 경우)
    mutating func skipRemaining(note: String) {
        for i in steps.indices where steps[i].state == .pending {
            steps[i].state = .skipped
            steps[i].note = note
            steps[i].startedAt = Date(); steps[i].endedAt = Date()
        }
    }

    var current: StageStep? { steps.first { $0.state == .running } }
    var failed: StageStep? { steps.first { $0.state == .failed } }
    var finishedCount: Int { steps.filter { $0.state.isFinished }.count }

    /// 0…1. 끝난 칸의 몫을 더하고, 도는 칸은 흐른 시간만큼 그 칸 안에서만 채운다 —
    /// 그래야 archive 3분 동안에도 막대가 아주 조금씩 움직인다. 그 칸을 넘지는 않는다.
    func fraction(now: Date = Date()) -> Double {
        let total = steps.reduce(0) { $0 + $1.stage.weight }
        guard total > 0 else { return 0 }
        var acc = 0.0
        for s in steps {
            switch s.state {
            case .done, .skipped, .failed:
                acc += s.stage.weight
            case .running:
                let spent = s.elapsed(now: now) ?? 0
                // 예상보다 오래 걸려도 그 칸을 다 채우지는 않는다 (최대 90%)
                acc += s.stage.weight * min(0.9, spent / max(s.stage.weight, 1))
            case .pending:
                break
            }
        }
        return min(1, acc / total)
    }
}
