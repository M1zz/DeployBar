#!/usr/bin/env swift
//
// DeployBar 앱 아이콘 생성기 — 의존성 0 (CoreGraphics 만).
//
//   swift scripts/make_icon.swift
//
// DeployBar/Assets.xcassets/AppIcon.appiconset/ 에 PNG 와 Contents.json 을 새로 쓴다.
// 디자인을 고치려면 아래 상수만 만지면 된다 — 모든 크기가 같은 코드에서 나오므로
// 16px 과 1024px 이 어긋날 일이 없다.
//
// 모티프: 가로 막대(메뉴바) 위로 솟는 화살표 = "메뉴바에서 올린다".
// 업로드 글리프라 16px 에서도 뜻이 읽힌다.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// ── 디자인 상수 (1024 캔버스 기준 비율) ─────────────────────────────────
let tileInset: CGFloat = 0.0977      // Big Sur 규격: 1024 중 100 여백
let cornerN: CGFloat = 5             // 초타원 지수 — Apple 스퀘어클에 가깝다
let gradTop = (r: 0.36, g: 0.55, b: 1.00)     // #5C8CFF
let gradBottom = (r: 0.16, g: 0.25, b: 0.82)  // #2940D1

// 타일 안에서 마크의 위치 (타일 크기 T 에 대한 비율, 원점 = 타일 좌하단)
let barX0: CGFloat = 0.235, barX1: CGFloat = 0.765
let barY0: CGFloat = 0.150, barY1: CGFloat = 0.243
let stemX0: CGFloat = 0.427, stemX1: CGFloat = 0.573
let stemY0: CGFloat = 0.345, stemY1: CGFloat = 0.605
let headX0: CGFloat = 0.283, headX1: CGFloat = 0.717
let headY0: CGFloat = 0.575, headApex: CGFloat = 0.850

// ── 초타원(스퀘어클) 경로 ──────────────────────────────────────────────
func squircle(in rect: CGRect, n: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let cx = rect.midX, cy = rect.midY
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = cx + a * (ct < 0 ? -1 : 1) * pow(abs(ct), 2 / n)
        let y = cy + b * (st < 0 ? -1 : 1) * pow(abs(st), 2 / n)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

func roundedBar(_ rect: CGRect) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: rect.height / 2, cornerHeight: rect.height / 2, transform: nil)
}

func newContext(_ size: Int) -> CGContext? {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    ctx?.interpolationQuality = .high
    ctx?.setAllowsAntialiasing(true)
    return ctx
}

// ── 한 장 그리기 ───────────────────────────────────────────────────────
//
// 타일(그라디언트 + 마크)을 **투명 배경에 따로 렌더한 뒤** 그림자를 걸어 합성한다.
// 검은 도형을 깔고 그 위에 그라디언트를 덮으면 안티에일리어싱된 가장자리에서
// 검정이 비쳐 테두리처럼 보인다 — 그래서 두 단계로 나눈다.
func drawIcon(size: Int) -> CGImage? {
    let S = CGFloat(size)
    guard let ctx = newContext(size) else { return nil }

    let inset = S * tileInset
    let tile = CGRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2)
    let T = tile.width
    let shape = squircle(in: tile, n: cornerN)

    // 배경 그라디언트 (위 → 아래)
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    let colors = [
        CGColor(colorSpace: space, components: [CGFloat(gradTop.r), CGFloat(gradTop.g), CGFloat(gradTop.b), 1])!,
        CGColor(colorSpace: space, components: [CGFloat(gradBottom.r), CGFloat(gradBottom.g), CGFloat(gradBottom.b), 1])!,
    ]
    if let grad = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 1]) {
        ctx.drawLinearGradient(grad,
                               start: CGPoint(x: tile.midX, y: tile.maxY),
                               end: CGPoint(x: tile.midX, y: tile.minY),
                               options: [])
    }
    // 상단 하이라이트 — 유리 같은 입체감 (작은 사이즈에선 생략)
    if size >= 64,
       let gloss = CGGradient(colorsSpace: space,
                              colors: [CGColor(red: 1, green: 1, blue: 1, alpha: 0.22),
                                       CGColor(red: 1, green: 1, blue: 1, alpha: 0)] as CFArray,
                              locations: [0, 1]) {
        ctx.drawLinearGradient(gloss,
                               start: CGPoint(x: tile.midX, y: tile.maxY),
                               end: CGPoint(x: tile.midX, y: tile.midY + T * 0.08),
                               options: [])
    }
    ctx.restoreGState()

    // 마크 — 막대 + 위로 솟는 화살표
    func px(_ v: CGFloat) -> CGFloat { tile.minX + T * v }
    func py(_ v: CGFloat) -> CGFloat { tile.minY + T * v }

    ctx.saveGState()
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))

    ctx.addPath(roundedBar(CGRect(x: px(barX0), y: py(barY0),
                                  width: T * (barX1 - barX0), height: T * (barY1 - barY0))))
    ctx.fillPath()

    let arrow = CGMutablePath()
    arrow.addRect(CGRect(x: px(stemX0), y: py(stemY0),
                         width: T * (stemX1 - stemX0), height: T * (stemY1 - stemY0)))
    arrow.move(to: CGPoint(x: px(headX0), y: py(headY0)))
    arrow.addLine(to: CGPoint(x: px(headX1), y: py(headY0)))
    arrow.addLine(to: CGPoint(x: px(0.5), y: py(headApex)))
    arrow.closeSubpath()
    ctx.addPath(arrow)
    ctx.fillPath()
    ctx.restoreGState()

    guard let tileImage = ctx.makeImage() else { return nil }

    // 그림자는 다 그린 타일에 건다 — 작은 사이즈에선 뭉개지므로 128 이상에서만
    guard size >= 128, let out = newContext(size) else { return tileImage }
    out.setShadow(offset: CGSize(width: 0, height: -S * 0.012),
                  blur: S * 0.030,
                  color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.28))
    out.draw(tileImage, in: CGRect(x: 0, y: 0, width: S, height: S))
    return out.makeImage()
}

// ── 메뉴바 글리프 ──────────────────────────────────────────────────────
//
// 앱 아이콘과 **같은 도형 상수**에서 뽑는다 — 로고와 메뉴바 아이콘이 어긋나지 않게.
// 검정 + 알파의 템플릿 이미지라 macOS 가 밝은/어두운 메뉴바에 맞춰 알아서 칠한다.
func drawMenuBarGlyph(size: Int) -> CGImage? {
    guard let ctx = newContext(size) else { return nil }
    let S = CGFloat(size)

    // 마크의 원래 비율 (타일 T 기준): 폭 0.53T, 높이 0.70T
    let markW = barX1 - barX0
    let markH = headApex - barY0
    // 캔버스 높이의 82% 를 차지하도록 T 를 역산 (위아래 여백 확보)
    let T = S * 0.82 / markH
    let originX = (S - T * markW) / 2 - T * barX0     // 마크를 가로 중앙에
    let originY = (S - T * markH) / 2 - T * barY0

    func px(_ v: CGFloat) -> CGFloat { originX + T * v }
    func py(_ v: CGFloat) -> CGFloat { originY + T * v }

    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    ctx.addPath(roundedBar(CGRect(x: px(barX0), y: py(barY0),
                                  width: T * markW, height: T * (barY1 - barY0))))
    ctx.fillPath()

    let arrow = CGMutablePath()
    arrow.addRect(CGRect(x: px(stemX0), y: py(stemY0),
                         width: T * (stemX1 - stemX0), height: T * (stemY1 - stemY0)))
    arrow.move(to: CGPoint(x: px(headX0), y: py(headY0)))
    arrow.addLine(to: CGPoint(x: px(headX1), y: py(headY0)))
    arrow.addLine(to: CGPoint(x: px(0.5), y: py(headApex)))
    arrow.closeSubpath()
    ctx.addPath(arrow)
    ctx.fillPath()

    return ctx.makeImage()
}

// ── 저장 ───────────────────────────────────────────────────────────────
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("DeployBar/Assets.xcassets/AppIcon.appiconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// macOS 앱 아이콘 슬롯 (표시 크기, 배율)
//
// 16x16@2x 와 32x32@1x 는 둘 다 32px 이라 한 파일을 공유하고 싶어지지만,
// 슬롯마다 파일을 따로 쓴다 (Apple 표준 이름 규칙). 렌더는 픽셀 크기별로 한 번만 한다.
//
// 참고: 빌드 결과의 Contents/Resources/AppIcon.icns 에는 일부 크기만 들어간다.
// 정상이다 — macOS 는 Info.plist 의 CFBundleIconName 을 보고 Assets.car 를 쓰고,
// 거기에는 10개 슬롯이 모두 들어간다. 확인하려면:
//   xcrun assetutil --info <앱>/Contents/Resources/Assets.car | grep -c AppIcon
let slots: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                           (256, 1), (256, 2), (512, 1), (512, 2)]
var entries: [String] = []
var cache: [Int: CGImage] = [:]

for (pt, scale) in slots {
    let px = pt * scale
    let name = "icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png"
    let image: CGImage
    if let hit = cache[px] {
        image = hit                                  // 같은 픽셀 크기는 한 번만 렌더
    } else {
        guard let rendered = drawIcon(size: px) else { fatalError("렌더 실패: \(px)") }
        image = rendered
        cache[px] = rendered
    }
    let url = iconset.appendingPathComponent(name)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("PNG 저장 실패: \(name)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("PNG 마무리 실패: \(name)") }
    print("  \(name)  (\(px)×\(px))")
    entries.append("""
        {
          "filename" : "\(name)",
          "idiom" : "mac",
          "scale" : "\(scale)x",
          "size" : "\(pt)x\(pt)"
        }
    """)
}
let written = entries

let contents = """
{
  "images" : [
\(entries.joined(separator: ",\n"))
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}

"""
try contents.write(to: iconset.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("✅ 앱 아이콘 \(written.count)장 + Contents.json")

// ── 메뉴바 템플릿 이미지 ───────────────────────────────────────────────
let menuset = root.appendingPathComponent("DeployBar/Assets.xcassets/MenuBarIcon.imageset")
try? FileManager.default.createDirectory(at: menuset, withIntermediateDirectories: true)

var menuEntries: [String] = []
for scale in 1...3 {
    let px = 18 * scale                       // 메뉴바 기준 18pt
    let name = "menubar_\(scale)x.png"
    guard let image = drawMenuBarGlyph(size: px) else { fatalError("메뉴바 글리프 렌더 실패") }
    let url = menuset.appendingPathComponent(name)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("PNG 저장 실패: \(name)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("PNG 마무리 실패: \(name)") }
    menuEntries.append("""
        {
          "filename" : "\(name)",
          "idiom" : "universal",
          "scale" : "\(scale)x"
        }
    """)
    print("  \(name)  (\(px)×\(px))")
}

let menuContents = """
{
  "images" : [
\(menuEntries.joined(separator: ",\n"))
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  },
  "properties" : {
    "template-rendering-intent" : "template"
  }
}

"""
try menuContents.write(to: menuset.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("✅ 메뉴바 템플릿 이미지 3장 + Contents.json")
