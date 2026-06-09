import Foundation

/// Pure value-cleaning helpers. Each is broken into single-purpose steps
/// so the algorithm maps closely to the code, line by line.
enum Normalizer {

    /// Clean a Korean phone number into the canonical "010-XXXX-XXXX" shape.
    /// Step 1: keep only digit characters.
    /// Step 2: if it starts with country code 82, replace with a leading 0.
    /// Step 3: if it's 10 digits and starts with 10, prepend a 0.
    /// Step 4: format 11-digit mobile numbers as 3-4-4; otherwise return digits as-is.
    static func cleanPhone(_ raw: String) -> String {
        // Step 1: keep only digits
        var digits = raw.filter { $0.isNumber }
        if digits.isEmpty { return "" }

        // Step 2: normalize +82 country code to a domestic leading zero
        if digits.hasPrefix("82") {
            digits = "0" + digits.dropFirst(2)
        }

        // Step 3: a 10-digit number starting with "10" is missing its leading zero
        if digits.count == 10 && digits.hasPrefix("10") {
            digits = "0" + digits
        }

        // Step 4: format standard 11-digit mobile numbers
        if digits.count == 11 {
            let a = digits.prefix(3)
            let b = digits.dropFirst(3).prefix(4)
            let c = digits.dropFirst(7)
            return "\(a)-\(b)-\(c)"
        }

        // Step 4b: format 10-digit Seoul-style numbers as 2-4-4 (e.g. 02 numbers)
        if digits.count == 10 {
            let a = digits.prefix(2)
            let b = digits.dropFirst(2).prefix(4)
            let c = digits.dropFirst(6)
            return "\(a)-\(b)-\(c)"
        }

        // Fallback: return the raw digit string
        return digits
    }

    /// The dedup key derived from a phone number: digits only, no formatting.
    /// Two rows with the same key are the same person.
    static func phoneKey(_ raw: String) -> String {
        var digits = raw.filter { $0.isNumber }
        if digits.hasPrefix("82") { digits = "0" + digits.dropFirst(2) }
        if digits.count == 10 && digits.hasPrefix("10") { digits = "0" + digits }
        return digits
    }

    /// Normalize a free-form birthdate into "yyyy-MM-dd".
    /// Tries several common input layouts and returns the first that parses.
    static func cleanDate(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }

        let candidateFormats = [
            "yyyy-MM-dd", "yyyy/MM/dd", "yyyy.MM.dd",
            "dd-MM-yyyy", "dd/MM/yyyy", "MM/dd/yyyy",
            "yyyyMMdd"
        ]
        let out = DateFormatter()
        out.locale = Locale(identifier: "en_US_POSIX")
        out.dateFormat = "yyyy-MM-dd"

        for fmt in candidateFormats {
            let parser = DateFormatter()
            parser.locale = Locale(identifier: "en_US_POSIX")
            parser.dateFormat = fmt
            if let d = parser.date(from: trimmed) {
                return out.string(from: d)
            }
        }
        // Could not parse: return the original so nothing is silently lost.
        return trimmed
    }
}
