import Foundation

nonisolated struct DiffRow: Identifiable, Sendable {
    enum Kind: String, Sendable { case same, insert, delete, change }
    var id: Int
    var kind: Kind
    var left: String
    var right: String
    var leftNumber: Int?
    var rightNumber: Int?
}

nonisolated enum TextDiff {
    static func rows(left: String, right: String) -> [DiffRow] {
        let a = left.components(separatedBy: "\n")
        let b = right.components(separatedBy: "\n")
        let ops = myers(a, b)
        var rows: [DiffRow] = []
        var leftNo = 1
        var rightNo = 1
        var index = 0
        var i = 0
        while i < ops.count {
            let op = ops[i]
            if op == .equal {
                rows.append(DiffRow(id: index, kind: .same, left: a[leftNo - 1], right: b[rightNo - 1], leftNumber: leftNo, rightNumber: rightNo))
                leftNo += 1
                rightNo += 1
                i += 1
                index += 1
                continue
            }
            var deletes: [String] = []
            var inserts: [String] = []
            while i < ops.count, ops[i] == .delete {
                deletes.append(a[leftNo - 1])
                leftNo += 1
                i += 1
            }
            while i < ops.count, ops[i] == .insert {
                inserts.append(b[rightNo - 1])
                rightNo += 1
                i += 1
            }
            let paired = min(deletes.count, inserts.count)
            for n in 0..<paired {
                rows.append(DiffRow(id: index, kind: .change, left: deletes[n], right: inserts[n], leftNumber: leftNo - deletes.count + n, rightNumber: rightNo - inserts.count + n))
                index += 1
            }
            for n in paired..<deletes.count {
                rows.append(DiffRow(id: index, kind: .delete, left: deletes[n], right: "", leftNumber: leftNo - deletes.count + n, rightNumber: nil))
                index += 1
            }
            for n in paired..<inserts.count {
                rows.append(DiffRow(id: index, kind: .insert, left: "", right: inserts[n], leftNumber: nil, rightNumber: rightNo - inserts.count + n))
                index += 1
            }
        }
        return rows
    }

    static func hunks(_ rows: [DiffRow]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start: Int?
        for (index, row) in rows.enumerated() {
            if row.kind == .same {
                if let start {
                    ranges.append(start..<index)
                }
                start = nil
            } else if start == nil {
                start = index
            }
        }
        if let start { ranges.append(start..<rows.count) }
        return ranges
    }

    private enum Op { case equal, insert, delete }

    /// Myers diff, bounded so a huge file still returns a usable result.
    private static func myers(_ a: [String], _ b: [String]) -> [Op] {
        if a.count > 8000 || b.count > 8000 {
            return a.map { _ in .delete } + b.map { _ in .insert }
        }
        let n = a.count
        let m = b.count
        let max = n + m
        var v = [Int: Int]()
        v[1] = 0
        var trace: [[Int: Int]] = []
        var found = false
        if max == 0 { return [] }
        for d in 0...max {
            var next = [Int: Int]()
            for k in stride(from: -d, through: d, by: 2) {
                let x: Int
                if k == -d || (k != d && (v[k - 1] ?? 0) < (v[k + 1] ?? 0)) {
                    x = v[k + 1] ?? 0
                } else {
                    x = (v[k - 1] ?? 0) + 1
                }
                var xx = x
                var yy = xx - k
                while xx < n, yy < m, a[xx] == b[yy] {
                    xx += 1
                    yy += 1
                }
                next[k] = xx
                if xx >= n, yy >= m {
                    found = true
                    break
                }
            }
            v = next
            trace.append(v)
            if found { break }
        }
        var x = n
        var y = m
        var ops: [Op] = []
        for d in stride(from: trace.count - 1, through: 0, by: -1) {
            let v = trace[d]
            let k = x - y
            let prevK: Int
            if k == -d || (k != d && (v[k - 1] ?? 0) < (v[k + 1] ?? 0)) {
                prevK = k + 1
            } else {
                prevK = k - 1
            }
            let prevX = d == 0 ? 0 : (trace[d - 1][prevK] ?? 0)
            let prevY = prevX - prevK
            while x > prevX, y > prevY {
                ops.append(.equal)
                x -= 1
                y -= 1
            }
            if d == 0 { break }
            if x == prevX {
                ops.append(.insert)
                y -= 1
            } else {
                ops.append(.delete)
                x -= 1
            }
        }
        return ops.reversed()
    }
}

nonisolated enum SyntaxColor {
    static let languages: [String: [String]] = [
        "swift": ["import", "struct", "class", "enum", "func", "var", "let", "return", "if", "else", "guard", "switch", "case", "for", "while", "private", "public", "internal", "static"],
        "c": ["int", "void", "return", "if", "else", "for", "while", "struct", "typedef", "const", "static"],
        "cpp": ["int", "void", "return", "if", "else", "class", "public", "private", "namespace", "template"],
        "m": ["interface", "implementation", "end", "return", "if", "else", "self", "nil"],
        "cs": ["class", "public", "private", "return", "if", "else", "var", "string", "void"],
        "java": ["class", "public", "private", "return", "if", "else", "import", "package", "void"],
        "js": ["function", "return", "const", "let", "var", "if", "else", "import", "export", "class"],
        "py": ["def", "return", "if", "else", "elif", "import", "class", "for", "while", "None", "True", "False"],
        "rb": ["def", "end", "class", "module", "if", "else", "return", "do"],
        "pl": ["sub", "my", "return", "if", "else", "use"],
        "php": ["function", "return", "if", "else", "class", "public", "echo"],
        "go": ["func", "return", "if", "else", "package", "import", "var", "type", "struct"],
        "rs": ["fn", "let", "mut", "return", "if", "else", "struct", "enum", "impl", "pub"],
        "sh": ["if", "then", "fi", "for", "while", "do", "done", "echo", "return"],
        "sql": ["select", "from", "where", "insert", "update", "delete", "create", "table", "and", "or"],
    ]

    static func keywords(for path: String) -> [String] {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        switch ext {
        case "h", "c", "cc", "cpp", "hpp", "mm": return languages["cpp"] ?? []
        case "m": return languages["m"] ?? []
        case "swift": return languages["swift"] ?? []
        case "java": return languages["java"] ?? []
        case "js", "ts", "json": return languages["js"] ?? []
        case "py": return languages["py"] ?? []
        case "rb": return languages["rb"] ?? []
        case "pl": return languages["pl"] ?? []
        case "php": return languages["php"] ?? []
        case "go": return languages["go"] ?? []
        case "rs": return languages["rs"] ?? []
        case "sh", "bash": return languages["sh"] ?? []
        case "sql", "pks", "pkb": return languages["sql"] ?? []
        case "cs": return languages["cs"] ?? []
        default: return []
        }
    }
}
