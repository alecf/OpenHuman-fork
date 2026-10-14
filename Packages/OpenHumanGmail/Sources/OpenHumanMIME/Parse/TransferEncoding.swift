import Foundation

enum TransferEncoding {
    static func decode(_ bytes: ArraySlice<UInt8>, encoding: String?) -> Data {
        switch encoding?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "base64": return base64(bytes)
        case "quoted-printable": return quotedPrintable(bytes)
        default: return Data(bytes)
        }
    }

    static func base64(_ bytes: ArraySlice<UInt8>) -> Data {
        var out = [UInt8]()
        out.reserveCapacity(bytes.count / 4 * 3 + 3)
        var acc: UInt32 = 0
        var bits = 0
        for b in bytes {
            let v: UInt32
            switch b {
            case 65...90: v = UInt32(b - 65)
            case 97...122: v = UInt32(b - 97 + 26)
            case 48...57: v = UInt32(b - 48 + 52)
            case UInt8(ascii: "+"), UInt8(ascii: "-"): v = 62
            case UInt8(ascii: "/"), UInt8(ascii: "_"): v = 63
            case UInt8(ascii: "="): bits = 0; acc = 0; continue
            default: continue
            }
            acc = (acc << 6) | v
            bits += 6
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((acc >> UInt32(bits)) & 0xFF))
                acc &= (1 << UInt32(bits)) - 1
            }
        }
        return Data(out)
    }

    static func quotedPrintable(_ bytes: ArraySlice<UInt8>) -> Data {
        let b = Array(bytes)
        var out = [UInt8]()
        out.reserveCapacity(b.count)
        func hex(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57: return c - 48
            case 65...70: return c - 55
            case 97...102: return c - 87
            default: return nil
            }
        }
        var i = 0
        var protected = 0
        while i < b.count {
            let c = b[i]
            if c == UInt8(ascii: "=") {
                var j = i + 1
                while j < b.count, b[j] == 0x20 || b[j] == 0x09 { j += 1 }
                if j < b.count, b[j] == 0x0D || b[j] == 0x0A {
                    if b[j] == 0x0D, j + 1 < b.count, b[j + 1] == 0x0A { j += 1 }
                    i = j + 1
                    continue
                }
                if i + 2 < b.count, let h = hex(b[i + 1]), let l = hex(b[i + 2]) {
                    out.append(h << 4 | l)
                    protected = out.count
                    i += 3
                    continue
                }
                if j >= b.count { i = j; continue }
                out.append(c)
                i += 1
            } else if c == 0x0D || c == 0x0A {
                while out.count > protected, let last = out.last, last == 0x20 || last == 0x09 { out.removeLast() }
                out.append(c)
                i += 1
            } else {
                out.append(c)
                i += 1
            }
        }
        return Data(out)
    }
}
