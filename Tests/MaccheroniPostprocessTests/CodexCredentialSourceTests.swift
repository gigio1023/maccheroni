import CryptoKit
import Darwin
import Foundation
import Testing
@testable import MaccheroniPostprocess

@Suite(.serialized)
struct CodexCredentialSourceTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    @Test func keychainPrecedesFileAndUsesCanonicalActiveHome() throws {
        let root = try credentialTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let realHome = root.appendingPathComponent("real-codex", isDirectory: true)
        let linkedHome = root.appendingPathComponent("linked-codex", isDirectory: true)
        try FileManager.default.createDirectory(at: realHome, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: linkedHome, withDestinationURL: realHome)
        let observedAccount = LockedValue<String?>(nil)
        let fileReads = LockedValue(0)
        let source = CodexCredentialSource(
            environment: ["CODEX_HOME": linkedHome.path],
            homeDirectory: root,
            keychainReader: { account in
                observedAccount.set(account)
                return .found(syntheticCodexCredential(expiration: 2_000_001_000))
            },
            fileReader: { _ in
                fileReads.mutate { $0 += 1 }
                throw CocoaError(.fileReadNoSuchFile)
            },
            now: { now }
        )

        try source.withCredential(requiredValidityS: 60) { credential in
            #expect(credential.accountID == "account-fixture")
            #expect(credential.planType == "plus")
        }
        #expect(fileReads.get() == 0)
        #expect(observedAccount.get() == expectedKeychainAccount(for: realHome.path))
    }

    @Test func fileFallbackOccursOnlyForKeychainItemNotFound() throws {
        let fileReads = LockedValue(0)
        for keychainResult in [
            CodexKeychainReadResult.denied,
            .interactionFailed,
            .failed,
        ] {
            let source = CodexCredentialSource(
                environment: ["CODEX_HOME": "/synthetic/codex-home"],
                homeDirectory: URL(fileURLWithPath: "/unused"),
                keychainReader: { _ in keychainResult },
                fileReader: { _ in
                    fileReads.mutate { $0 += 1 }
                    return syntheticCodexCredential(expiration: 2_000_001_000)
                },
                now: { now }
            )
            #expect(throws: CodexCredentialSourceError.keychainReadFailed) {
                try source.withCredential(requiredValidityS: 60) { _ in }
            }
        }
        #expect(fileReads.get() == 0)

        let fallback = CodexCredentialSource(
            environment: ["CODEX_HOME": "/synthetic/codex-home"],
            homeDirectory: URL(fileURLWithPath: "/unused"),
            keychainReader: { _ in .itemNotFound },
            fileReader: { _ in
                fileReads.mutate { $0 += 1 }
                return syntheticCodexCredential(expiration: 2_000_001_000)
            },
            now: { now }
        )
        try fallback.withCredential(requiredValidityS: 60) { credential in
            #expect(credential.accountID == "account-fixture")
        }
        #expect(fileReads.get() == 1)
    }

    @Test func malformedKeychainRecordDoesNotSelectAValidFile() throws {
        let fileReads = LockedValue(0)
        let source = CodexCredentialSource(
            environment: [:],
            homeDirectory: URL(fileURLWithPath: "/synthetic-home"),
            keychainReader: { _ in .found(Data("not-json".utf8)) },
            fileReader: { _ in
                fileReads.mutate { $0 += 1 }
                return syntheticCodexCredential(expiration: 2_000_001_000)
            },
            now: { now }
        )
        #expect(throws: CodexCredentialSourceError.malformedCredential) {
            try source.withCredential(requiredValidityS: 60) { _ in }
        }
        #expect(fileReads.get() == 0)
    }

    @Test func fallbackFileMustBeReadableOwnerOnlyRegularAndNotASymlink() throws {
        enum InvalidFileCase: CaseIterable { case missing, denied, directory, symlink, wrongMode }

        for invalidCase in InvalidFileCase.allCases {
            let root = try credentialTestDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let home = root.appendingPathComponent("codex", isDirectory: true)
            let auth = home.appendingPathComponent("auth.json")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
            switch invalidCase {
            case .missing:
                break
            case .denied:
                try syntheticCodexCredential(expiration: 2_000_001_000).write(to: auth)
                try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: auth.path)
            case .directory:
                try FileManager.default.createDirectory(at: auth, withIntermediateDirectories: false)
            case .symlink:
                let target = root.appendingPathComponent("target.json")
                try syntheticCodexCredential(expiration: 2_000_001_000).write(to: target)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
                try FileManager.default.createSymbolicLink(at: auth, withDestinationURL: target)
            case .wrongMode:
                try syntheticCodexCredential(expiration: 2_000_001_000).write(to: auth)
                try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: auth.path)
            }
            let source = fileBackedSource(home: home, now: now)
            #expect(throws: CodexCredentialSourceError.credentialFileUnreadable) {
                try source.withCredential(requiredValidityS: 60) { _ in }
            }
        }
    }

    @Test func fileReadDoesNotChangeCredentialContentOrWriteMetadata() throws {
        let root = try credentialTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("codex", isDirectory: true)
        let auth = home.appendingPathComponent("auth.json")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
        let initial = syntheticCodexCredential(expiration: 2_000_001_000)
        try initial.write(to: auth)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: auth.path)
        let before = try readOnlyMetadata(at: auth)
        let source = fileBackedSource(home: home, now: now)

        try source.withCredential(requiredValidityS: 60) { _ in }

        #expect(try Data(contentsOf: auth) == initial)
        #expect(try readOnlyMetadata(at: auth) == before)
    }

    @Test func sourceDoesNotCacheCredentialRecords() throws {
        let reads = LockedValue(0)
        let source = CodexCredentialSource(
            environment: ["CODEX_HOME": "/synthetic/codex-home"],
            homeDirectory: URL(fileURLWithPath: "/unused"),
            keychainReader: { _ in
                let read = reads.mutate { value in
                    value += 1
                    return value
                }
                return .found(syntheticCodexCredential(
                    expiration: 2_000_001_000,
                    accountID: "account-\(read)"
                ))
            },
            now: { now }
        )
        var first: String?
        var second: String?
        try source.withCredential(requiredValidityS: 60) { first = $0.accountID }
        try source.withCredential(requiredValidityS: 60) { second = $0.accountID }
        #expect(first == "account-1")
        #expect(second == "account-2")
        #expect(reads.get() == 2)
    }

    @Test func rejectsAPIKeyAndUnsupportedCredentialModes() throws {
        let apiKeyRecords = [
            jsonData(["auth_mode": "apikey", "OPENAI_API_KEY": "synthetic-key"]),
            jsonData([
                "auth_mode": "chatgpt",
                "OPENAI_API_KEY": "synthetic-key",
                "tokens": syntheticTokenObject(expiration: 2_000_001_000),
            ]),
        ]
        for record in apiKeyRecords {
            #expect(throws: CodexCredentialSourceError.apiKeyCredential) {
                try keychainBackedSource(record: record, now: now)
                    .withCredential(requiredValidityS: 60) { _ in }
            }
        }

        for mode in ["agentIdentity", "personalAccessToken", "bedrockApiKey", "chatgptAuthTokens", "unknown"] {
            let record = jsonData([
                "auth_mode": mode,
                "tokens": syntheticTokenObject(expiration: 2_000_001_000),
            ])
            #expect(throws: CodexCredentialSourceError.unsupportedCredential) {
                try keychainBackedSource(record: record, now: now)
                    .withCredential(requiredValidityS: 60) { _ in }
            }
        }

        for field in ["agent_identity", "personal_access_token", "bedrock_api_key"] {
            var object = try #require(
                JSONSerialization.jsonObject(
                    with: syntheticCodexCredential(expiration: 2_000_001_000)
                ) as? [String: Any]
            )
            if field == "agent_identity" {
                object[field] = ["fixture": true]
            } else {
                object[field] = "fixture"
            }
            #expect(throws: CodexCredentialSourceError.unsupportedCredential) {
                try keychainBackedSource(record: jsonData(object), now: now)
                    .withCredential(requiredValidityS: 60) { _ in }
            }
        }
    }

    @Test func rejectsMalformedOrIncompleteOAuthRecords() throws {
        for record in [
            Data("[]".utf8),
            jsonData(["auth_mode": "chatgpt"]),
            jsonData(["auth_mode": "chatgpt", "tokens": [:]]),
            jsonData([
                "auth_mode": "chatgpt",
                "tokens": [
                    "id_token": syntheticJWT([:]),
                    "access_token": syntheticJWT(["exp": 2_000_001_000]),
                    "account_id": "account-fixture",
                ],
            ]),
        ] {
            #expect(throws: CodexCredentialSourceError.self) {
                try keychainBackedSource(record: record, now: now)
                    .withCredential(requiredValidityS: 60) { _ in }
            }
        }
    }

    @Test func rejectsUndecodableExpiredAndInsufficientLifetimeAccessTokens() throws {
        let undecodable = syntheticCodexCredential(
            expiration: 2_000_001_000,
            accessTokenOverride: "not-a-jwt"
        )
        #expect(throws: CodexCredentialSourceError.undecodableExpiration) {
            try keychainBackedSource(record: undecodable, now: now)
                .withCredential(requiredValidityS: 60) { _ in }
        }

        for expiration in [
            1_999_999_999,
            2_000_000_090,
        ] {
            #expect(throws: CodexCredentialSourceError.insufficientLifetime) {
                try keychainBackedSource(
                    record: syntheticCodexCredential(expiration: expiration),
                    now: now
                ).withCredential(requiredValidityS: 60) { _ in }
            }
        }

        try keychainBackedSource(
            record: syntheticCodexCredential(expiration: 2_000_000_091),
            now: now
        ).withCredential(requiredValidityS: 60) { _ in }
    }

    @Test func rejectsMissingOrMismatchedAccountID() throws {
        let missing = syntheticCodexCredential(
            expiration: 2_000_001_000,
            accountID: nil,
            includeAccountClaim: false
        )
        #expect(throws: CodexCredentialSourceError.missingAccountID) {
            try keychainBackedSource(record: missing, now: now)
                .withCredential(requiredValidityS: 60) { _ in }
        }

        let mismatch = syntheticCodexCredential(
            expiration: 2_000_001_000,
            accountID: "stored-account",
            claimAccountID: "claimed-account"
        )
        #expect(throws: CodexCredentialSourceError.accountMismatch) {
            try keychainBackedSource(record: mismatch, now: now)
                .withCredential(requiredValidityS: 60) { _ in }
        }

        var whitespaceTokens = syntheticTokenObject(expiration: 2_000_001_000)
        whitespaceTokens["account_id"] = " \n "
        #expect(throws: CodexCredentialSourceError.missingAccountID) {
            try keychainBackedSource(
                record: jsonData(["auth_mode": "chatgpt", "tokens": whitespaceTokens]),
                now: now
            ).withCredential(requiredValidityS: 60) { _ in }
        }

        whitespaceTokens = syntheticTokenObject(expiration: 2_000_001_000)
        whitespaceTokens["refresh_token"] = " \t "
        #expect(throws: CodexCredentialSourceError.unsupportedCredential) {
            try keychainBackedSource(
                record: jsonData(["auth_mode": "chatgpt", "tokens": whitespaceTokens]),
                now: now
            ).withCredential(requiredValidityS: 60) { _ in }
        }
    }

    @Test func acceptsNullablePlanTypeAndLegacyChatGPTMode() throws {
        for planType in [nil, " \n "] as [String?] {
            let record = syntheticCodexCredential(
                expiration: 2_000_001_000,
                planType: planType,
                authMode: nil
            )
            try keychainBackedSource(record: record, now: now)
                .withCredential(requiredValidityS: 60) { credential in
                    #expect(credential.accountID == "account-fixture")
                    #expect(credential.planType == nil)
                }
        }
    }

    @Test func rejectsRelativeConfiguredHome() throws {
        let source = CodexCredentialSource(
            environment: ["CODEX_HOME": "relative/codex"],
            homeDirectory: URL(fileURLWithPath: "/unused"),
            keychainReader: { _ in .itemNotFound },
            now: { now }
        )
        #expect(throws: CodexCredentialSourceError.invalidHome) {
            try source.withCredential(requiredValidityS: 60) { _ in }
        }
    }

    @Test func rejectsOversizedFallbackFile() throws {
        let root = try credentialTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("codex", isDirectory: true)
        let auth = home.appendingPathComponent("auth.json")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
        try Data(repeating: 0x20, count: CodexCredentialSource.maximumCredentialRecordBytes + 1)
            .write(to: auth)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: auth.path)

        #expect(throws: CodexCredentialSourceError.credentialFileUnreadable) {
            try fileBackedSource(home: home, now: now)
                .withCredential(requiredValidityS: 60) { _ in }
        }
    }
}

private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func get() -> Value {
        lock.withLock { value }
    }

    func set(_ newValue: Value) {
        lock.withLock { value = newValue }
    }

    func mutate<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.withLock { body(&value) }
    }
}

private struct CredentialMetadata: Equatable {
    let type: mode_t
    let permissions: mode_t
    let owner: uid_t
    let group: gid_t
    let device: dev_t
    let inode: ino_t
    let linkCount: nlink_t
    let size: off_t
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int
}

private func readOnlyMetadata(at url: URL) throws -> CredentialMetadata {
    var status = stat()
    guard url.path.withCString({ Darwin.lstat($0, &status) }) == 0 else {
        throw CocoaError(.fileReadNoSuchFile)
    }
    return CredentialMetadata(
        type: status.st_mode & mode_t(S_IFMT),
        permissions: status.st_mode & 0o777,
        owner: status.st_uid,
        group: status.st_gid,
        device: status.st_dev,
        inode: status.st_ino,
        linkCount: status.st_nlink,
        size: status.st_size,
        modifiedSeconds: status.st_mtimespec.tv_sec,
        modifiedNanoseconds: status.st_mtimespec.tv_nsec,
        changedSeconds: status.st_ctimespec.tv_sec,
        changedNanoseconds: status.st_ctimespec.tv_nsec
    )
}

private func credentialTestDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "maccheroni-codex-credential-tests-\(UUID().uuidString.lowercased())",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    return url
}

private func fileBackedSource(home: URL, now: Date) -> CodexCredentialSource {
    CodexCredentialSource(
        environment: ["CODEX_HOME": home.path],
        homeDirectory: home.deletingLastPathComponent(),
        keychainReader: { _ in .itemNotFound },
        now: { now }
    )
}

private func keychainBackedSource(record: Data, now: Date) -> CodexCredentialSource {
    CodexCredentialSource(
        environment: ["CODEX_HOME": "/synthetic/codex-home"],
        homeDirectory: URL(fileURLWithPath: "/unused"),
        keychainReader: { _ in .found(record) },
        now: { now }
    )
}

private func syntheticCodexCredential(
    expiration: Int,
    accountID: String? = "account-fixture",
    claimAccountID: String? = nil,
    includeAccountClaim: Bool = true,
    planType: String? = "plus",
    authMode: String? = "chatgpt",
    accessTokenOverride: String? = nil
) -> Data {
    var record: [String: Any] = [
        "tokens": syntheticTokenObject(
            expiration: expiration,
            accountID: accountID,
            claimAccountID: claimAccountID,
            includeAccountClaim: includeAccountClaim,
            planType: planType,
            accessTokenOverride: accessTokenOverride
        ),
    ]
    if let authMode { record["auth_mode"] = authMode }
    return jsonData(record)
}

private func syntheticTokenObject(
    expiration: Int,
    accountID: String? = "account-fixture",
    claimAccountID: String? = nil,
    includeAccountClaim: Bool = true,
    planType: String? = "plus",
    accessTokenOverride: String? = nil
) -> [String: Any] {
    let claimAccountID = claimAccountID ?? accountID
    var authClaims: [String: Any] = [:]
    if includeAccountClaim, let claimAccountID {
        authClaims["chatgpt_account_id"] = claimAccountID
    }
    var idAuthClaims = authClaims
    if let planType { idAuthClaims["chatgpt_plan_type"] = planType }
    var tokens: [String: Any] = [
        "id_token": syntheticJWT(["https://api.openai.com/auth": idAuthClaims]),
        "access_token": accessTokenOverride ?? syntheticJWT([
            "exp": expiration,
            "https://api.openai.com/auth": authClaims,
        ]),
        "refresh_token": "synthetic-refresh-token",
    ]
    if let accountID { tokens["account_id"] = accountID }
    return tokens
}

private func syntheticJWT(_ claims: [String: Any]) -> String {
    let header = base64URL(jsonData(["alg": "none"]))
    let payload = base64URL(jsonData(claims))
    return "\(header).\(payload).synthetic-signature"
}

private func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private func jsonData(_ object: Any) -> Data {
    try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private func expectedKeychainAccount(for canonicalPath: String) -> String {
    let digest = SHA256.hash(data: Data(canonicalPath.utf8))
    let hexadecimal = digest.map { String(format: "%02x", $0) }.joined()
    return "cli|\(hexadecimal.prefix(16))"
}
