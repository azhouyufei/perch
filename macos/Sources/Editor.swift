import CoreText
import ImageIO
import SwiftUI
import Vision

enum MarkTool: String, CaseIterable, Identifiable {
  case pen = "画笔"
  case box = "矩形"
  case arrow = "箭头"
  case redact = "遮盖"
  case circle = "圆形"
  case ellipse = "椭圆"
  case text = "文字"
  case mosaic = "马赛克"
  var id: Self { self }
  func hint(inSelection: Bool) -> String {
    let action: String
    switch self {
    case .pen: action = L("按住并拖动，自由绘制线条")
    case .box: action = L("从一个角拖到对角，绘制矩形轮廓")
    case .arrow: action = L("从起点拖向要指示的位置")
    case .redact: action = L("拖出范围，用不透明色块遮盖")
    case .circle: action = L("按住并拖动，绘制正圆")
    case .ellipse: action = L("拖出长宽，绘制椭圆")
    case .text: action = inSelection ? L("点击输入，回车确认；拖动已有文字可调整位置") : L("输入后点击图片放置；拖动已有文字可调整位置")
    case .mosaic: action = L("拖出要像素化的范围，线宽控制颗粒大小")
    }
    return L(rawValue) + " · " + action
  }
  var symbol: String {
    switch self {
    case .pen: return "pencil.tip"
    case .box: return "rectangle"
    case .arrow: return "arrow.up.right"
    case .redact: return "rectangle.fill"
    case .circle: return "circle"
    case .ellipse: return "oval"
    case .text: return "textformat"
    case .mosaic: return "checkerboard.rectangle"
    }
  }
}
struct Mark {
  let tool: MarkTool
  let color: CGColor
  var points: [CGPoint]
  var strokeFraction: CGFloat = 0.006
  var caption = ""
  var texture: CGImage?
  private func captionLine(_ size: CGSize) -> (CTFont, CTLine) {
    let font = CTFontCreateWithName(
      "Helvetica" as CFString, max(0.25, min(size.width, size.height) * strokeFraction) * 6, nil)
    let attrs: [NSAttributedString.Key: Any] = [
      NSAttributedString.Key(kCTFontAttributeName as String): font,
      NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
    ]
    let text = CTLineCreateWithAttributedString(
      NSAttributedString(string: caption, attributes: attrs))
    return (font, text)
  }
  func captionBounds(_ size: CGSize) -> CGRect? {
    guard tool == .text, let anchor = points.first else { return nil }
    let (font, line) = captionLine(size)
    let width = CTLineGetTypographicBounds(line, nil, nil, nil)
    return CGRect(
      x: anchor.x * size.width, y: anchor.y * size.height, width: CGFloat(width),
      height: CTFontGetAscent(font) + CTFontGetDescent(font))
  }
  func draw(_ ctx: CGContext, size: CGSize) {
    guard let a = points.first, let b = points.last else { return }
    func at(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * size.width, y: p.y * size.height) }
    let start = at(a)
    let end = at(b)
    let bounds = CGRect(
      x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x),
      height: abs(end.y - start.y))
    let line = max(0.25, min(size.width, size.height) * strokeFraction)
    ctx.saveGState()
    defer { ctx.restoreGState() }
    ctx.setStrokeColor(color)
    ctx.setFillColor(color)
    ctx.setLineWidth(line)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    switch tool {
    case .circle:
      let side = min(bounds.width, bounds.height)
      ctx.strokeEllipse(
        in: CGRect(
          x: end.x >= start.x ? start.x : start.x - side,
          y: end.y >= start.y ? start.y : start.y - side, width: side, height: side))
    case .ellipse: ctx.strokeEllipse(in: bounds)
    case .text:
      let (font, text) = captionLine(size)
      ctx.translateBy(x: start.x, y: start.y + CTFontGetAscent(font))
      ctx.scaleBy(x: 1, y: -1)
      ctx.textMatrix = .identity
      ctx.textPosition = .zero
      CTLineDraw(text, ctx)
    case .mosaic:
      guard let texture else { return }
      ctx.clip(to: bounds)
      ctx.interpolationQuality = .none
      ctx.translateBy(x: 0, y: size.height)
      ctx.scaleBy(x: 1, y: -1)
      ctx.draw(texture, in: CGRect(origin: .zero, size: size))
    case .redact:
      ctx.setFillColor(CGColor(gray: 0.04, alpha: 1))
      ctx.fill(bounds)
    case .box: ctx.stroke(bounds)
    case .pen:
      if points.count == 1 {
        ctx.fillEllipse(
          in: CGRect(x: start.x - line / 2, y: start.y - line / 2, width: line, height: line))
      } else {
        ctx.addLines(between: points.map(at))
        ctx.strokePath()
      }
    case .arrow:
      let angle = atan2(end.y - start.y, end.x - start.x)
      let len = min(hypot(end.x - start.x, end.y - start.y) * 0.45, line * 5)
      ctx.move(to: start)
      ctx.addLine(to: end)
      for offset in [-0.53, 0.53] {
        ctx.move(to: end)
        ctx.addLine(
          to: CGPoint(x: end.x - len * cos(angle + offset), y: end.y - len * sin(angle + offset)))
      }
      ctx.strokePath()
    }
  }
}
// Coordinates are relative to the annotated image in both the AppKit and SwiftUI canvases.
struct CaptionMove {
  let index: Int, original: CGPoint, touch: CGPoint, maxAnchor: CGPoint
  init?(marks: [Mark], touch: CGPoint, size: CGSize) {
    guard size.width > 0, size.height > 0 else { return nil }
    let point = CGPoint(x: touch.x * size.width, y: touch.y * size.height)
    for i in marks.indices.reversed() {
      guard let bounds = marks[i].captionBounds(size),
        bounds.insetBy(dx: -3, dy: -3).contains(point), let anchor = marks[i].points.first
      else { continue }
      self.index = i; self.original = anchor; self.touch = touch
      maxAnchor = CGPoint(
        x: max(0, 1 - bounds.width / size.width), y: max(0, 1 - bounds.height / size.height))
      return
    }
    return nil
  }
  func update(_ marks: inout [Mark], to p: CGPoint) {
    guard marks.indices.contains(index) else { return }
    if p == touch { marks[index].points = [original]; return }
    marks[index].points = [
      CGPoint(
        x: max(0, min(maxAnchor.x, original.x + p.x - touch.x)),
        y: max(0, min(maxAnchor.y, original.y + p.y - touch.y)))
    ]
  }
  func outline(_ ctx: CGContext, marks: [Mark], size: CGSize) {
    guard marks.indices.contains(index), let box = marks[index].captionBounds(size) else { return }
    ctx.saveGState()
    ctx.setStrokeColor(NSColor.controlAccentColor.cgColor); ctx.setLineWidth(1);
    ctx.setLineDash(phase: 0, lengths: [3, 2]); ctx.stroke(box.insetBy(dx: -2, dy: -2))
    ctx.restoreGState()
  }
}
struct AnnotationDraft {
  let image: CGImage, marks: [Mark], moves: CaptionMoves
}
struct CaptionMoves {
  private var changes: [(count: Int, move: CaptionMove)] = []
  mutating func finish(_ move: CaptionMove, in marks: [Mark]) {
    if marks.indices.contains(move.index), marks[move.index].points.first != move.original {
      changes.append((marks.count, move))
    }
  }
  mutating func undo(_ marks: inout [Mark]) -> Bool {
    if let last = changes.last, last.count == marks.count {
      marks[last.move.index].points = [last.move.original]; changes.removeLast(); return true
    }
    _ = marks.popLast(); return false
  }
}
enum ImageEditor {
  static func refreshMosaics(_ marks: inout [Mark], source: CGImage) {
    for i in marks.indices where marks[i].tool == .mosaic {
      let width = marks[i].strokeFraction * CGFloat(min(source.width, source.height))
      if let texture = try? mosaicTexture(
        source, previous: Array(marks[..<i]), blockSize: max(1, Int((4 * width).rounded())))
      {
        marks[i].texture = texture
      }
    }
  }
  static func mosaicTexture(_ image: CGImage, previous: [Mark], blockSize: Int) throws -> CGImage {
    let source = previous.isEmpty ? image : try composite(image, marks: previous)
    let w = max(1, (source.width + blockSize - 1) / blockSize)
    let h = max(1, (source.height + blockSize - 1) / blockSize)
    guard
      let ctx = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw CocoaError(.fileWriteUnknown) }
    ctx.interpolationQuality = .high
    ctx.draw(source, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let result = ctx.makeImage() else { throw CocoaError(.fileWriteUnknown) }
    return result
  }
  static func original(_ shot: Shot) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(shot.url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
  }
  static func render(_ shot: Shot, marks: [Mark], original image: CGImage? = nil) throws -> Data {
    guard let cg = image ?? original(shot) else { throw CocoaError(.fileReadCorruptFile) }
    let result = try composite(cg, marks: marks)
    guard let data = NSBitmapImageRep(cgImage: result).representation(using: .png, properties: [:])
    else { throw CocoaError(.fileWriteUnknown) }
    return data
  }
  static func composite(_ cg: CGImage, marks: [Mark]) throws -> CGImage {
    guard
      let context = CGContext(
        data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw CocoaError(.fileReadCorruptFile) }
    let size = CGSize(width: cg.width, height: cg.height)
    context.draw(cg, in: CGRect(origin: .zero, size: size))
    context.translateBy(x: 0, y: size.height)
    context.scaleBy(x: 1, y: -1)
    for mark in marks { mark.draw(context, size: size) }
    guard let result = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
    return result
  }
}
struct EditorView: View {
  let shot: Shot
  @ObservedObject var captures: Captures
  let finish: (Shot) -> Void
  let draft: AnnotationDraft?
  init(
    shot: Shot, captures: Captures, draft: AnnotationDraft? = nil, finish: @escaping (Shot) -> Void
  ) {
    self.shot = shot; self.captures = captures; self.draft = draft; self.finish = finish
    _marks = State(initialValue: draft?.marks ?? [])
    _moves = State(initialValue: draft?.moves ?? CaptionMoves())
    _tool = State(
      initialValue: draft?.marks.contains(where: { $0.tool == .text }) == true ? .text : .arrow)
  }
  @State private var marks: [Mark] = []
  @State private var active: Mark?
  @State private var move: CaptionMove?
  @State private var moves = CaptionMoves()
  private func updateMosaics() {
    guard marks.contains(where: { $0.tool == .mosaic }),
      let cg = draft?.image ?? ImageEditor.original(shot)
    else { return }
    ImageEditor.refreshMosaics(&marks, source: cg)
  }
  @State private var tool = MarkTool.arrow
  @State private var ink = Color.red
  @State private var option: AnnotationOption?
  @State private var stroke = 4
  @State private var hoveredHint: String?
  @State private var caption = ""
  @State private var preview: NSImage?
  @State private var failure: String?
  @Environment(\.dismiss) var dismiss
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        VStack(alignment: .leading) {
          Text(L("标注截图")).font(.title2.bold())
          Text("\(Int(shot.pixels.width)) × \(Int(shot.pixels.height)) px").font(
            .caption.monospacedDigit()
          ).foregroundStyle(.secondary)
        }
        Spacer()
        Button(L("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
        Button(L("保存副本")) {
          do {
            let saved = try captures.add(
              ImageEditor.render(shot, marks: marks, original: draft?.image))
            finish(saved)
            dismiss()
          } catch { failure = error.localizedDescription }
        }.buttonStyle(.borderedProminent).disabled(marks.isEmpty && draft == nil)
      }
      HStack {
        ForEach(MarkTool.allCases) { t in
          Button {
            tool = t
          } label: {
            Image(systemName: t.symbol).font(.system(size: 21, weight: .medium)).frame(width: 37, height: 37)
              .background(
                tool == t ? ScopeTheme.raised : .clear, in: RoundedRectangle(cornerRadius: 6))
          }.buttonStyle(.plain).hoverInstruction(t.hint(inSelection: false), selection: $hoveredHint).accessibilityLabel(L(t.rawValue))
            .accessibilityAddTraits(tool == t ? .isSelected : [])
        }
        Divider().frame(height: 18)
        ForEach([AnnotationOption.width, .color], id: \.self) { choice in
          Button { option = choice } label: {
            Image(systemName: choice == .width ? "lineweight" : "circle.fill")
              .foregroundStyle(choice == .width ? Color.primary : ink)
              .font(.system(size: 20)).frame(width: 32, height: 32)
          }.buttonStyle(.plain).accessibilityLabel(L(choice.rawValue))
            .hoverInstruction(
              choice == .width ? L("线宽 · 选择像素宽度") : L("颜色 · 常用色或自定义色盘"), selection: $hoveredHint
            )
            .disabled(choice == .color && (tool == .redact || tool == .mosaic))
            .popover(isPresented: Binding(get: { option == choice }, set: { if !$0 { option = nil } })) {
              AnnotationOptions(choice, width: stroke, current: NSColor(ink)) { value in
                stroke = value; option = nil
              } chooseColor: { value in ink = Color(nsColor: value); option = nil }
            }
        }
        Spacer()
        Button {
          if moves.undo(&marks) { updateMosaics() }
        } label: {
          Image(systemName: "arrow.uturn.backward").font(.system(size: 18))
        }
        .disabled(marks.isEmpty).keyboardShortcut("z").hoverInstruction(
          L("撤销上一次标注或移动（⌘Z）"), selection: $hoveredHint
        ).accessibilityLabel(L("撤销"))
      }
      Text(hoveredHint ?? tool.hint(inSelection: false)).font(.callout).foregroundStyle(.secondary)
      if tool == .text {
        TextField(L("输入文字，再点图片放置"), text: $caption).textFieldStyle(.roundedBorder)
      }
      GeometryReader { geo in
        let scale = min(
          geo.size.width / max(1, shot.pixels.width), geo.size.height / max(1, shot.pixels.height))
        let size = CGSize(width: shot.pixels.width * scale, height: shot.pixels.height * scale)
        ZStack {
          if let preview { Image(nsImage: preview).resizable() }
          Canvas { context, size in
            context.withCGContext { ctx in
              for mark in marks { mark.draw(ctx, size: size) }
              active?.draw(ctx, size: size)
              move?.outline(ctx, marks: marks, size: size)
            }
          }
        }.frame(width: size.width, height: size.height).clipped().contentShape(Rectangle())
          .gesture(
            DragGesture(minimumDistance: 0).onChanged { value in
              func norm(_ p: CGPoint) -> CGPoint {
                CGPoint(x: min(1, max(0, p.x / size.width)), y: min(1, max(0, p.y / size.height)))
              }
              if move == nil && active == nil && tool == .text {
                move = CaptionMove(marks: marks, touch: norm(value.startLocation), size: size)
              }
              if let move { move.update(&marks, to: norm(value.location)); return }
              if active == nil {
                active = Mark(
                  tool: tool, color: NSColor(ink).cgColor, points: [norm(value.startLocation)],
                  strokeFraction: CGFloat(stroke)
                    / max(1, min(shot.pixels.width, shot.pixels.height)), caption: caption)
                if tool == .mosaic, let image = draft?.image ?? ImageEditor.original(shot) {
                  do {
                    active?.texture = try ImageEditor.mosaicTexture(
                      image, previous: marks, blockSize: stroke * 4)
                  } catch { failure = error.localizedDescription }
                }
              }
              if tool == .pen {
                active?.points.append(norm(value.location))
              } else {
                active?.points = [norm(value.startLocation), norm(value.location)]
              }
            }.onEnded { value in
              if let move {
                move.update(
                  &marks,
                  to: CGPoint(x: value.location.x / size.width, y: value.location.y / size.height))
                moves.finish(move, in: marks); self.move = nil; updateMosaics(); return
              }
              if let active, active.tool != .text || !active.caption.isEmpty,
                active.tool != .mosaic || active.texture != nil
              {
                marks.append(active)
              }
              active = nil
            }
          )
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }.background(ScopeTheme.card).clipShape(RoundedRectangle(cornerRadius: 9))
      if let failure { Text(failure).foregroundStyle(.red) }
    }.padding(22).frame(minWidth: 620, minHeight: 420).frame(idealWidth: 800, idealHeight: 550)
      .background(ScopeTheme.canvas).tint(ScopeTheme.accent)
      .onAppear {
        preview = (draft?.image ?? shot.thumbnail(1800)).map { NSImage(cgImage: $0, size: .zero) }
      }
  }
}
func recognizeText(_ url: URL, completion: @escaping (Result<String, Error>) -> Void) {
  DispatchQueue.global(qos: .userInitiated).async {
    let result = Result<String, Error> {
      let request = VNRecognizeTextRequest()
      request.recognitionLevel = .accurate
      let supported = try request.supportedRecognitionLanguages()
      request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"].filter(supported.contains)
      try VNImageRequestHandler(url: url).perform([request])
      return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(
        separator: "\n")
    }
    DispatchQueue.main.async { completion(result) }
  }
}
