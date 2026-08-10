import CryptoKit
import Darwin
import Foundation
import Security

struct CodexCredential: Sendable {
    let accessToken: String
    let accountID: String
    let planType: String?
}

enum CodexCredentialSourceError: Error, Equatable, Sendable {
    case invalidHome
    case keychainReadFailed
    case credentialFileUnreadable
    case malformedCredential
    case apiKeyCredential
    case unsupportedCredential
    case missingAccountID
    case accountMismatch
    case undecodableExpiration
    case insufficientLifetime
}

enum CodexKeychainReadResult: Sendable {
    case found(Data)
    case itemNotFound
    case denied
    case interactionFailed
    case failed
}

struct CodexCredentialSource: Sendable {
    static let tokenLifetimeSafetyMarginS: TimeInterval = 30
    static let maximumCredentialRecordBytes = 256 * 1_024

    private let environment: [String: String]
    private let homeDirectory: URL
    private let keychainReader: @Sendable (String) -> CodexKeychainReadResult
    private let fileReader: @Sendable (URL) throws -> Data
    private let now: @Sendable () -> Date

    init() {
        self.init(
            environment: ProcessInfo.processInfo.environment,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            keychainReader: Self.readKeychain(account:),
            fileReader: Self.readOwnerOnlyRegularFile(at:),
            now: Date.init
        )
    }

    init(
        environment: [String: String],
        homeDirectory: URL,
        keychainReader: @escaping @Sendable (String) -> CodexKeychainReadResult,
        fileReader: @escaping @Sendable (URL) throws -> Data = Self.readOwnerOnlyRegularFile(at:),
        now: @escaping @Sendable () -> Date
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.keychainReader = keychainReader
        self.fileReader = fileReader
        self.now = now
    }

    func withCredential(
        requiredValidityS: TimeInterval,
        _ body: (CodexCredential) throws -> Void
    ) throws {
        var recordData = try readCredentialRecord()
        defer {
            recordData.resetBytes(in: recordData.startIndex ..< recordData.endIndex)
            recordData.removeAll(keepingCapacity: false)
        }
        try body(
            Self.parseCredential(
                recordData,
                validAfter: now().addingTimeInterval(
                    requiredValidityS + Self.tokenLifetimeSafetyMarginS
                )
            )
        )
    }

    func activeHomeURL() throws -> URL {
        let home: URL
        if let configured = environment["CODEX_HOME"], !configured.isEmpty {
            guard NSString(string: configured).isAbsolutePath else {
                throw CodexCredentialSourceError.invalidHome
            }
            home = URL(fileURLWithPath: configured, isDirectory: true)
        } else {
            home = homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        }
        return home.standardizedFileURL.resolvingSymlinksInPath()
    }

    func keychainAccount() throws -> String {
        let path = try activeHomeURL().path
        let digest = SHA256.hash(data: Data(path.utf8))
        let hexadecimal = digest.map { String(format: "%02x", $0) }.joined()
        return "cli|\(hexadecimal.prefix(16))"
    }

    private func readCredentialRecord() throws -> Data {
        switch keychainReader(try keychainAccount()) {
        case let .found(data):
            return data
        case .itemNotFound:
            do {
                return try fileReader(
                    try activeHomeURL().appendingPathComponent("auth.json", isDirectory: false)
                )
            } catch {
                throw CodexCredentialSourceError.credentialFileUnreadable
            }
        case .denied, .interactionFailed, .failed:
            throw CodexCredentialSourceError.keychainReadFailed
        }
    }

    private static func parseCredential(
        _ data: Data,
        validAfter: Date
    ) throws -> CodexCredential {
        var rawObject: Any?
        do {
            rawObject = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw CodexCredentialSourceError.malformedCredential
        }
        defer { rawObject = nil }
        guard let record = rawObject as? [String: Any] else {
            throw CodexCredentialSourceError.malformedCredential
        }

        if exactNonEmptyString(record["OPENAI_API_KEY"]) != nil {
            throw CodexCredentialSourceError.apiKeyCredential
        }
        if let mode = trimmedNonEmptyString(record["auth_mode"]),
           mode.lowercased() != "chatgpt" {
            if ["apikey", "api_key"].contains(mode.lowercased()) {
                throw CodexCredentialSourceError.apiKeyCredential
            }
            throw CodexCredentialSourceError.unsupportedCredential
        }
        if record["agent_identity"] != nil
            || exactNonEmptyString(record["personal_access_token"]) != nil
            || record["bedrock_api_key"] != nil
        {
            throw CodexCredentialSourceError.unsupportedCredential
        }
        guard let tokens = record["tokens"] as? [String: Any],
              let accessToken = exactNonBlankString(tokens["access_token"]),
              exactNonBlankString(tokens["refresh_token"]) != nil,
              let idToken = exactNonBlankString(tokens["id_token"]) else {
            throw CodexCredentialSourceError.unsupportedCredential
        }

        let accessClaims = try jwtClaims(accessToken)
        let idClaims = try jwtClaims(idToken)
        guard let expiration = numericDate(accessClaims["exp"]) else {
            throw CodexCredentialSourceError.undecodableExpiration
        }
        guard expiration > validAfter else {
            throw CodexCredentialSourceError.insufficientLifetime
        }

        guard let storedAccountID = trimmedNonEmptyString(tokens["account_id"]) else {
            throw CodexCredentialSourceError.missingAccountID
        }
        let accessAccountID = authClaim("chatgpt_account_id", in: accessClaims)
        let idAccountID = authClaim("chatgpt_account_id", in: idClaims)
        let accountIDs = Set([storedAccountID, accessAccountID, idAccountID].compactMap { $0 })
        guard accountIDs.count == 1, let accountID = accountIDs.first else {
            throw CodexCredentialSourceError.accountMismatch
        }
        let planType = authClaim("chatgpt_plan_type", in: idClaims)
        return CodexCredential(
            accessToken: accessToken,
            accountID: accountID,
            planType: planType
        )
    }

    private static func jwtClaims(_ token: String) throws -> [String: Any] {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty }) else {
            throw CodexCredentialSourceError.undecodableExpiration
        }
        var encoded = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded.append(String(repeating: "=", count: (4 - encoded.count % 4) % 4))
        guard var payload = Data(base64Encoded: encoded) else {
            throw CodexCredentialSourceError.undecodableExpiration
        }
        defer {
            payload.resetBytes(in: payload.startIndex ..< payload.endIndex)
            payload.removeAll(keepingCapacity: false)
        }
        guard let claims = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            throw CodexCredentialSourceError.undecodableExpiration
        }
        return claims
    }

    private static func authClaim(_ name: String, in claims: [String: Any]) -> String? {
        guard let auth = claims["https://api.openai.com/auth"] as? [String: Any] else {
            return nil
        }
        return trimmedNonEmptyString(auth[name])
    }

    private static func numericDate(_ value: Any?) -> Date? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite,
              number.doubleValue.rounded(.towardZero) == number.doubleValue,
              number.doubleValue > 0 else {
            return nil
        }
        return Date(timeIntervalSince1970: number.doubleValue)
    }

    private static func exactNonEmptyString(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        return value
    }

    private static func exactNonBlankString(_ value: Any?) -> String? {
        guard let value = exactNonEmptyString(value),
              value.trimmingCharacters(in: .whitespacesAndNewlines) == value,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }

    private static func trimmedNonEmptyString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func readKeychain(account: String) -> CodexKeychainReadResult {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "Codex Auth",
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return .itemNotFound }
        if status == errSecAuthFailed { return .denied }
        if status == errSecInteractionNotAllowed || status == errSecUserCanceled {
            return .interactionFailed
        }
        guard status == errSecSuccess, let data = item as? Data else { return .failed }
        return .found(data)
    }

    static func readOwnerOnlyRegularFile(at url: URL) throws -> Data {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw CodexCredentialSourceError.credentialFileUnreadable
        }
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              status.st_uid == geteuid(),
              status.st_mode & 0o077 == 0,
              status.st_size >= 0,
              status.st_size <= maximumCredentialRecordBytes else {
            _ = Darwin.close(descriptor)
            throw CodexCredentialSourceError.credentialFileUnreadable
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            let data = try handle.read(upToCount: maximumCredentialRecordBytes + 1) ?? Data()
            guard data.count <= maximumCredentialRecordBytes else {
                throw CodexCredentialSourceError.credentialFileUnreadable
            }
            return data
        } catch {
            throw CodexCredentialSourceError.credentialFileUnreadable
        }
    }
}
