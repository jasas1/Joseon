import Foundation

/// The one way the app prints a number: a real minus sign "−" (U+2212), never the ASCII hyphen.
/// Header, strip, popovers, session list and Settings all go through here.
enum NumberText {
    static let minus = "\u{2212}"

    /// "−11.5", "2.5", and with `plus` "+2.5". A value that rounds to zero has no sign.
    static func signed(_ value: Double, decimals: Int = 1, plus: Bool = false) -> String {
        guard value.isFinite else { return "—" }
        let body = String(format: "%.\(max(decimals, 0))f", abs(value))
        let isZero = !body.contains { $0 != "0" && $0 != "." }
        if isZero { return body }
        if value < 0 { return minus + body }
        return (plus ? "+" : "") + body
    }

    static func signed(_ value: Float, decimals: Int = 1, plus: Bool = false) -> String {
        signed(Double(value), decimals: decimals, plus: plus)
    }

    static func signed(_ value: Int, plus: Bool = false) -> String {
        value < 0 ? minus + String(-value) : (plus && value > 0 ? "+" : "") + String(value)
    }

    /// Text from another module (stress flag titles and details, plot labels) can carry an ASCII hyphen as
    /// a minus sign: "-21.6 dBFS". A hyphen that starts a number becomes a real minus. A hyphen inside a
    /// word or between two numbers ("1/6-octave", "32-bit", "3-5") stays.
    static func typographic(_ text: String) -> String {
        guard text.contains("-") else { return text }
        var out = ""
        out.reserveCapacity(text.count)
        var previous: Character?
        var index = text.startIndex
        while index < text.endIndex {
            let c = text[index]
            let next = text.index(after: index)
            if c == "-", next < text.endIndex, text[next].isNumber || text[next] == ".",
               previous.map({ !$0.isLetter && !$0.isNumber }) ?? true {
                out += minus
            } else {
                out.append(c)
            }
            previous = c
            index = next
        }
        return out
    }
}
