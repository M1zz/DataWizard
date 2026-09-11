import Foundation

/// Minimal XLSX reader. An .xlsx is a ZIP archive of XML parts.
/// We extract it with the system `unzip`, then parse the shared-strings
/// table and the first worksheet's rows.
///
/// Supports the structure produced by Numbers / Excel / Google Sheets exports,
/// which is all this pipeline needs. Reads the FIRST sheet only.
enum XLSXReader {

    enum XLSXError: Error, LocalizedError {
        case noWorksheet
        var errorDescription: String? {
            switch self {
            case .noWorksheet: return "No worksheet found inside the .xlsx file."
            }
        }
    }

    /// Read a worksheet into a 2D grid of strings. Empty cells become "".
    static func readGrid(at url: URL) throws -> [[String]] {
        // Step 1: read all archive entries in-process (sandbox-safe, no external tools)
        let parts = try MiniZip.entries(of: url)

        // Step 2: load the shared-strings table (cell text is often stored here by index)
        let sharedStrings = parseSharedStrings(parts: parts)

        // Step 3: find the first worksheet xml
        guard let sheetData = parts["xl/worksheets/sheet1.xml"] else {
            throw XLSXError.noWorksheet
        }
        return parseSheet(data: sheetData, sharedStrings: sharedStrings)
    }

    /// 숨김 여부까지 함께 읽는다 — 엑셀·넘버스에서 필터로 감춰 둔 줄을 그대로 존중하기 위해.
    static func readGridWithHidden(at url: URL) throws -> (grid: [[String]], hidden: [Bool]) {
        let parts = try MiniZip.entries(of: url)
        let sharedStrings = parseSharedStrings(parts: parts)
        guard let sheetData = parts["xl/worksheets/sheet1.xml"] else { throw XLSXError.noWorksheet }
        return parseSheetWithHidden(data: sheetData, sharedStrings: sharedStrings)
    }

    /// 머리글 줄을 스스로 찾아 읽되, **시트에서 숨겨진 줄은 빼고** 읽는다.
    /// (빼기 전에 몇 줄을 뺐는지 `hiddenSkipped`로 알려 준다 — 사용자가 되돌릴 수 있게.)
    static func readVisibleTable(at url: URL, includeHidden: Bool = false)
        throws -> (headers: [String], rows: [[String: String]], headerRow: Int, hiddenSkipped: Int) {
        let (grid, hidden) = try readGridWithHidden(at: url)
        guard !grid.isEmpty else { return ([], [], 0, 0) }

        func filled(_ row: [String]) -> Int {
            row.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        }
        var headerRow = 0
        var bestScore = filled(grid[0])
        for i in 1..<min(grid.count, 5) where filled(grid[i]) > bestScore {
            headerRow = i
            bestScore = filled(grid[i])
        }

        let header = grid[headerRow]
        var rows: [[String: String]] = []
        var skipped = 0
        for i in (headerRow + 1)..<grid.count {
            let r = grid[i]
            if r.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) { continue }
            if !includeHidden, i < hidden.count, hidden[i] {
                skipped += 1
                continue
            }
            var dict: [String: String] = [:]
            for (idx, key) in header.enumerated() { dict[key] = idx < r.count ? r[idx] : "" }
            rows.append(dict)
        }
        return (header, rows, headerRow, skipped)
    }

    /// Read a worksheet into its ordered header plus header-keyed rows,
    /// given which row holds the header.
    static func readTable(at url: URL, headerRowIndex: Int) throws -> (headers: [String], rows: [[String: String]]) {
        let grid = try readGrid(at: url)
        guard headerRowIndex < grid.count else { return ([], []) }
        let header = grid[headerRowIndex]
        var out: [[String: String]] = []
        let dataRows = grid.dropFirst(headerRowIndex + 1)
        for r in dataRows {
            if r.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) { continue }
            var dict: [String: String] = [:]
            for (idx, key) in header.enumerated() {
                dict[key] = idx < r.count ? r[idx] : ""
            }
            out.append(dict)
        }
        return (header, out)
    }

    /// 머리글이 몇 번째 줄인지 스스로 찾아 읽는다.
    /// 내보내기 도구들이 첫 줄에 파일 제목만 한 칸 써 두는 경우가 흔해서,
    /// ‘이름이 채워진 칸이 가장 많은 줄’을 머리글로 본다 (앞 5줄만 살핀다).
    static func readTableAutoHeader(at url: URL) throws -> (headers: [String], rows: [[String: String]], headerRow: Int) {
        let grid = try readGrid(at: url)
        guard !grid.isEmpty else { return ([], [], 0) }
        func filled(_ row: [String]) -> Int {
            row.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        }
        var best = 0
        var bestScore = filled(grid[0])
        for i in 1..<min(grid.count, 5) where filled(grid[i]) > bestScore {
            best = i
            bestScore = filled(grid[i])
        }
        let table = try readTable(at: url, headerRowIndex: best)
        return (table.headers, table.rows, best)
    }

    /// Read a worksheet as header-keyed dictionaries, given which row holds the header.
    static func readDicts(at url: URL, headerRowIndex: Int) throws -> [[String: String]] {
        try readTable(at: url, headerRowIndex: headerRowIndex).rows
    }

    // MARK: - sharedStrings.xml

    private static func parseSharedStrings(parts: [String: Data]) -> [String] {
        guard let data = parts["xl/sharedStrings.xml"] else { return [] }
        let parser = SharedStringsParser()
        let xml = XMLParser(data: data)
        xml.delegate = parser
        xml.parse()
        return parser.strings
    }

    // MARK: - worksheet xml

    private static func parseSheetWithHidden(data: Data,
                                            sharedStrings: [String]) -> (grid: [[String]], hidden: [Bool]) {
        let delegate = SheetParser(sharedStrings: sharedStrings)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return (delegate.grid, delegate.hidden)
    }

    private static func parseSheet(data: Data, sharedStrings: [String]) -> [[String]] {
        let parser = SheetParser(sharedStrings: sharedStrings)
        let xml = XMLParser(data: data)
        xml.delegate = parser
        xml.parse()
        return parser.grid
    }
}

// MARK: - sharedStrings delegate

private final class SharedStringsParser: NSObject, XMLParserDelegate {
    var strings: [String] = []
    private var current = ""
    private var insideText = false

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String]) {
        if elementName == "si" { current = "" }
        if elementName == "t" { insideText = true }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if insideText { current += string }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "t" { insideText = false }
        if elementName == "si" { strings.append(current) }
    }
}

// MARK: - worksheet delegate

private final class SheetParser: NSObject, XMLParserDelegate {
    let sharedStrings: [String]
    var grid: [[String]] = []
    /// 각 줄이 시트에서 숨겨져 있는지 (엑셀·넘버스에서 필터로 감춘 줄).
    var hidden: [Bool] = []

    private var rowHidden = false
    private var currentRow: [String: String] = [:]   // column letter -> value
    private var maxColIndex = 0
    private var cellType = ""        // "s" = shared string, "" = number, "str"/"inlineStr"
    private var cellRef = ""         // e.g. "B3"
    private var cellText = ""
    private var insideValue = false
    private var insideInlineText = false

    init(sharedStrings: [String]) { self.sharedStrings = sharedStrings }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String]) {
        switch elementName {
        case "row":
            currentRow = [:]
            rowHidden = (attributeDict["hidden"] == "1" || attributeDict["hidden"] == "true")
        case "c":
            cellType = attributeDict["t"] ?? ""
            cellRef = attributeDict["r"] ?? ""
            cellText = ""
        case "v":
            insideValue = true
        case "t":
            insideInlineText = true
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if insideValue || insideInlineText { cellText += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName {
        case "v":
            insideValue = false
        case "t":
            insideInlineText = false
        case "c":
            // Resolve the cell value depending on its type
            var value = cellText
            if cellType == "s", let idx = Int(cellText), idx < sharedStrings.count {
                value = sharedStrings[idx]
            }
            let col = SheetParser.columnLetters(fromRef: cellRef)
            currentRow[col] = value
            let colIdx = SheetParser.columnIndex(fromLetters: col)
            maxColIndex = max(maxColIndex, colIdx)
        case "row":
            // Flatten the column-letter dictionary into a dense array
            var arr = Array(repeating: "", count: maxColIndex + 1)
            for (letters, val) in currentRow {
                let idx = SheetParser.columnIndex(fromLetters: letters)
                if idx < arr.count { arr[idx] = val }
            }
            grid.append(arr)
            hidden.append(rowHidden)
        default:
            break
        }
    }

    // "B3" -> "B"
    static func columnLetters(fromRef ref: String) -> String {
        String(ref.prefix { $0.isLetter })
    }

    // "A" -> 0, "B" -> 1, "Z" -> 25, "AA" -> 26
    static func columnIndex(fromLetters letters: String) -> Int {
        var idx = 0
        for ch in letters.uppercased().unicodeScalars where ch.properties.isAlphabetic {
            idx = idx * 26 + (Int(ch.value) - 64)
        }
        return idx - 1
    }
}
