import SwiftUI

/// 輕量 Markdown 顯示：支援標題（# / ## / ###）、項目符號、編號清單、表格、粗體/斜體（行內交給 SwiftUI）。
/// SwiftUI 內建的 Text(markdown:) 只處理行內樣式，不處理標題與表格，所以自己逐行排版。
struct MarkdownView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                render(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    // MARK: - Parsing

    private enum Block {
        case heading(level: Int, text: String)
        case bullet(text: String, indent: Int)
        case numbered(number: String, text: String)
        case table(rows: [[String]])
        case paragraph(text: String)
        case rule
        case blank
    }

    private var blocks: [Block] {
        var result: [Block] = []
        var tableRows: [[String]] = []

        func flushTable() {
            if !tableRows.isEmpty {
                result.append(.table(rows: tableRows))
                tableRows = []
            }
        }

        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("|") {
                let cells = line
                    .trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                    .components(separatedBy: "|")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                // 略過 |---|---| 分隔列
                let isSeparator = cells.allSatisfy { cell in
                    !cell.isEmpty && cell.allSatisfy { $0 == "-" || $0 == ":" }
                }
                if !isSeparator { tableRows.append(cells) }
                continue
            }
            flushTable()

            if line.isEmpty {
                result.append(.blank)
            } else if line == "---" || line == "***" {
                result.append(.rule)
            } else if line.hasPrefix("#") {
                let level = line.prefix { $0 == "#" }.count
                let text = line.dropFirst(level).trimmingCharacters(in: .whitespaces)
                result.append(.heading(level: min(level, 3), text: text))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                let indent = rawLine.prefix { $0 == " " || $0 == "\t" }.count
                result.append(.bullet(text: String(line.dropFirst(2)), indent: indent >= 2 ? 1 : 0))
            } else if let match = numberedPrefix(line) {
                result.append(.numbered(number: match.number, text: match.text))
            } else {
                result.append(.paragraph(text: line))
            }
        }
        flushTable()
        return result
    }

    private func numberedPrefix(_ line: String) -> (number: String, text: String)? {
        // 例如 "1. 文字" 或 "12) 文字"
        guard let dot = line.firstIndex(where: { $0 == "." || $0 == ")" }) else { return nil }
        let head = line[line.startIndex..<dot]
        guard !head.isEmpty, head.count <= 3, head.allSatisfy(\.isNumber) else { return nil }
        let rest = line[line.index(after: dot)...].trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return nil }
        return (String(head), rest)
    }

    // MARK: - Rendering

    @ViewBuilder
    private func render(_ block: Block) -> some View {
        switch block {
        case .heading(let level, let text):
            inline(text)
                .font(level == 1 ? .title2.bold() : (level == 2 ? .title3.bold() : .headline))
                .padding(.top, level == 1 ? 4 : 8)
        case .bullet(let text, let indent):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•")
                inline(text)
            }
            .padding(.leading, CGFloat(indent) * 16)
        case .numbered(let number, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(number).").monospacedDigit()
                inline(text)
            }
        case .table(let rows):
            tableView(rows)
        case .paragraph(let text):
            inline(text)
        case .rule:
            Divider()
        case .blank:
            Spacer().frame(height: 2)
        }
    }

    private func inline(_ text: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attributed)
        }
        return Text(text)
    }

    private func tableView(_ rows: [[String]]) -> some View {
        let columns = rows.map(\.count).max() ?? 0
        return ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                    GridRow {
                        ForEach(0..<columns, id: \.self) { col in
                            inline(col < row.count ? row[col] : "")
                                .font(rowIndex == 0 ? .subheadline.bold() : .subheadline)
                                .frame(minWidth: 60, alignment: .leading)
                        }
                    }
                    if rowIndex == 0 { Divider() }
                }
            }
            .padding(10)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
