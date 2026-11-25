import AppKit
import SwiftUI

struct CompareView: View {
    @Bindable var model: AppModel
    @State private var mode = "side"
    @State private var focus: Int?
    @State private var showLegend = false
    @State private var findOpen = false
    @State private var findQuery = ""
    @State private var selectedSide = ""
    @FocusState private var findFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if let document = model.compare {
                HStack(spacing: 8) {
                    revisionMenu(document.leftTitle, left: true)
                    Spacer()
                    Text((document.path as NSString).lastPathComponent).font(.headline).lineLimit(1)
                    if document.leftImage != nil || document.rightImage != nil {
                        Picker("", selection: $mode) {
                            Text(model.t("compare.sideBySide")).tag("side")
                            Text(model.t("compare.wipe")).tag("wipe")
                            Text(model.t("compare.pixels")).tag("pixels")
                        }.pickerStyle(.segmented).frame(width: 280)
                    }
                    Spacer()
                    revisionMenu(document.rightTitle, left: false)
                    Button(model.t("compare.previous")) { step(-1) }
                    Button(model.t("compare.next")) { step(1) }
                    Button(model.t("compare.find")) { findOpen = true; findFocused = true }
                    Button(model.t("action.showAnnotations")) { showLegend.toggle() }
                        .disabled((model.compare?.blame ?? []).isEmpty)
                }
                .padding(6)
                if findOpen {
                    HStack {
                        TextField(model.t("compare.find"), text: $findQuery)
                            .textFieldStyle(.roundedBorder)
                            .focused($findFocused)
                        Button(model.t("compare.previous")) { stepMatch(-1) }
                        Button(model.t("compare.next")) { stepMatch(1) }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
                }
                if document.propertyOnly {
                    Text(model.t("compare.properties")).font(.caption).foregroundStyle(.secondary)
                }
                if showLegend { legend }
                if let left = document.leftImage, let right = document.rightImage, let a = NSImage(data: left), let b = NSImage(data: right) {
                    ImageCompare(left: a, right: b, mode: mode)
                } else if document.leftText.utf8.contains(0) || document.rightText.utf8.contains(0) {
                    VStack {
                        ContentUnavailableView(model.t("compare.binary"), systemImage: "doc")
                        Text("\(document.leftText.utf8.count) / \(document.rightText.utf8.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    SideBySideDiff(
                        rows: document.rows,
                        path: document.path,
                        showNumbers: model.preferences.showLineNumbers,
                        showInline: model.preferences.showInline,
                        showInvisibles: model.preferences.showInvisibles,
                        blame: model.preferences.showAnnotations ? document.blame : [],
                        editable: document.editable,
                        focus: focus,
                        fontSize: CGFloat(model.preferences.fontSize),
                        tabWidth: model.preferences.tabWidth,
                        fontName: model.preferences.fontName,
                        query: findQuery,
                        selectedSide: selectedSide,
                        onApply: { model.applyHunk(at: $0) },
                        onDiscard: { model.discardHunk(at: $0) },
                        onEdit: { model.replaceWorkingLine($0, $1) }
                    )
                }
            } else {
                ContentUnavailableView(model.t("empty.selectFile"), systemImage: "doc.text.magnifyingglass")
            }
        }
        .background {
            Group {
                Button("") { findOpen = true; findFocused = true }.keyboardShortcut("f", modifiers: .command)
                Button("") { selectSide("left") }.keyboardShortcut("a", modifiers: .command)
                Button("") { selectSide("right") }.keyboardShortcut("a", modifiers: [.command, .option])
                Button("") { stepMatch(1) }.keyboardShortcut("g", modifiers: .command)
                Button("") { stepMatch(-1) }.keyboardShortcut("g", modifiers: [.command, .shift])
            }
            .opacity(0)
            .frame(width: 0, height: 0)
        }
    }

    private func selectSide(_ side: String) {
        selectedSide = side
        let text = side == "left" ? model.compare?.leftText : model.compare?.rightText
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text ?? "", forType: .string)
    }

    private func stepMatch(_ direction: Int) {
        let query = findQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        let hits = (model.compare?.rows ?? []).filter {
            $0.left.localizedCaseInsensitiveContains(query) || $0.right.localizedCaseInsensitiveContains(query)
        }.map(\.id)
        guard !hits.isEmpty else { return }
        let current = hits.firstIndex(of: focus ?? -1) ?? (direction > 0 ? -1 : 0)
        let next = (current + direction + hits.count) % hits.count
        focus = hits[next]
    }

    private var legend: some View {
        HStack(spacing: 16) {
            Label(model.t("log.added"), systemImage: "circle.fill").foregroundStyle(.green)
            Label(model.t("log.deleted"), systemImage: "circle.fill").foregroundStyle(.red)
            Label(model.t("log.modified"), systemImage: "circle.fill").foregroundStyle(.orange)
            Text(model.t("action.showAnnotations")).foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.bottom, 4)
    }

    private func revisionMenu(_ title: String, left: Bool) -> some View {
        Menu(title) {
            ForEach(["BASE", "WORKING", "HEAD", "PREVIOUS"], id: \.self) { revision in
                Button(revision) { Task { await model.setCompareRevision(left: left, revision: revision) } }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func step(_ direction: Int) {
        let hunks = TextDiff.hunks(model.compare?.rows ?? [])
        guard !hunks.isEmpty else { return }
        let current = hunks.firstIndex { range in
            if let focus { return range.contains(focus) }
            return false
        } ?? (direction > 0 ? -1 : hunks.count)
        let next = min(max(current + direction, 0), hunks.count - 1)
        focus = hunks[next].lowerBound
    }
}

struct SideBySideDiff: View {
    var rows: [DiffRow]
    var path: String
    var showNumbers = true
    var showInline = true
    var showInvisibles = false
    var blame: [BlameLine] = []
    var editable = false
    var focus: Int?
    var fontSize: CGFloat = 12
    var tabWidth: Int = 4
    var fontName: String = "Menlo"
    var query: String = ""
    var selectedSide: String = ""
    var onApply: (Int) -> Void = { _ in }
    var onDiscard: (Int) -> Void = { _ in }
    var onEdit: (Int, String) -> Void = { _, _ in }
    @State private var editing: Int?
    @State private var draft = ""

    var body: some View {
        ScrollViewReader { proxy in
            HStack(spacing: 0) {
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { row in
                            HStack(alignment: .top, spacing: 0) {
                                line(display(row.left), number: row.leftNumber, kind: leftKind(row), other: row.right, blameLine: nil, side: "left", rowID: row.id)
                                Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1)
                                line(display(row.right), number: row.rightNumber, kind: rightKind(row), other: row.left, blameLine: blame.first { $0.line == row.rightNumber }, side: "right", rowID: row.id)
                                if editable, row.kind != .same {
                                    VStack(spacing: 2) {
                                        Button("←") { if let hunk = hunkIndex(row) { onApply(hunk) } }
                                        Button("×") { if let hunk = hunkIndex(row) { onDiscard(hunk) } }
                                    }
                                    .font(.caption2)
                                    .buttonStyle(.borderless)
                                }
                            }
                            .id(row.id)
                        }
                    }
                }
                markerRail(proxy)
            }
            .onAppear { scroll(proxy, to: focus ?? rows.first { $0.kind != .same }?.id) }
            .onChange(of: focus) { _, value in scroll(proxy, to: value) }
        }
    }

    private func markerRail(_ proxy: ScrollViewProxy) -> some View {
        GeometryReader { geo in
            let changed = rows.filter { $0.kind != .same }
            let total = max(rows.count, 1)
            ForEach(changed) { row in
                let color: Color = row.kind == .delete ? .red : (row.kind == .insert ? .green : .orange)
                Button {
                    proxy.scrollTo(row.id, anchor: .center)
                } label: {
                    RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 8, height: 4)
                }
                .buttonStyle(.plain)
                .position(x: 6, y: max(4, geo.size.height * (CGFloat(row.id) + 0.5) / CGFloat(total)))
            }
        }
        .frame(width: 12)
        .background(Color(nsColor: .separatorColor).opacity(0.15))
    }

    private func scroll(_ proxy: ScrollViewProxy, to id: Int?) {
        if let id { proxy.scrollTo(id, anchor: .center) }
    }

    private func hunkIndex(_ row: DiffRow) -> Int? {
        TextDiff.hunks(rows).firstIndex { $0.contains(row.id) }
    }

    private func leftKind(_ row: DiffRow) -> DiffRow.Kind {
        switch row.kind {
        case .insert: return .same
        case .delete, .change: return row.kind
        case .same: return .same
        }
    }

    private func rightKind(_ row: DiffRow) -> DiffRow.Kind {
        switch row.kind {
        case .delete: return .same
        case .insert, .change: return row.kind
        case .same: return .same
        }
    }

    private var modelFont: CGFloat { fontSize }

    private func display(_ text: String) -> String {
        let expanded = text.replacingOccurrences(of: "\t", with: String(repeating: " ", count: max(1, tabWidth)))
        guard showInvisibles else { return expanded }
        return expanded.replacingOccurrences(of: " ", with: "·")
    }

    private func line(_ text: String, number: Int?, kind: DiffRow.Kind, other: String, blameLine: BlameLine?, side: String, rowID: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if showNumbers {
                Text(number.map(String.init) ?? "")
                    .font(.custom(fontName, size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(width: 36, alignment: .trailing)
            }
            if let blameLine {
                Text(blameLine.author)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(width: 72, alignment: .leading)
                    .lineLimit(1)
            }
            if side == "right", editable, editing == rowID {
                TextField("", text: $draft)
                    .font(.custom(fontName, size: modelFont))
                    .onSubmit {
                        if let number { onEdit(number, draft) }
                        editing = nil
                    }
            } else {
                Text(highlighted(text, other: showInline && kind == .change ? other : nil))
                    .font(.custom(fontName, size: modelFont))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .onTapGesture(count: 2) {
                        guard side == "right", editable, number != nil else { return }
                        draft = text
                        editing = rowID
                    }
            }
        }
        .padding(.vertical, 1)
        .padding(.trailing, 8)
        .frame(minWidth: 420, alignment: .leading)
        .background(background(kind))
        .overlay(selectedSide == side ? Color.accentColor.opacity(0.12) : Color.clear)
    }

    private func background(_ kind: DiffRow.Kind) -> Color {
        switch kind {
        case .insert: return Color.green.opacity(0.22)
        case .delete: return Color.red.opacity(0.16)
        case .change: return Color.green.opacity(0.18)
        case .same: return .clear
        }
    }

    private func highlighted(_ line: String, other: String?) -> AttributedString {
        var text = AttributedString(line.isEmpty ? " " : line)
        text.foregroundColor = .primary
        let source = line
        for word in SyntaxColor.keywords(for: path) where word.count > 1 {
            var search = source.startIndex
            while let range = source.range(of: word, range: search..<source.endIndex) {
                let before = range.lowerBound == source.startIndex || !source[source.index(before: range.lowerBound)].isLetter
                let after = range.upperBound == source.endIndex || !source[range.upperBound].isLetter
                if before && after, let lower = AttributedString.Index(range.lowerBound, within: text), let upper = AttributedString.Index(range.upperBound, within: text) {
                    text[lower..<upper].foregroundColor = .purple
                }
                search = range.upperBound
            }
        }
        if !query.isEmpty {
            var search = source.startIndex
            while let range = source.range(of: query, options: .caseInsensitive, range: search..<source.endIndex) {
                if let lower = AttributedString.Index(range.lowerBound, within: text), let upper = AttributedString.Index(range.upperBound, within: text), lower < upper {
                    text[lower..<upper].backgroundColor = Color.orange.opacity(0.55)
                }
                if range.upperBound == source.endIndex { break }
                search = range.upperBound
            }
        }
        if let other {
            let limit = min(line.count, other.count)
            let chars = Array(line)
            let theirs = Array(other)
            var i = 0
            while i < limit, chars[i] == theirs[i] { i += 1 }
            var j = 0
            while j < limit - i, chars[chars.count - 1 - j] == theirs[theirs.count - 1 - j] { j += 1 }
            if i < chars.count - j {
                let start = line.index(line.startIndex, offsetBy: i)
                let end = line.index(line.endIndex, offsetBy: -j)
                if let lower = AttributedString.Index(start, within: text), let upper = AttributedString.Index(end, within: text), lower < upper {
                    text[lower..<upper].backgroundColor = Color.yellow.opacity(0.45)
                }
            }
        }
        return text
    }
}

struct DiffText: NSViewRepresentable {
    var rows: [DiffRow]
    var blame: [BlameLine]
    var showInvisibles: Bool
    var path: String = ""

    func makeNSView(context: Context) -> NSScrollView {
        let text = NSTextView()
        text.isEditable = false
        text.isRichText = true
        text.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        text.textContainerInset = NSSize(width: 8, height: 8)
        let scroll = NSScrollView()
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? NSTextView else { return }
        text.textStorage?.setAttributedString(render())
    }

    private func render() -> NSAttributedString {
        let result = NSMutableAttributedString()
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        for row in rows {
            let color: NSColor
            switch row.kind {
            case .insert: color = NSColor(calibratedRed: 0.85, green: 0.97, blue: 0.88, alpha: 1)
            case .delete: color = NSColor(calibratedRed: 0.99, green: 0.91, blue: 0.85, alpha: 1)
            case .change: color = NSColor(calibratedRed: 0.90, green: 0.94, blue: 1, alpha: 1)
            case .same: color = .textBackgroundColor
            }
            let leftNo = row.leftNumber.map(String.init) ?? ""
            let rightNo = row.rightNumber.map(String.init) ?? ""
            var left = row.left
            var right = row.right
            if showInvisibles {
                left = left.replacingOccurrences(of: " ", with: "·").replacingOccurrences(of: "\t", with: "→")
                right = right.replacingOccurrences(of: " ", with: "·").replacingOccurrences(of: "\t", with: "→")
            }
            let blameText = blame.first { $0.line == row.rightNumber }.map { " \($0.author) r\($0.revision)" } ?? ""
            let prefix = "\(leftNo.padding(toLength: 5, withPad: " ", startingAt: 0)) | \(rightNo.padding(toLength: 5, withPad: " ", startingAt: 0)) "
            result.append(NSAttributedString(string: prefix, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor, .backgroundColor: color]))
            result.append(colored(left, font: font, background: color))
            result.append(NSAttributedString(string: "  |  ", attributes: [.font: font, .backgroundColor: color]))
            result.append(colored(right + blameText, font: font, background: color))
            result.append(NSAttributedString(string: "\n", attributes: [.font: font, .backgroundColor: color]))
        }
        return result
    }

    private func colored(_ line: String, font: NSFont, background: NSColor) -> NSAttributedString {
        let text = NSMutableAttributedString(string: line, attributes: [.font: font, .backgroundColor: background, .foregroundColor: NSColor.labelColor])
        let words = SyntaxColor.keywords(for: path)
        for word in words {
            var search = line.startIndex
            while let range = line.range(of: word, range: search..<line.endIndex) {
                let before = range.lowerBound == line.startIndex || !line[line.index(before: range.lowerBound)].isLetter
                let after = range.upperBound == line.endIndex || !line[range.upperBound].isLetter
                if before && after {
                    let ns = NSRange(range, in: line)
                    text.addAttribute(.foregroundColor, value: NSColor.systemPurple, range: ns)
                }
                search = range.upperBound
            }
        }
        return text
    }
}

struct ImageCompare: View {
    var left: NSImage
    var right: NSImage
    var mode: String
    @State private var fit = true
    @State private var magnification: CGFloat = 1
    @State private var split = 0.5

    var body: some View {
        VStack {
            HStack {
                Button(modelFit) { fit.toggle() }
                Button("−") { magnification = max(0.25, magnification - 0.25) }
                Button("+") { magnification = min(4, magnification + 0.25) }
            }
            .buttonStyle(.borderless)
            GeometryReader { proxy in
                imageBody(proxy)
                    .scaleEffect(fit ? 1 : magnification)
            }
        }
    }

    private var modelFit: String { fit ? "1:1" : "Fit" }

    @ViewBuilder private func imageBody(_ proxy: GeometryProxy) -> some View {
            ZStack {
                if mode == "pixels" {
                    Image(nsImage: difference())
                        .resizable()
                        .scaledToFit()
                } else if mode == "wipe" {
                    Image(nsImage: left).resizable().scaledToFit()
                    Image(nsImage: right).resizable().scaledToFit().mask(alignment: .leading) {
                        Rectangle().frame(width: proxy.size.width * split)
                    }
                    Rectangle().frame(width: 1).offset(x: proxy.size.width * (split - 0.5))
                        .gesture(DragGesture().onChanged { split = min(1, max(0, $0.location.x / proxy.size.width)) })
                } else {
                    HStack {
                        Image(nsImage: left).resizable().scaledToFit()
                        Image(nsImage: right).resizable().scaledToFit()
                    }
                }
            }
    }

    private func difference() -> NSImage {
        let width = min(Int(left.size.width), 1200)
        let height = min(Int(left.size.height), 1200)
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        left.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        right.draw(in: NSRect(x: 0, y: 0, width: width, height: height), from: .zero, operation: .difference, fraction: 1)
        image.unlockFocus()
        return image
    }
}

struct LogView: View {
    @Bindable var model: AppModel
    @State private var logFilter = "all"
    @State private var query = ""

    var body: some View {
        ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(sections) { section in
                        Text(section.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 18)
                            .padding(.bottom, 8)
                        ForEach(section.entries) { entry in
                            logRow(entry)
                            Divider().padding(.leading, 20)
                        }
                    }
                }
                .padding(.bottom, 12)
            }
            .safeAreaBar(edge: .top) { filterBar }
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 6) {
                    ForEach(filters, id: \.0) { key, title in
                        let selected = logFilter == key
                        Button(model.t(title)) { logFilter = key }
                            .buttonStyle(.plain)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .glassEffect(selected ? .regular.interactive() : .clear.interactive(), in: Capsule())
                            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    }
                }
            }
            }
            TextField(model.t("filter.search"), text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background {
            Group {
                Button("") { logFilter = "all" }.keyboardShortcut("a", modifiers: .control)
                Button("") { logFilter = "mine" }.keyboardShortcut("y", modifiers: .control)
                Button("") { logFilter = "others" }.keyboardShortcut("p", modifiers: .control)
                Button("") { logFilter = "newer" }.keyboardShortcut("n", modifiers: .control)
                Button("") { logFilter = "today" }.keyboardShortcut("t", modifiers: .control)
                Button("") { logFilter = "week" }.keyboardShortcut("w", modifiers: .control)
                Button("") { logFilter = "month" }.keyboardShortcut("m", modifiers: .control)
                Button("") { logFilter = "added" }.keyboardShortcut("e", modifiers: .control)
                Button("") { logFilter = "deleted" }.keyboardShortcut("d", modifiers: .control)
                Button("") { logFilter = "replaced" }.keyboardShortcut("r", modifiers: .control)
            }
            .opacity(0)
            .frame(width: 0, height: 0)
        }
    }

    private var filters: [(String, String)] {
        [("all", "filter.all"), ("mine", "filter.mine"), ("others", "filter.others"), ("newer", "filter.newer"), ("today", "filter.today"), ("week", "filter.thisWeek"), ("month", "filter.thisMonth"), ("added", "filter.added"), ("deleted", "filter.deleted"), ("replaced", "filter.replaced")]
    }

    private var sections: [LogDay] {
        let items = logsFiltered(model.logs, filter: logFilter, username: model.suggestedUsername().isEmpty ? NSUserName() : model.suggestedUsername(), query: query, workingRevision: workingRevision)
        let calendar = Calendar.current
        var order: [Date] = []
        var grouped: [Date: [LogEntry]] = [:]
        for entry in items {
            let day = calendar.startOfDay(for: entry.date ?? .distantPast)
            if grouped[day] == nil { order.append(day) }
            grouped[day, default: []].append(entry)
        }
        return order.map { day in
            LogDay(id: day, title: day.formatted(.dateTime.weekday(.wide).month(.wide).day().year().locale(model.language.locale)), entries: grouped[day] ?? [])
        }
    }

    private var workingRevision: Int { Int(model.info.lastChangedRev) ?? 0 }

    private func logRow(_ entry: LogEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.revision.formatted(.number.locale(model.language.locale)))
                    .font(.system(size: 22, weight: .regular, design: .default))
                if entry.revision == workingRevision {
                    Text(model.t("log.working"))
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                Spacer()
                if workingRevision > 0 {
                    Button(model.t("action.update")) { Task { await model.updateToRevision(entry.revision) } }
                        .buttonStyle(.borderless)
                }
                if workingRevision > 0, entry.revision < workingRevision {
                    Button(model.t("log.revertTo")) { Task { await model.revertToRevision(entry.revision) } }
                        .buttonStyle(.borderless)
                }
                Button(model.t("action.copyURL")) { copyLog(entry) }
                    .buttonStyle(.borderless)
                ShareLink(item: "r\(entry.revision) \(entry.author)\n\(entry.message)")
                Text(meta(entry))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            linkedMessage(entry)
            DisclosureGroup(model.t("log.changes").uppercased()) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(changeGroups(entry), id: \.action) { group in
                        Text(actionTitle(group.action))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        ForEach(group.changes) { change in
                            Button {
                                model.selectedLogRevision = entry.revision
                                Task { await model.showLogChange(entry, change: change) }
                            } label: {
                                HStack(alignment: .center, spacing: 8) {
                                    Text(change.action)
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(.white)
                                        .frame(width: 18, height: 18)
                                        .background(actionColor(change.action), in: RoundedRectangle(cornerRadius: 4))
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text((change.path as NSString).lastPathComponent)
                                            .font(.body)
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Text(change.path)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.top, 6)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(model.selectedLogRevision == entry.revision ? Color.accentColor.opacity(0.08) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { model.selectedLogRevision = entry.revision }
    }

    private func copyLog(_ entry: LogEntry) {
        let date = entry.date?.formatted() ?? ""
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("r\(entry.revision) \(entry.author) \(date)\n\(entry.message)", forType: .string)
    }

    private func linkedMessage(_ entry: LogEntry) -> some View {
        let message = entry.message.isEmpty ? " " : entry.message
        let rules = model.selectedRepository.map { model.library.issueRules(repo: $0.id) } ?? []
        if let rule = rules.first, let regex = try? NSRegularExpression(pattern: rule.pattern) {
            let ns = message as NSString
            let matches = regex.matches(in: message, range: NSRange(location: 0, length: ns.length))
            if !matches.isEmpty {
                var pieces: [String] = []
                var cursor = 0
                for match in matches {
                    if match.range.location > cursor {
                        pieces.append(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
                    }
                    pieces.append(ns.substring(with: match.range))
                    cursor = match.range.location + match.range.length
                }
                if cursor < ns.length { pieces.append(ns.substring(from: cursor)) }
                return AnyView(HStack(spacing: 0) {
                    ForEach(Array(pieces.enumerated()), id: \.offset) { _, piece in
                        if regex.firstMatch(in: piece, range: NSRange(location: 0, length: (piece as NSString).length)) != nil {
                            let number = piece.filter(\.isNumber)
                            if !number.isEmpty, let url = URL(string: rule.urlTemplate.replacingOccurrences(of: "{number}", with: number)) {
                                Link(piece, destination: url)
                            } else {
                                Text(piece)
                            }
                        } else {
                            Text(piece)
                        }
                    }
                }.font(.body).frame(maxWidth: .infinity, alignment: .leading))
            }
        }
        return AnyView(Text(message).font(.body).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled))
    }

    private func changeGroups(_ entry: LogEntry) -> [(action: String, changes: [LogPathChange])] {
        let order = ["M", "A", "D", "R"]
        return order.compactMap { action in
            let items = entry.changes.filter { $0.action == action }
            return items.isEmpty ? nil : (action, items)
        }
    }

    private func actionTitle(_ action: String) -> String {
        switch action {
        case "A": return model.t("log.added")
        case "D": return model.t("log.deleted")
        case "R": return model.t("log.replaced")
        default: return model.t("log.modified")
        }
    }

    private func actionColor(_ action: String) -> Color {
        switch action {
        case "A": return .green
        case "D": return .secondary
        case "R": return .pink
        default: return .blue
        }
    }

    private func meta(_ entry: LogEntry) -> String {
        guard let date = entry.date else { return entry.author }
        let time = date.formatted(date: .omitted, time: .shortened)
        let ago = date.formatted(.relative(presentation: .named).locale(model.language.locale))
        return "\(entry.author)  ·  \(time)  ·  \(ago)"
    }
}

private struct LogDay: Identifiable {
    var id: Date
    var title: String
    var entries: [LogEntry]
}

func logsFiltered(_ entries: [LogEntry], filter: String, username: String, query: String = "", workingRevision: Int = 0) -> [LogEntry] {
    let calendar = Calendar.current
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return entries.filter { entry in
        if !needle.isEmpty {
            let hay = "\(entry.author) \(entry.message) \(entry.changes.map(\.path).joined(separator: " "))".lowercased()
            if !hay.contains(needle) { return false }
        }
        switch filter {
        case "mine": return entry.author == username
        case "others": return !username.isEmpty && entry.author != username
        case "newer": return workingRevision > 0 && entry.revision > workingRevision
        case "today": return entry.date.map { calendar.isDateInToday($0) } ?? false
        case "week": return entry.date.map { calendar.isDate($0, equalTo: Date(), toGranularity: .weekOfYear) } ?? false
        case "month": return entry.date.map { calendar.isDate($0, equalTo: Date(), toGranularity: .month) } ?? false
        case "added": return entry.changes.contains { $0.action == "A" }
        case "deleted": return entry.changes.contains { $0.action == "D" }
        case "replaced": return entry.changes.contains { $0.action == "R" }
        default: return true
        }
    }
}

struct TimelineView: View {
    @Bindable var model: AppModel
    @State private var filter = "all"
    @State private var query = ""
    @State private var author = ""
    @State private var revisionFrom = ""
    @State private var revisionTo = ""
    @State private var useDates = false
    @State private var dateFrom = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var dateTo = Date()
    @State private var picks: [Int] = []
    @State private var compared: [Int] = []
    @State private var ancestors: [LogEntry] = []
    @State private var ancestorTitle = ""

    private let slot: CGFloat = 76

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            if model.logs.isEmpty {
                ContentUnavailableView(model.t("empty.selectFile"), systemImage: "timeline.selection")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if !ancestors.isEmpty {
                    ancestorTrack
                }
                if model.selectedPaths.count > 1 {
                    ForEach(model.selectedPaths, id: \.self) { path in
                        axis(path)
                    }
                } else {
                    track
                }
                Divider()
                if showsCompare {
                    CompareView(model: model)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView(model.t("timeline.prompt"), systemImage: "timeline.selection")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { if model.logs.isEmpty { await model.loadLog(switchMode: false) } }
    }

    private var showsCompare: Bool {
        guard model.compare != nil else { return false }
        if picks.isEmpty { return true }
        return picks.count == 2 && compared == picks.sorted()
    }

    private var entries: [LogEntry] {
        let source: [LogEntry]
        if filter == "last10" {
            source = Array(model.logs.prefix(10))
        } else {
            source = logsFiltered(model.logs, filter: filter, username: "", query: query)
        }
        return source.filter { entry in
            if !author.isEmpty, !entry.author.localizedCaseInsensitiveContains(author) { return false }
            if let from = Int(revisionFrom), entry.revision < from { return false }
            if let to = Int(revisionTo), entry.revision > to { return false }
            if useDates, let date = entry.date, date < dateFrom || date > dateTo { return false }
            return true
        }.sorted { $0.revision < $1.revision }
    }

    private var targetName: String {
        if let path = model.selectedPaths.first, !path.isEmpty {
            return (path as NSString).lastPathComponent
        }
        if !model.browserRoot.isEmpty { return (model.browserRoot as NSString).lastPathComponent }
        return model.selectedWorkingCopy?.name ?? model.selectedRepository?.nickname ?? ""
    }

    private var filterBar: some View {
        HStack(spacing: 14) {
            ForEach(["all", "last10", "today", "week", "month"], id: \.self) { key in
                Button(chipTitle(key)) { filter = key }
                    .buttonStyle(.plain)
                    .font(.caption.weight(filter == key ? .semibold : .regular))
                    .foregroundStyle(filter == key ? Color.accentColor : Color.secondary)
            }
            Spacer()
            TextField(model.t("timeline.author"), text: $author)
                .textFieldStyle(.roundedBorder)
                .frame(width: 100)
            TextField(model.t("field.revision"), text: $revisionFrom)
                .textFieldStyle(.roundedBorder)
                .frame(width: 64)
            TextField(model.t("field.revision"), text: $revisionTo)
                .textFieldStyle(.roundedBorder)
                .frame(width: 64)
            Toggle(model.t("column.date"), isOn: $useDates)
                .toggleStyle(.checkbox)
            if useDates {
                DatePicker("", selection: $dateFrom, displayedComponents: .date).labelsHidden()
                DatePicker("", selection: $dateTo, displayedComponents: .date).labelsHidden()
            }
            TextField(model.t("filter.search"), text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(width: 140)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func axis(_ path: String) -> some View {
        HStack {
            Text((path as NSString).lastPathComponent)
                .frame(width: 160, alignment: .leading)
                .lineLimit(1)
            ScrollView(.horizontal, showsIndicators: false) {
                ZStack {
                    Capsule().fill(Color.secondary.opacity(0.35)).frame(height: 2)
                    HStack(spacing: 8) {
                        ForEach(entries.filter { $0.changes.contains { $0.path.hasSuffix(path) || path.hasSuffix($0.path) } }) { entry in
                            nodeButton(entry, path: path)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 8)
    }

    private var ancestorTrack: some View {
        HStack {
            Text(ancestorTitle).lineLimit(1).frame(width: 160, alignment: .leading)
            ScrollView(.horizontal, showsIndicators: false) {
                ZStack {
                    Capsule().fill(Color.purple.opacity(0.45)).frame(height: 2)
                    HStack(spacing: 8) {
                        ForEach(ancestors) { entry in
                            nodeButton(entry, path: "")
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 8)
    }

    private func nodeButton(_ entry: LogEntry, path: String) -> some View {
        let mark = symbol(for: entry, path: path)
        return Button { pick(entry.revision, path: path.isEmpty ? (model.selectedPaths.first ?? "") : path) } label: {
            Image(systemName: mark.0).foregroundStyle(mark.1)
        }
        .buttonStyle(.plain)
        .help("r\(entry.revision)  \(entry.author)")
        .contextMenu {
            if let change = entry.changes.first(where: { !$0.copyFromPath.isEmpty }) {
                Button(model.t("timeline.ancestor")) {
                    ancestorTitle = (change.copyFromPath as NSString).lastPathComponent
                    Task { ancestors = await model.ancestorLog(change) }
                }
            }
        }
    }

    private var track: some View {
        HStack(alignment: .top, spacing: 0) {
            Label(targetName, systemImage: model.selectedPaths.isEmpty ? "folder" : "doc.text")
                .font(.callout)
                .lineLimit(2)
                .frame(width: 168, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.top, 10)
            Divider()
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 4) {
                    nodes
                    HStack(spacing: 0) {
                        ForEach(entries) { entry in
                            Text(formattedRevision(entry.revision))
                                .font(.caption2)
                                .lineLimit(1)
                                .frame(width: slot)
                        }
                    }
                    band(.year)
                    band(.month)
                    band(.day)
                    HStack(spacing: 0) {
                        ForEach(entries) { entry in
                            Text(entry.date?.formatted(date: .omitted, time: .shortened) ?? "")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(width: slot)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
        }
        .frame(height: 168)
    }

    private var nodes: some View {
        ZStack {
            Capsule()
                .fill(Color.secondary.opacity(0.35))
                .frame(height: 2)
            HStack(spacing: 0) {
                ForEach(entries) { entry in
                    let selected = picks.contains(entry.revision)
                    Button { pick(entry.revision) } label: {
                        let mark = symbol(for: entry)
                        Image(systemName: mark.0)
                            .foregroundStyle(selected ? Color.accentColor : mark.1)
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .frame(width: slot)
                    .help("r\(entry.revision)  \(entry.author)\n\(entry.message)")
                    .contextMenu {
                        if let change = entry.changes.first(where: { !$0.copyFromPath.isEmpty }) {
                            Button(model.t("timeline.ancestor")) {
                                ancestorTitle = (change.copyFromPath as NSString).lastPathComponent
                                Task { ancestors = await model.ancestorLog(change) }
                            }
                        }
                    }
                }
            }
        }
        .frame(height: 20)
    }

    private func band(_ component: Calendar.Component) -> some View {
        HStack(spacing: 0) {
            ForEach(spans(entries, component)) { span in
                Text(span.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: slot * CGFloat(span.count))
            }
        }
        .frame(height: 16)
    }

    private func symbol(for entry: LogEntry, path: String) -> (String, Color) {
        let change = entry.changes.first { path.isEmpty || $0.path.hasSuffix(path) || path.hasSuffix($0.path) }
        if let change, !change.copyFromPath.isEmpty { return ("arrow.triangle.branch", .purple) }
        switch change?.action {
        case "A": return ("plus.circle.fill", .green)
        case "D": return ("minus.circle.fill", .red)
        case "R": return ("arrow.triangle.2.circlepath", .orange)
        case "M": return ("circle.fill", .blue)
        default: return ("circle", .secondary)
        }
    }

    private func symbol(for entry: LogEntry) -> (String, Color) {
        symbol(for: entry, path: model.selectedPaths.first ?? "")
    }

    private func pick(_ revision: Int, path: String) {
        model.selectedPaths = [path]
        pick(revision)
    }

    private func pick(_ revision: Int) {
        let extend = NSEvent.modifierFlags.contains(.command)
        if picks.contains(revision) {
            picks.removeAll { $0 == revision }
            compared = []
            return
        }
        if !extend || picks.count >= 2 { picks = [revision] }
        else { picks.append(revision) }
        guard picks.count == 2 else { compared = []; return }
        guard let path = model.selectedPaths.first, !path.isEmpty, let full = model.absolutePath(path) else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: full, isDirectory: &isDirectory), !isDirectory.boolValue else { return }
        let ordered = picks.sorted()
        Task {
            await model.compare(path: path, left: "\(ordered[0])", right: "\(ordered[1])", switchMode: false)
            compared = ordered
        }
    }

    private func chipTitle(_ key: String) -> String {
        switch key {
        case "last10": return model.t("timeline.last10")
        case "today": return model.t("filter.today")
        case "week": return model.t("filter.thisWeek")
        case "month": return model.t("filter.thisMonth")
        default: return model.t("filter.all")
        }
    }

    private func formattedRevision(_ revision: Int) -> String {
        revision.formatted(.number.grouping(.automatic))
    }

    private func spans(_ entries: [LogEntry], _ component: Calendar.Component) -> [RevisionSpan] {
        let calendar = Calendar.current
        var result: [RevisionSpan] = []
        for entry in entries {
            let title: String
            let group: String
            if let date = entry.date {
                let year = calendar.component(.year, from: date)
                let month = calendar.component(.month, from: date)
                let day = calendar.component(.day, from: date)
                switch component {
                case .year:
                    title = String(year)
                    group = title
                case .month:
                    title = date.formatted(.dateTime.month(.abbreviated))
                    group = "\(year)-\(month)"
                case .day:
                    title = String(day)
                    group = "\(year)-\(month)-\(day)"
                default:
                    title = ""
                    group = ""
                }
            } else {
                title = ""
                group = ""
            }
            if let index = result.indices.last, result[index].group == group {
                result[index].count += 1
            } else {
                result.append(RevisionSpan(id: "\(component)-\(entry.revision)", title: title, count: 1, group: group))
            }
        }
        return result
    }
}

private struct RevisionSpan: Identifiable {
    var id: String
    var title: String
    var count: Int
    var group: String
}

struct TranscriptView: View {
    @Bindable var model: AppModel

    var body: some View {
        List(model.transcript) { entry in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(model.formattedDate(entry.created)).font(.caption).foregroundStyle(.secondary)
                    Text(entry.title).fontWeight(entry.ok ? .regular : .semibold)
                    if !entry.ok { Image(systemName: "exclamationmark.circle").foregroundStyle(.red) }
                }
                Text(coloredTranscript(entry.body))
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(8)
                if !entry.note.isEmpty { Text(entry.note).foregroundStyle(.secondary) }
            }
            .contextMenu {
                Button(model.t("transcript.note")) { model.sheet = .note(entry.id) }
                Button(model.t("action.showDifferences")) { showTranscriptDiff(entry) }
                Button(model.t("action.showInWorkingCopy")) { showInWorkingCopy(entry) }
            }
        }
    }

    private func showTranscriptDiff(_ entry: TranscriptRecord) {
        let lines = entry.body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let range = lines.first(where: { $0.hasPrefix("#range:") })?.dropFirst("#range:".count).split(separator: "|", maxSplits: 1).map(String.init), range.count == 2, !range[0].isEmpty, !range[1].isEmpty {
            let path = lines.first { $0.hasPrefix("#path:") }.map { String($0.dropFirst("#path:".count)) } ?? model.selectedPaths.first
            Task { await model.compare(path: path, left: range[0], right: range[1], switchMode: true) }
            return
        }
        let numbers = entry.body.split { !$0.isNumber }.compactMap { Int($0) }
        guard numbers.count >= 2 else { return }
        Task { await model.compare(path: model.selectedPaths.first, left: "\(numbers[0])", right: "\(numbers[1])", switchMode: true) }
    }

    private func showInWorkingCopy(_ entry: TranscriptRecord) {
        if let path = entry.body.split(separator: "\n").first(where: { $0.hasPrefix("#path:") }).map({ String($0.dropFirst("#path:".count)) }), !path.isEmpty {
            model.selectedPaths = [path]
        }
        model.mode = .browser
    }

    private func coloredTranscript(_ body: String) -> AttributedString {
        var text = AttributedString(body)
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
        var cursor = body.startIndex
        for lineSub in lines {
            let line = String(lineSub)
            let end = body.index(cursor, offsetBy: line.count, limitedBy: body.endIndex) ?? body.endIndex
            let color: Color? = line.contains("conflict") || line.hasPrefix("C ") ? .red : (line.hasPrefix("A ") || line.contains(" added") ? .green : (line.hasPrefix("D ") ? .secondary : nil))
            if let color, let lower = AttributedString.Index(cursor, within: text), let upper = AttributedString.Index(end, within: text) {
                text[lower..<upper].foregroundColor = color
            }
            cursor = end < body.endIndex ? body.index(after: end) : body.endIndex
        }
        return text
    }
}

private struct UserPropertyText: View {
    var title: String
    var value: String
    var onCommit: (String) -> Void
    @State private var draft = ""

    var body: some View {
        TextField(title, text: $draft)
            .onAppear { draft = value }
            .onChange(of: value) { _, newValue in draft = newValue }
            .onSubmit { onCommit(draft) }
    }
}

struct InspectorView: View {
    @Bindable var model: AppModel
    @State private var ignoreText = ""
    @State private var externals = ""
    @State private var propName = ""
    @State private var propValue = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                section("inspector.general") {
                    line("column.name", model.selectedPaths.first ?? model.selectedWorkingCopy?.name ?? model.selectedRepository?.nickname ?? "")
                    line("column.revision", model.info.revision)
                    line("field.url", model.info.url)
                    line("column.author", model.info.author)
                    line("column.date", model.formattedDate(model.info.date))
                    line("column.depth", model.info.depth)
                }
                section("inspector.repository") {
                    line("field.url", model.selectedRepository?.url ?? "")
                    line("inspector.repository", model.info.repositoryRoot)
                }
                if model.selectedWorkingCopy != nil {
                    section("inspector.workingCopy") {
                        Toggle(model.t("field.includeExternals"), isOn: $model.showExternals)
                    }
                    section("inspector.properties") {
                        ForEach(model.properties, id: \.name) { property in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(property.name).font(.caption).foregroundStyle(.secondary)
                                    Text(property.value).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                                }
                                Spacer()
                                Button(model.t("action.delete")) { Task { await model.deleteProperty(property.name) } }
                                    .buttonStyle(.borderless)
                                Button(model.t("action.revert")) { Task { await model.revertPropertyToBase(property.name) } }
                                    .buttonStyle(.borderless)
                            }
                        }
                        if model.preferences.enableUserProperties {
                            ForEach(model.library.userProperties().filter(\.enabled)) { item in
                                let value = model.properties.first { $0.name == item.name }?.value ?? ""
                                switch item.type {
                                case "checkbox":
                                    Toggle(item.label.isEmpty ? item.name : item.label, isOn: Binding(get: { value == "1" || value == "yes" }, set: { on in
                                        Task { await model.setProperty(item.name, on ? "1" : "0") }
                                    }))
                                case "popup":
                                    Picker(item.label.isEmpty ? item.name : item.label, selection: Binding(get: { value }, set: { newValue in
                                        Task { await model.setProperty(item.name, newValue) }
                                    })) {
                                        ForEach(item.options.split(separator: ",").map(String.init), id: \.self) { option in
                                            Text(option).tag(option)
                                        }
                                    }
                                default:
                                    UserPropertyText(title: item.label.isEmpty ? item.name : item.label, value: value) { newValue in
                                        Task { await model.setProperty(item.name, newValue) }
                                    }
                                }
                            }
                        }
                        TextField(model.t("field.name"), text: $propName)
                        TextField(model.t("field.value"), text: $propValue)
                        Button(model.t("inspector.save")) { Task { await model.setProperty(propName, propValue) } }
                        TextField(model.t("inspector.externals"), text: $externals, axis: .vertical)
                        Button(model.t("inspector.save")) { Task { await model.saveExternals(externals) } }
                    }
                    section("column.lock") {
                        Text(model.properties.first { $0.name == "svn:lock" }?.value ?? model.rows.first { $0.path == model.selectedPaths.first }?.lock ?? "")
                        Button(model.t("action.lock")) { Task { await model.lockSelected(comment: "", steal: false) } }
                        Button(model.t("action.unlock")) { Task { await model.unlockSelected(force: false) } }
                    }
                    Button(model.t("pref.doubleClick.open")) { model.openEditor() }
                    Button(model.t("inspector.openWith")) { model.rememberDefaultApp() }
                }
            }
            .padding(12)
        }
        .onChange(of: model.properties.count) {
            externals = model.properties.first { $0.name == "svn:externals" }?.value ?? ""
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.t(title)).font(.caption).foregroundStyle(.secondary).textCase(.uppercase)
            content()
        }
    }

    private func line(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(model.t(key)).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
            Text(value).textSelection(.enabled)
        }
        .font(.callout)
    }
}

struct CommitPane: View {
    @Bindable var model: AppModel
    @State private var message = ""
    @State private var unlock = true
    @State private var postScript = ""
    @State private var expanded: String?

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.t("commit.title")).font(.title3)
                TextEditor(text: $message)
                    .font(.system(size: model.preferences.commitLogFontSize, design: .monospaced))
                    .frame(minHeight: 180)
                if !model.logs.isEmpty {
                    Menu(model.t("log.copy")) {
                        ForEach(model.logs.prefix(6)) { entry in
                            Button(entry.message.isEmpty ? "r\(entry.revision)" : entry.message) { message = entry.message }
                        }
                    }
                }
                TextField(model.t("commit.postScript"), text: $postScript)
                Toggle(model.t("commit.unlock"), isOn: $unlock)
                HStack {
                    Button(model.t("action.cancel")) { cancel() }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(model.t("commit.button")) {
                        Task { await model.commit(message: message, unlock: unlock, preScript: model.preferences.preCommitScript, postScript: postScript) }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
            .frame(minWidth: 280, maxWidth: 420)
            Divider()
            List {
                ForEach(model.commitItems) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Toggle(isOn: Binding(get: { item.included }, set: { _ in
                                model.toggleCommit(item.path, option: NSEvent.modifierFlags.contains(.option))
                            })) {
                                Text("\(item.letter)  \(item.path)").font(.system(.body, design: .monospaced))
                            }
                            if !(model.rows.first { $0.path == item.path }?.isDirectory ?? true) {
                                Button(expanded == item.path ? "▾" : "▸") {
                                    expanded = expanded == item.path ? nil : item.path
                                    if expanded == item.path {
                                        Task { await model.compare(path: item.path, left: "BASE", right: "WORKING", switchMode: false) }
                                    }
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        if expanded == item.path, model.compare?.path == item.path {
                            Text(model.compare?.rows.filter { $0.kind != .same }.prefix(8).map { $0.kind == .delete ? "- \($0.left)" : "+ \($0.right)" }.joined(separator: "\n") ?? "")
                                .font(.system(size: 11, design: .monospaced))
                                .lineLimit(8)
                        }
                    }
                }
            }
        }
        .onAppear { message = model.logDraft }
        .onChange(of: message) { _, value in model.logDraft = value }
        .onExitCommand { cancel() }
    }

    private func cancel() {
        model.logDraft = message
        model.mode = .browser
    }
}
