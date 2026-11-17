import SwiftUI

enum ScopeTheme {
  static let defaultAppearance = "system"

  private static func tone(_ light: UInt32, _ dark: UInt32) -> Color {
    Color(
      nsColor: NSColor(name: nil) { appearance in
        let rgb = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        return NSColor(
          srgbRed: CGFloat((rgb >> 16) & 255) / 255,
          green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1)
      })
  }
  static let canvas = tone(0xF2F2F2, 0x0D0D0D)
  static let sidebar = tone(0xEAEAEA, 0x121212)
  static let card = tone(0xFFFFFF, 0x1C1C1C)
  static let raised = tone(0xE8E8E8, 0x303030)
  static let ink = tone(0x171717, 0xFAFAFA)
  static let accent = tone(0x343434, 0x424242)
  static let labelAccent = tone(0x414141, 0xD6D6D6)
  static let download = tone(0x0074AE, 0x19A7F5)
  static let yellow = tone(0x936900, 0xFFD642)
  static let upload = tone(0xBF4A18, 0xF16C32)
  static let live = tone(0x25733D, 0x64D977)
  static let panel = LinearGradient(colors: [card, card], startPoint: .top, endPoint: .bottom)
  static func applyAppearance(_ choice: String) {
    let name: NSAppearance.Name? = choice == "light" ? .aqua : choice == "dark" ? .darkAqua : nil
    NSApp.appearance = name.flatMap(NSAppearance.init(named:))
  }
}

// A status item can inherit its appearance from the menu bar on its display.
// Give its detached panels and menus the same effective appearance as the workspace.
final class StatusAppearance {
  private let popover: NSPopover
  private weak var menu: NSMenu?
  private var observation: NSKeyValueObservation?

  init(popover: NSPopover) {
    self.popover = popover
    observation = NSApp.observe(\.effectiveAppearance, options: [.initial, .new]) { [weak self] app, _ in
      self?.update(app.effectiveAppearance)
    }
  }

  func prepare(_ menu: NSMenu) {
    self.menu = menu
    apply(NSApp.effectiveAppearance, to: menu)
  }

  private func update(_ appearance: NSAppearance) {
    popover.appearance = appearance
    if let menu { apply(appearance, to: menu) }
  }

  private func apply(_ appearance: NSAppearance, to menu: NSMenu) {
    menu.appearance = appearance
    for item in menu.items {
      if let submenu = item.submenu { apply(appearance, to: submenu) }
    }
  }
}

// Keep related cards aligned and give labels enough room when the workspace narrows.
struct FittingColumns: Layout {
  var minimum: CGFloat
  var spacing: CGFloat
  static func count(for width: CGFloat, items: Int, minimum: CGFloat, spacing: CGFloat) -> Int {
    if CGFloat(items) * minimum + CGFloat(items - 1) * spacing <= width { return max(1, items) }
    return items >= 4 && width >= 2 * minimum + spacing ? 2 : 1
  }

  private func rows(_ width: CGFloat, _ views: Subviews) -> (columns: Int, cell: CGFloat, heights: [CGFloat]) {
    let columns = Self.count(for: width, items: views.count, minimum: minimum, spacing: spacing)
    let cell = max(0, (width - CGFloat(columns - 1) * spacing) / CGFloat(columns))
    var heights: [CGFloat] = []
    for (index, view) in views.enumerated() {
      if index % columns == 0 { heights.append(0) }
      let height = view.sizeThatFits(.init(width: cell, height: nil)).height
      heights[index / columns] = max(heights[index / columns], height)
    }
    return (columns, cell, heights)
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width.flatMap { $0.isFinite ? $0 : nil }
      ?? (minimum * CGFloat(subviews.count) + spacing * CGFloat(max(0, subviews.count - 1)))
    let heights = rows(width, subviews).heights
    return CGSize(width: width, height: heights.reduce(0,+) + spacing * CGFloat(max(0, heights.count - 1)))
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let (columns, cell, heights) = rows(bounds.width, subviews)
    var y = bounds.minY
    for (index, view) in subviews.enumerated() {
      let column = index % columns, height = heights[index / columns]
      view.place(at: CGPoint(x: bounds.minX + CGFloat(column) * (cell + spacing), y: y),
                 anchor: .topLeading, proposal: .init(width: cell, height: height))
      if column == columns - 1 { y += height + spacing }
    }
  }
}
