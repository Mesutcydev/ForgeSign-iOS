import Foundation
import Security
import SwiftUI

struct P12Info {
    let commonName: String?
    let organization: String?
    let teamID: String?
    let notBefore: Date?
    let notAfter: Date?
}

enum ExpiryTone {
    case good, warn, bad

    func color(in theme: ForgeTheme) -> Color {
        switch self {
        case .good: return theme.good
        case .warn: return theme.warn
        case .bad: return theme.bad
        }
    }
}

/// Validates a PKCS#12 and reports certificate metadata plus remaining
/// validity. Primary path uses the vendored OpenSSL engine (accepts every
/// p12 the signer accepts, including OpenSSL-3 AES-256 files); the Security
/// framework is the fallback where the bridge is unavailable.
enum P12Inspector {
    static func inspect(url: URL, password: String) -> P12Info? {
        #if FORGE_BRIDGE
        if let info = inspectViaEngine(url: url, password: password) {
            return info
        }
        #endif
        return inspectViaSecurity(url: url, password: password)
    }

    #if FORGE_BRIDGE
    private static func inspectViaEngine(url: URL, password: String) -> P12Info? {
        var cnBuf = [CChar](repeating: 0, count: 256)
        var oBuf = [CChar](repeating: 0, count: 256)
        var ouBuf = [CChar](repeating: 0, count: 256)
        var msgBuf = [CChar](repeating: 0, count: 256)
        var notAfter: Int64 = 0
        let status = forgesign_p12_info(url.path, password,
                                        &cnBuf, Int32(cnBuf.count),
                                        &oBuf, Int32(oBuf.count),
                                        &ouBuf, Int32(ouBuf.count),
                                        &notAfter,
                                        &msgBuf, Int32(msgBuf.count))
        guard status == 0 else { return nil }

        func string(_ buffer: [CChar]) -> String? {
            let s = String(cString: buffer)
            return s.isEmpty ? nil : s
        }
        return P12Info(commonName: string(cnBuf),
                       organization: string(oBuf),
                       teamID: string(ouBuf),
                       notBefore: nil,
                       notAfter: notAfter > 0 ? Date(timeIntervalSince1970: TimeInterval(notAfter)) : nil)
    }
    #endif

    private static func inspectViaSecurity(url: URL, password: String) -> P12Info? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        var items: CFArray?
        let options = [kSecImportExportPassphrase as String: password] as CFDictionary
        guard SecPKCS12Import(data as CFData, options, &items) == errSecSuccess,
              let list = items as? [[String: Any]],
              let entry = list.first,
              let identityValue = entry[kSecImportItemIdentity as String]
        else { return nil }
        let identity = identityValue as! SecIdentity

        var certificateRef: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificateRef) == errSecSuccess,
              let certificate = certificateRef
        else { return nil }

        let summary = SecCertificateCopySubjectSummary(certificate) as String?
        let x509 = X509Lite.parse(SecCertificateCopyData(certificate) as Data)

        return P12Info(commonName: summary ?? x509?.commonName,
                       organization: x509?.organization,
                       teamID: x509?.teamID,
                       notBefore: x509?.notBefore,
                       notAfter: x509?.notAfter)
    }

    /// Human-readable remaining validity plus a semantic tone
    /// (>30 days good, <=30 days warn, expired bad).
    static func expiry(_ notAfter: Date?, now: Date = .now) -> (text: String, tone: ExpiryTone) {
        guard let notAfter else { return ("no expiry", .warn) }
        let interval = notAfter.timeIntervalSince(now)
        if interval <= 0 {
            let days = Int(-interval / 86_400)
            return (days < 1 ? "expired" : "expired \(days)d", .bad)
        }
        if interval < 3_600 * 24 {
            let hours = max(1, Int(interval / 3_600))
            return ("\(hours)h left", .warn)
        }
        let days = Int((interval / 86_400).rounded(.up))
        return ("\(days)d left", days <= 30 ? .warn : .good)
    }
}

/// Minimal DER walker extracting validity dates and subject CN / O / OU
/// from an X.509 certificate.
struct X509Lite {
    let notBefore: Date?
    let notAfter: Date?
    let commonName: String?
    let organization: String?
    let teamID: String?

    private static let oidCN: [UInt8] = [0x55, 0x04, 0x03]
    private static let oidO: [UInt8] = [0x55, 0x04, 0x0A]
    private static let oidOU: [UInt8] = [0x55, 0x04, 0x0B]

    static func parse(_ data: Data) -> X509Lite? {
        var outer = DERReader(bytes: [UInt8](data))
        guard let cert = outer.element(), cert.tag == 0x30 else { return nil }
        var tbsWrap = DERReader(bytes: cert.content)
        guard let tbs = tbsWrap.element(), tbs.tag == 0x30 else { return nil }
        var seq = DERReader(bytes: tbs.content)

        var notBefore: Date?
        var notAfter: Date?
        var cn: String?
        var o: String?
        var ou: String?

        var logical = 0
        var first = true
        while let el = seq.element() {
            if first {
                first = false
                if el.tag == 0xA0 { continue }   // explicit version tag
            }
            switch logical {
            case 3:                              // validity
                var validity = DERReader(bytes: el.content)
                if let nb = validity.element() { notBefore = parseTime(nb) }
                if let na = validity.element() { notAfter = parseTime(na) }
            case 4:                              // subject
                parseName(el.content) { oid, value in
                    if oid == oidCN { cn = value }
                    if oid == oidO { o = value }
                    if oid == oidOU { ou = value }
                }
            default:
                break
            }
            logical += 1
        }

        return X509Lite(notBefore: notBefore, notAfter: notAfter,
                        commonName: cn, organization: o, teamID: ou)
    }

    private static func parseName(_ content: [UInt8], visit: ([UInt8], String) -> Void) {
        var name = DERReader(bytes: content)
        while let rdn = name.element(), rdn.tag == 0x31 {
            var set = DERReader(bytes: rdn.content)
            while let atv = set.element(), atv.tag == 0x30 {
                var pair = DERReader(bytes: atv.content)
                guard let oid = pair.element(), oid.tag == 0x06,
                      let value = pair.element() else { continue }
                visit(oid.content, String(decoding: value.content, as: UTF8.self))
            }
        }
    }

    private static func parseTime(_ el: (tag: UInt8, content: [UInt8])) -> Date? {
        let raw = String(decoding: el.content, as: UTF8.self)
        guard raw.hasSuffix("Z") else { return nil }
        let digits = String(raw.dropLast())
        let year: Int
        let rest: String
        if el.tag == 0x17 {                      // UTCTime YYMMDDHHMMSS
            guard let yy = Int(digits.prefix(2)) else { return nil }
            year = yy < 50 ? 2000 + yy : 1900 + yy
            rest = String(digits.dropFirst(2))
        } else if el.tag == 0x18 {               // GeneralizedTime YYYYMMDDHHMMSS
            guard let yyyy = Int(digits.prefix(4)) else { return nil }
            year = yyyy
            rest = String(digits.dropFirst(4))
        } else {
            return nil
        }
        guard rest.count >= 10,
              let month = Int(rest.prefix(2)),
              let day = Int(rest.dropFirst(2).prefix(2)),
              let hour = Int(rest.dropFirst(4).prefix(2)),
              let minute = Int(rest.dropFirst(6).prefix(2)),
              let second = Int(rest.dropFirst(8).prefix(2))
        else { return nil }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        components.timeZone = TimeZone(secondsFromGMT: 0)
        return Calendar(identifier: .gregorian).date(from: components)
    }
}

private struct DERReader {
    let bytes: [UInt8]
    var pos = 0

    mutating func element() -> (tag: UInt8, content: [UInt8])? {
        guard pos < bytes.count else { return nil }
        let tag = bytes[pos]
        pos += 1
        guard pos < bytes.count else { return nil }
        var length = Int(bytes[pos])
        pos += 1
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard count <= 4, pos + count <= bytes.count else { return nil }
            length = 0
            for _ in 0..<count {
                length = length << 8 | Int(bytes[pos])
                pos += 1
            }
        }
        guard pos + length <= bytes.count else { return nil }
        let content = Array(bytes[pos..<pos + length])
        pos += length
        return (tag, content)
    }
}
