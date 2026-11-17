import SwiftUI

struct Workspace: View {
  @ObservedObject var studio: Studio
  @ObservedObject var captures: Captures
  @State private var deleting: Shot?
  @State private var editAfterPreview: Shot?
  @State private var textResult: String?
  @State private var recognizing = false
  var body: some View {
    HStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 5) {
          Brand(size: 33)
          Text(L("Perch")).font(.system(size: 17, weight: .semibold)).lineLimit(1)
        }.padding(.bottom, 25)
        ForEach([Page.overview, .monitor, .usage, .todos, .clipboard, .gallery]) { page in nav(page) }
        Spacer()
        Divider().padding(.bottom, 5)
        nav(.settings)
      }.padding(.horizontal, 13).padding(.top, 38).padding(.bottom, 18).fixedSize(horizontal: true, vertical: false).frame(minWidth: 160)
        .background(ScopeTheme.sidebar)
      Divider()
      VStack(alignment: .leading, spacing: 0) {
        HStack {
          Text(L(studio.page.rawValue)).font(.system(size: 28, weight: .bold))
          Spacer()
          if studio.page == .gallery {
            Button(L("打开截图文件夹")) { captures.openFolder() }
            Button(L("导入图片")) { captures.importImages() }
          }

        }.padding(.horizontal, 24).padding(.top, 28).padding(.bottom, 18)
        ScrollView {
          Group {
            switch studio.page {
            case .overview:
              Overview(
                studio: studio, monitor: studio.monitor, captures: captures, keys: studio.keys)
            case .monitor: MonitorPage(monitor: studio.monitor, initialMetric: studio.detailedMetric)
            case .usage: UsagePage(store: studio.usage)
            case .gallery: Gallery(studio: studio, captures: captures)
            case .todos: TodosPage(store:studio.todos, request:studio.requestReminderAccess)
            case .clipboard:
              ClipboardPage(
                keys: studio.keys, store: studio.clips, open: { studio.clipChooser.open() })
            case .settings: Preferences(studio: studio)
            }
          }.padding(.horizontal, 24).padding(.bottom, 24).frame(
            maxWidth: .infinity, alignment: .leading)
        }
        .id(studio.page)
        if let notice = captures.notice {
          HStack {
            Image(systemName: "info.circle")
            Text(notice).lineLimit(3)
            Spacer()
            Button {
              captures.notice = nil
            } label: {
              Image(systemName: "xmark")
            }.buttonStyle(.plain).accessibilityLabel(L("关闭提示"))
          }
          .font(.callout).padding(10).background(ScopeTheme.sidebar)
        }
      }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }.environment(\.processTablesVisible, studio.workspaceVisible).background(ScopeTheme.canvas).tint(ScopeTheme.accent)
      .sheet(
        item: $studio.inspected,
        onDismiss: {
          if let pending = editAfterPreview {
            editAfterPreview = nil
            studio.edit = pending
          }
        }
      ) { shot in
        VStack(alignment: .leading, spacing: 15) {
          HStack {
            VStack(alignment: .leading) {
              Text(shot.title).font(.title2.bold())
              Text(
                shot.date.formatted()
                  + "  ·  \(Int(shot.pixels.width)) × \(Int(shot.pixels.height)) px"
              ).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(L("完成")) { studio.inspected = nil }.keyboardShortcut(.cancelAction)
          }
          ShotImage(shot: shot, size: 1400).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
          HStack {
            Button {
              studio.pin(shot)
              studio.inspected = nil
            } label: {
              Label(L("贴到桌面"), systemImage: "pin")
            }.buttonStyle(.borderedProminent)
            Button {
              captures.copy(shot)
              studio.inspected = nil
            } label: {
              Label(L("复制"), systemImage: "doc.on.doc")
            }
            Button {
              editAfterPreview = shot
              studio.inspected = nil
            } label: {
              Label(L("标注"), systemImage: "pencil.tip")
            }
            Button {
              captures.export(shot)
            } label: {
              Label(L("导出"), systemImage: "square.and.arrow.up")
            }
            Button { captures.reveal(shot) } label: { Image(systemName: "folder") }.help(L("在访达中显示原文件")).accessibilityLabel(L("在访达中显示原文件"))
            Button(recognizing ? L("正在识别…") : L("识别文字")) {
              recognizing = true
              recognizeText(shot.url) { result in
                recognizing = false
                guard studio.inspected?.id == shot.id else { return }
                switch result {
                case .success(let text): textResult = text.isEmpty ? L("未识别到文字") : text
                case .failure(let e): textResult = L("识别失败 · ") + e.localizedDescription
                }
              }
            }.disabled(recognizing)
            Spacer()
            Button {
              deleting = shot
            } label: {
              Image(systemName: "trash")
            }.help(L("删除截图"))
          }
          if let textResult {
            ScrollView {
              Text(textResult).textSelection(.enabled).frame(
                maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 90)
          }
        }.padding(22).frame(minWidth: 620, minHeight: 420).frame(idealWidth: 780, idealHeight: 540)
          .background(ScopeTheme.canvas).tint(ScopeTheme.accent)
          .onDisappear { textResult = nil }
          .alert(
            L("删除这张截图？"),
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
          ) { item in
            Button(L("删除"), role: .destructive) {
              captures.remove(item)
              studio.inspected = nil
            }
            Button(L("取消"), role: .cancel) {}
          }
      }
      .sheet(item: $studio.edit, onDismiss: { studio.editDraft = nil }) { shot in
        EditorView(shot: shot, captures: captures, draft: studio.editDraft) { _ in
          studio.page = .gallery
          captures.notice = L("标注副本已保存，原图已保留")
        }
      }

  }
  func nav(_ page: Page) -> some View {
    Button {
      studio.detailedMetric = nil
      studio.page = page
    } label: {
      HStack(spacing: 10) {
        Image(systemName: page.symbol).frame(width: 18)
        Text(L(page.rawValue)).fontWeight(studio.page == page ? .semibold : .regular)
        Spacer()
      }
      .padding(.horizontal, 10).padding(.vertical, 10).foregroundStyle(
        studio.page == page ? Color.primary : .secondary
      )
      .background(
        studio.page == page ? ScopeTheme.raised : .clear, in: RoundedRectangle(cornerRadius: 8)
      ).contentShape(Rectangle())
    }.buttonStyle(.plain)
  }
}
struct Overview: View {
  @ObservedObject var studio: Studio
  @ObservedObject var monitor: Monitor
  @ObservedObject var captures: Captures
  @ObservedObject var keys: HotKeys
  @State private var toolHint: String?
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      ConsoleOverview(monitor: monitor) { metric in
        studio.detailedMetric = metric
        studio.page = .monitor
      }
      AwakeControl(session: studio.awake)
      HStack {
        Text(L("截图工具")).font(.title3.bold())
        Spacer()
        if let toolHint { Text(toolHint).font(.callout).foregroundStyle(.secondary) }
      }
      LazyVGrid(
        columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 9
      ) {
        ForEach(CaptureMode.allCases, id: \.self) { m in
          tool(
            m.name, m.symbol, m == .region ? L("拖动选择区域 · ") + keys.label(.capture) : (m == .window ? L("点击要截取的窗口") : L("截取整个显示器")),
            m == .region ? ScopeTheme.download : m == .window ? ScopeTheme.yellow : ScopeTheme.upload
          ) {
            studio.take(m)
          }
        }
        tool(L("剪贴板贴图"), "pin", L("将剪贴板内容固定在桌面 · ") + keys.label(.paste), .purple) { studio.pinClipboard() }
        tool(L("屏幕取色"), "eyedropper", L("点击屏幕像素复制 HEX 色值"), ScopeTheme.live) { studio.pickColor() }
        tool(L("截图库"), "photo.stack", Lf("查看已保存的 %@ 张图像", String(describing: captures.shots.count)), .teal) { studio.page = .gallery }
      }
      HStack {
        Text(L("最近截图")).font(.title3.bold())
        Spacer()
        Button(L("查看全部")) { studio.page = .gallery }.buttonStyle(.plain).foregroundStyle(ScopeTheme.labelAccent)
      }
      if captures.shots.isEmpty {
        HStack {
          Image(systemName: "photo.on.rectangle.angled").font(.title2).foregroundStyle(ScopeTheme.labelAccent)
          Text(L("还没有截图")).font(.headline)
          Spacer()
          Text(L("按 ") + keys.label(.capture) + L(" 拍下第一张")).font(.callout).foregroundStyle(.secondary)
        }.padding(16).tile()
      } else {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 155), spacing: 10)], spacing: 10) {
          ForEach(Array(captures.shots.prefix(3))) { shot in
            ShotTile(shot: shot) { studio.inspected = shot }
          }
        }
      }
    }
  }
  func stat(_ title: String, _ value: String, _ symbol: String, _ color: Color) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Label(title, systemImage: symbol).font(.caption).foregroundStyle(color)
      Text(value).font(.system(size: 21, weight: .semibold, design: .rounded)).monospacedDigit()
        .lineLimit(1).minimumScaleFactor(0.7)
    }.frame(maxWidth: .infinity, alignment: .leading).padding(13).tile()
  }
  func tool(_ name: String, _ symbol: String, _ detail: String, _ color: Color, _ action: @escaping () -> Void)
    -> some View
  {
    Button(action: action) {
      Image(systemName:symbol).font(.system(size:22,weight:.semibold)).foregroundStyle(color)
        .frame(maxWidth:.infinity,minHeight:48).tile(10).contentShape(Rectangle())
    }.buttonStyle(.plain).disabled(captures.capturing).accessibilityLabel(name).hoverInstruction(name + " · " + detail, selection: $toolHint)
  }
}
struct ShotImage: View {
  let shot: Shot
  let size: Int
  @State private var image: NSImage?
  var body: some View {
    Group {
      if let image {
        Image(nsImage: image).resizable().scaledToFit()
      } else {
        Image(systemName: "photo").foregroundStyle(.secondary)
      }
    }
    .task(id: shot.id) {
      let result = await Task.detached(priority: .utility) { shot.thumbnail(size) }.value
      if !Task.isCancelled { image = result.map { NSImage(cgImage: $0, size: .zero) } }
    }
  }
}
struct ShotTile: View {
  let shot: Shot
  let action: () -> Void
  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 0) {
        ShotImage(shot: shot, size: 420).frame(maxWidth: .infinity).frame(height: 90).background(
          .primary.opacity(0.04))
        VStack(alignment: .leading, spacing: 3) {
          Text(shot.title).font(.callout.weight(.medium))
          Text("\(Int(shot.pixels.width)) × \(Int(shot.pixels.height)) px").font(.caption2)
            .foregroundStyle(.secondary)
        }.padding(10)
      }.frame(maxWidth: .infinity, alignment: .leading).tile(10).clipShape(
        RoundedRectangle(cornerRadius: 10))
    }.buttonStyle(.plain)
  }
}
struct Gallery: View {
  @ObservedObject var studio: Studio
  @ObservedObject var captures: Captures
  @State private var deleting: Shot?
  var body: some View {
    if captures.shots.isEmpty {
      VStack(spacing: 14) {
        Image(systemName: "photo.stack").font(.system(size: 40, weight: .light)).foregroundStyle(
          ScopeTheme.accent)
        Text(L("还没有截图")).font(.title3.bold())
        Text(L("保存的截图和标注副本会出现在这里。")).foregroundStyle(.secondary)
        Button(L("开始区域截图")) { studio.take(.region) }
      }.frame(maxWidth: .infinity).padding(.vertical, 85).tile()
    } else {
      let groups = Dictionary(grouping: captures.shots) {
        Calendar.current.startOfDay(for: $0.date)
      }
      VStack(alignment: .leading, spacing: 15) {
        ForEach(groups.keys.sorted(by: >), id: \.self) { date in
          Text(date.formatted(date: .long, time: .omitted)).font(.headline).foregroundStyle(
            .secondary)
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 185), spacing: 12)], spacing: 12) {
            ForEach(groups[date] ?? []) { shot in
              VStack(spacing: 4) {
                ShotTile(shot: shot) { studio.inspected = shot }
                HStack {
                  Button { captures.reveal(shot) } label: { Label(L("访达中显示"), systemImage: "folder") }
                  Spacer()
                  Button { deleting = shot } label: { Label(L("删除"), systemImage: "trash") }
                }.buttonStyle(.plain).font(.caption).padding(.horizontal, 8).padding(.vertical, 4)
              }.contextMenu {
                Button(L("贴到桌面")) { studio.pin(shot) }
                Button(L("复制图像")) { captures.copy(shot) }
                Button(L("标注")) { studio.edit = shot }
                Button(L("导出 PNG")) { captures.export(shot) }
                Button(L("在访达中显示原文件")) { captures.reveal(shot) }
                Button(L("删除截图"), role: .destructive) { deleting = shot }
              }
            }
          }
        }
      }.alert(L("删除这张截图？"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { shot in
        Button(L("删除"), role: .destructive) { captures.remove(shot) }
        Button(L("取消"), role: .cancel) {}
      }
    }
  }
}
