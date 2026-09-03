import Foundation
import CryptoKit

/// SPEC §7.5 的签发公钥。发布前用 `tools/license/` 里的私钥对应的公钥替换掉。
/// 空串 = 还没有签发体系,任何许可证都验不过,只有 7 天试用生效。
public let LicensePublicKeyB64URL: String = ""

public struct LicensePayload: Codable, Equatable {
    public let email: String
    /// Unix 秒;null 表示永久。
    public let exp: Double?
    public let seats: Int

    public init(email: String, exp: Double?, seats: Int) {
        self.email = email
        self.exp = exp
        self.seats = seats
    }

    public var expiry: Date? {
        guard let exp = exp else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    /// 签名覆盖的正是这个 canonical JSON(SPEC §2 的通用签名格式)。
    public var canonical: JSONValue {
        return .object([
            "email": .string(email),
            "exp": exp.map { JSONValue.number($0) } ?? JSONValue.null,
            "seats": .int(seats)
        ])
    }
}

public enum LicenseError: Error, Equatable {
    case malformed
    case noPublicKey
    case badSignature
    case expired(Date)
}

/// 试用 / 已授权 / 已过期。App 只根据这个决定要不要拦 run 与 fs.put。
public enum LicenseState: Equatable {
    case trial(daysLeft: Int)
    case trialExpired
    case licensed(email: String, expiry: Date?)
    case licenseExpired(email: String, expiry: Date)
    case invalid(String)

    /// SPEC §7.5:过期后仍可配对与查看,只有 run / fs.put 返回 LICENSE。
    public var blocksWrites: Bool {
        switch self {
        case .trial, .licensed:
            return false
        case .trialExpired, .licenseExpired, .invalid:
            return true
        }
    }
}

public enum License {

    public static let trialDays = 7
    public static let prefix = "MHL1"

    /// `MHL1.<base64url(payload)>.<base64url(sig)>`
    ///
    /// 签名验的是 canonicalJSON(payload)(SPEC §2)。但签发工具也可能直接签了
    /// 中间那段 base64url 字符串,所以两种都接受 —— 验证宽容一点不会削弱安全性,
    /// 两条路径用的都是同一把公钥。
    public static func verify(_ text: String,
                              publicKeyB64URL: String = LicensePublicKeyB64URL,
                              now: Date = Date()) -> Result<LicensePayload, LicenseError> {

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0] == prefix else { return .failure(.malformed) }

        guard let payloadData = Base64URL.decode(parts[1]),
              let signature = Base64URL.decode(parts[2]),
              let payload = try? JSONDecoder().decode(LicensePayload.self, from: payloadData) else {
            return .failure(.malformed)
        }

        guard !publicKeyB64URL.isEmpty,
              let keyRaw = Base64URL.decode(publicKeyB64URL),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyRaw) else {
            return .failure(.noPublicKey)
        }

        let canonical = CanonicalJSON.data(payload.canonical)
        let segment = Data(parts[1].utf8)
        let signedOverCanonical = key.isValidSignature(signature, for: canonical)
        let signedOverSegment = key.isValidSignature(signature, for: segment)
        guard signedOverCanonical || signedOverSegment else { return .failure(.badSignature) }

        if let expiry = payload.expiry, expiry < now {
            return .failure(.expired(expiry))
        }
        return .success(payload)
    }

    /// 签发端用的那一半,测试里用来自己造一张许可证。
    public static func issue(payload: LicensePayload,
                             privateKey: Curve25519.Signing.PrivateKey) -> String? {
        guard let payloadData = try? JSONEncoder().encode(payload),
              let signature = try? privateKey.signature(for: CanonicalJSON.data(payload.canonical)) else {
            return nil
        }
        return [prefix,
                Base64URL.encode(payloadData),
                Base64URL.encode(signature)].joined(separator: ".")
    }

    /// 当前状态。`licenseText` 为空就是试用。
    public static func state(licenseText: String?,
                             trialStart: Date,
                             publicKeyB64URL: String = LicensePublicKeyB64URL,
                             now: Date = Date()) -> LicenseState {

        let text = (licenseText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            switch verify(text, publicKeyB64URL: publicKeyB64URL, now: now) {
            case .success(let payload):
                return .licensed(email: payload.email, expiry: payload.expiry)
            case .failure(let error):
                switch error {
                case .expired(let when):
                    // 过期的许可证还认得出是谁的,说出来比说"无效"有用。
                    let email = payloadEmail(text) ?? "—"
                    return .licenseExpired(email: email, expiry: when)
                case .noPublicKey:
                    return .invalid("noPublicKey")
                case .badSignature:
                    return .invalid("badSignature")
                case .malformed:
                    return .invalid("malformed")
                }
            }
        }

        let end = trialStart.addingTimeInterval(Double(trialDays) * 86400)
        if now >= end { return .trialExpired }
        let left = Int(ceil(end.timeIntervalSince(now) / 86400))
        return .trial(daysLeft: max(1, left))
    }

    private static func payloadEmail(_ text: String) -> String? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let data = Base64URL.decode(parts[1]),
              let payload = try? JSONDecoder().decode(LicensePayload.self, from: data) else {
            return nil
        }
        return payload.email
    }
}
