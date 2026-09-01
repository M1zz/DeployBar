import AppKit

// 붙여넣기용 지시문을 클립보드에 넣는다.
// 복사됐다는 표시는 각 뷰가 자기 상태로 관리한다 (여러 곳에서 동시에 눌릴 수 있으므로).
enum Clipboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
