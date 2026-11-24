import AppKit
import SwiftUI

struct CompareView: View {
    @Bindable var model: AppModel
    @State private var mode = "side"

    var body: some View {
        VStack(spacing: 0) {
            if let document = model.compare {
                HStack {
                    Text(document.leftTitle).font(.caption)
                    Spacer()
                    if document.leftImage != nil || document.rightImage != nil {
                        Picker("", selection: $mode) {
                            Text(model.t("compare.sideBySide")).tag("side")
                            Text(model.t("compare.wipe")).tag("wipe")
                            Text(model.t("compare.pixels")).tag("pixels")
                        }.pickerStyle(.segmented).frame(width: 280)
                    }
                    Spacer()
                    Text(document.rightTitle).font(.caption)
                }
                .padding(6)
                if let left = document.leftImage, let right = document.rightImage, let a = NSImage(data: left), let b = NSImage(data: right) {
                    ImageCompare(left: a, right: b, mode: mode)
                } else if document.leftText.utf8.contains(0) || document.rightText.utf8.contains(0) {
                    ContentUnavailableView(model.t("compare.binary"), systemImage: "doc")
                } else {
                    SideBySideDiff(rows: document.rows, path: document.path)
                }
            } else {
                ContentUnavailableView(model.t("empty.selectFile"), systemImage: "doc.text.magnifyingglass")
            }
        }
    }
}

struct SideBySideDiff: View {
    var rows: [DiffRow]
    var path: String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        HStack(alignment: .top, spacing: 0) {
                            line(row.left, number: row.leftNumber, kind: leftKind(row))
                            Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1)
                            line(row.right, number: row.rightNumber, kind: rightKind(row))
                            if row.kind != .same {
                                Rectangle()
                                    .fill(Color.green.opacity(0.85))
                                    .frame(width: 3)
                            } else {
                                Color.clear.frame(width: 3)
                            }
                        }
                        .id(row.id)
                    }
                }
            }
            .onAppear {
                if let first = rows.first(where: { $0.kind != .same })?.id {
                    proxy.scrollTo(first, anchor: .center)
                }
            }
        }
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

    private func line(_ text: String, number: Int?, kind: DiffRow.Kind) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(number.map(String.init) ?? "")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 36, alignment: .trailing)
            Text(highlighted(text))
                .font(.system(size: 12, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(.vertical, 1)
        .padding(.trailing, 8)
        .frame(minWidth: 420, alignment: .leading)
        .background(background(kind))
    }

    private func background(_ kind: DiffRow.Kind) -> Color {
        switch kind {
        case .insert: return Color.green.opacity(0.22)
        case .delete: return Color.red.opacity(0.16)
        case .change: return Color.green.opacity(0.18)
        case .same: return .clear
        }
    }

    private func highlighted(_ line: String) -> AttributedString {
        var text = AttributedString(line.isEmpty ? " " : line)
        text.foregroundColor = .primary
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
    @State private var split = 0.5

    var body: some View {
        GeometryReader { proxy in
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
                Text(meta(entry))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(entry.message.isEmpty ? " " : entry.message)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
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
    @State private var picks: [Int] = []
    @State private var compared: [Int] = []

    private let slot: CGFloat = 76

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            if model.logs.isEmpty {
                ContentUnavailableView(model.t("empty.selectFile"), systemImage: "timeline.selection")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                track
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
        return source.sorted { $0.revision < $1.revision }
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
            TextField(model.t("filter.search"), text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
                        Circle()
                            .fill(selected ? Color.accentColor : Color(nsColor: .windowBackgroundColor))
                            .overlay(Circle().stroke(selected ? Color.accentColor : Color.secondary, lineWidth: 1.5))
                            .frame(width: 11, height: 11)
                    }
                    .buttonStyle(.plain)
                    .frame(width: slot)
                    .help("r\(entry.revision)  \(entry.author)\n\(entry.message)")
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

    private func pick(_ revision: Int) {
        if let index = picks.firstIndex(of: revision) {
            picks.remove(at: index)
            compared = []
            return
        }
        if picks.count == 2 { picks.removeFirst() }
        picks.append(revision)
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
                Text(entry.body).font(.system(size: 12, design: .monospaced)).lineLimit(6)
                if !entry.note.isEmpty { Text(entry.note).foregroundStyle(.secondary) }
            }
            .contextMenu {
                Button(model.t("transcript.note")) { model.sheet = .note(entry.id) }
            }
        }
    }
}

struct InspectorView: View {
    @Bindable var model: AppModel
    @State private var ignoreText = ""
    @State private var externals = ""

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
                            VStack(alignment: .leading) {
                                Text(property.name).font(.caption).foregroundStyle(.secondary)
                                Text(property.value).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                            }
                        }
                        TextField(model.t("inspector.externals"), text: $externals, axis: .vertical)
                        Button(model.t("inspector.save")) { Task { await model.saveExternals(externals) } }
                    }
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
