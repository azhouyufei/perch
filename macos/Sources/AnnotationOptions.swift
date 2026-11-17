import SwiftUI

enum AnnotationOption: String {
  case width = "线宽"
  case color = "颜色"
  static let widths = [1, 2, 4, 6, 8, 12, 16]
  static let colors = [
    (L("黑"), "171717"), (L("灰"), "81858C"), (L("白"), "FFFFFF"), (L("红"), "FF453A"),
    (L("橙"), "FF8A30"), (L("黄"), "FFDA42"), (L("绿"), "38C96F"), (L("青"), "27C8BA"),
    (L("天蓝"), "45C7F4"), (L("蓝"), "3486FF"), (L("靛"), "595AD8"), (L("紫"), "AE64E8"),
    (L("洋红"), "DC43A5"), (L("粉"), "FF85A7"), (L("棕"), "986947"), (L("深绿"), "17774E"),
  ]
  static func decode(_ text: String) -> NSColor? {
    var hex = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if hex.first == "#" { hex.removeFirst() }
    guard hex.count == 6,
      hex.utf8.allSatisfy({
        (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
      }), let n = Int(hex, radix: 16)
    else { return nil }
    return NSColor(
      srgbRed: CGFloat(n >> 16) / 255, green: CGFloat((n >> 8) & 255) / 255,
      blue: CGFloat(n & 255) / 255, alpha: 1)
  }
  static func hex(_ color: NSColor) -> String {
    guard let rgb = color.usingColorSpace(.sRGB) else { return "" }
    return String(
      format: "%02X%02X%02X", Int((rgb.redComponent * 255).rounded()),
      Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
  }
}
struct AnnotationOptions: View {
  let option: AnnotationOption, width: Int, current: NSColor
  let chooseWidth: (Int) -> Void, chooseColor: (NSColor) -> Void
  @State private var hue: Double
  @State private var saturation: Double
  @State private var brightness: Double
  init(
    _ option: AnnotationOption, width: Int, current: NSColor, chooseWidth: @escaping (Int) -> Void,
    chooseColor: @escaping (NSColor) -> Void
  ) {
    self.option = option
    self.width = width
    self.current = current
    self.chooseWidth = chooseWidth
    self.chooseColor = chooseColor
    let rgb = current.usingColorSpace(.sRGB) ?? .red
    _hue = State(initialValue: rgb.hueComponent);
    _saturation = State(initialValue: rgb.saturationComponent);
    _brightness = State(initialValue: rgb.brightnessComponent)
  }
  private var picked: NSColor {
    NSColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1).usingColorSpace(
      .sRGB) ?? .black
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(L(option.rawValue)).font(.headline)
      if option == .width {
        ForEach(AnnotationOption.widths, id: \.self) { n in
          Button {
            chooseWidth(n)
          } label: {
            HStack {
              Text("\(n) px").frame(width: 40, alignment: .leading)
              Capsule().fill(Color.primary).frame(width: 76, height: CGFloat(n))
              Spacer()
              if width == n { Image(systemName: "checkmark") }
            }.frame(height: 20).contentShape(Rectangle())
          }.buttonStyle(.plain)
        }
      } else {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: 8) {
          ForEach(AnnotationOption.colors.indices, id: \.self) { i in
            let (name, hex) = AnnotationOption.colors[i]
            if let c = AnnotationOption.decode(hex) {
              Button {
                chooseColor(c)
              } label: {
                Circle().fill(Color(nsColor: c)).overlay(
                  Circle().strokeBorder(.primary.opacity(0.25))
                )
                .overlay {
                  if hex == AnnotationOption.hex(current) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, .black)
                  }
                }
                .frame(width: 21, height: 21)
              }.buttonStyle(.plain).help(name).accessibilityLabel(name)
            }
          }
        }
        let base = Color(hue: hue, saturation: 1, brightness: 1)
        GeometryReader { g in
          ZStack(alignment: .topLeading) {
            LinearGradient(colors: [.white, base], startPoint: .leading, endPoint: .trailing)
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
            Circle().strokeBorder(.black.opacity(0.7), lineWidth: 3).overlay(
              Circle().strokeBorder(.white, lineWidth: 1.5)
            ).frame(width: 12, height: 12)
              .position(
                x: max(6, min(g.size.width - 6, saturation * g.size.width)),
                y: max(6, min(g.size.height - 6, (1 - brightness) * g.size.height)))
          }.clipShape(RoundedRectangle(cornerRadius: 5)).contentShape(Rectangle())
            .gesture(
              DragGesture(minimumDistance: 0).onChanged { v in
                saturation = max(0, min(1, Double(v.location.x / g.size.width)));
                brightness = max(0, min(1, 1.0 - Double(v.location.y / g.size.height)))
              }
            )
            .accessibilityRepresentation {
              VStack {
                Slider(value: $saturation, in: 0...1) { Text(L("饱和度")) };
                Slider(value: $brightness, in: 0...1) { Text(L("亮度")) }
              }
            }
        }.frame(height: 92)
        GeometryReader { g in
          ZStack(alignment: .leading) {
            LinearGradient(
              colors: (0...6).map { Color(hue: Double($0) / 6, saturation: 1, brightness: 1) },
              startPoint: .leading, endPoint: .trailing
            ).clipShape(Capsule())
            Capsule().strokeBorder(.white, lineWidth: 2).shadow(radius: 1).frame(width: 7).offset(
              x: hue * (g.size.width - 7))
          }.contentShape(Rectangle()).gesture(
            DragGesture(minimumDistance: 0).onChanged { v in
              hue = max(0, min(1, Double(v.location.x / g.size.width)))
            }
          )
          .accessibilityRepresentation { Slider(value: $hue, in: 0...1) { Text(L("色相")) } }
        }.frame(height: 12)
        HStack {
          Circle().fill(Color(nsColor: picked)).frame(width: 18, height: 18).overlay(
            Circle().strokeBorder(.secondary.opacity(0.4)))
          Text(L("自定义颜色")).font(.caption); Spacer(); Button(L("使用此颜色")) { chooseColor(picked) }
        }
      }
    }.padding(12).frame(width: option == .width ? 202 : 258).background(ScopeTheme.card)
  }
}
