import Foundation

/// 압축 없이(stored) ZIP 한 덩어리를 만든다.
/// xlsx는 결국 ZIP이라, 읽기만 하던 `MiniZip`의 짝으로 쓰기 쪽만 최소한으로 붙였다.
enum ZipWriter {

    static func archive(_ files: [(name: String, data: Data)]) -> Data {
        var out = Data()
        var central = Data()
        var offset = 0

        for file in files {
            let name = Array(file.name.utf8)
            let body = file.data
            let crc = crc32(body)
            let size = UInt32(body.count)

            var local = Data()
            local.append(u32(0x0403_4b50))      // local file header
            local.append(u16(20))               // version needed
            local.append(u16(0))                // flags
            local.append(u16(0))                // method: stored
            local.append(u16(0)); local.append(u16(0))   // time, date
            local.append(u32(crc))
            local.append(u32(size)); local.append(u32(size))
            local.append(u16(UInt16(name.count))); local.append(u16(0))
            local.append(contentsOf: name)
            local.append(body)

            central.append(u32(0x0201_4b50))    // central directory header
            central.append(u16(20)); central.append(u16(20))
            central.append(u16(0)); central.append(u16(0))
            central.append(u16(0)); central.append(u16(0))
            central.append(u32(crc))
            central.append(u32(size)); central.append(u32(size))
            central.append(u16(UInt16(name.count)))
            central.append(u16(0)); central.append(u16(0))
            central.append(u16(0)); central.append(u16(0))
            central.append(u32(0))
            central.append(u32(UInt32(offset)))
            central.append(contentsOf: name)

            offset += local.count
            out.append(local)
        }

        let centralOffset = out.count
        out.append(central)
        out.append(u32(0x0605_4b50))            // end of central directory
        out.append(u16(0)); out.append(u16(0))
        out.append(u16(UInt16(files.count))); out.append(u16(UInt16(files.count)))
        out.append(u32(UInt32(central.count)))
        out.append(u32(UInt32(centralOffset)))
        out.append(u16(0))
        return out
    }

    private static func u16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    private static func u32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) == 1 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in data { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}

/// 표 하나짜리 엑셀 파일(.xlsx)을 만든다.
/// 값은 전부 **글자(inline string)로** 넣는다 — `010-1234-5678`이나 `0012` 같은 값이
/// 숫자로 바뀌어 앞자리 0이 사라지는 사고를 막기 위해서다.
enum XLSXWriter {

    static func book(headers: [String], rows: [[String]], sheetName: String = "완성본") -> Data {
        var sheet = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>
        """
        sheet += row(headers, at: 1)
        for (i, r) in rows.enumerated() { sheet += row(r, at: i + 2) }
        sheet += "</sheetData></worksheet>"

        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\
        <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>\
        </Types>
        """
        let rels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>\
        </Relationships>
        """
        let workbook = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
        <sheets><sheet name="\(escape(sheetName))" sheetId="1" r:id="rId1"/></sheets></workbook>
        """
        let workbookRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>\
        </Relationships>
        """
        return ZipWriter.archive([
            ("[Content_Types].xml", Data(contentTypes.utf8)),
            ("_rels/.rels", Data(rels.utf8)),
            ("xl/workbook.xml", Data(workbook.utf8)),
            ("xl/_rels/workbook.xml.rels", Data(workbookRels.utf8)),
            ("xl/worksheets/sheet1.xml", Data(sheet.utf8)),
        ])
    }

    private static func row(_ values: [String], at index: Int) -> String {
        var out = "<row r=\"\(index)\">"
        for (i, v) in values.enumerated() {
            out += "<c r=\"\(name(i))\(index)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">"
                + escape(v) + "</t></is></c>"
        }
        return out + "</row>"
    }

    /// 0 → A, 25 → Z, 26 → AA …
    private static func name(_ index: Int) -> String {
        var i = index, out = ""
        repeat {
            out = String(UnicodeScalar(UInt8(65 + i % 26))) + out
            i = i / 26 - 1
        } while i >= 0
        return out
    }

    private static func escape(_ s: String) -> String {
        var out = ""
        for ch in s.unicodeScalars {
            switch ch {
            case "&":  out += "&amp;"
            case "<":  out += "&lt;"
            case ">":  out += "&gt;"
            case "\"": out += "&quot;"
            // 엑셀이 못 읽는 제어 문자는 뺀다 (탭·줄바꿈은 남긴다).
            case let c where c.value < 0x20 && c != "\n" && c != "\t" && c != "\r": break
            default:   out.unicodeScalars.append(ch)
            }
        }
        return out
    }
}
