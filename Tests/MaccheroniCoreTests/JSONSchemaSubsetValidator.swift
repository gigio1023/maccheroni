import Foundation

/// A JSON Schema 2020-12 validator covering the keywords the published
/// Maccheroni contracts actually use.
///
/// It exists because the canonical scorer validates sealed derived manifests
/// against `derived-manifest.schema.json` in Python, and nothing in the Swift
/// tree checked that the manifests this package *writes* satisfy that schema.
/// A whole schema library is not the point; the point is that
/// `DerivedManifest.encode` and the published contract are checked against each
/// other in the same test run that builds them.
///
/// Supported: `$ref` (in-document pointers and pointers into a sibling schema
/// file), `type`, `const`, `enum`, `properties`, `required`,
/// `additionalProperties: false`, `minProperties`, `allOf`, `anyOf`, `oneOf`,
/// `if`/`then`/`else`, `items`, `contains` with `minContains`/`maxContains`,
/// `minItems`, `maxItems`, `minLength`, `pattern`, `minimum`, and
/// `exclusiveMinimum`. `format` is parsed and ignored, as it is an annotation
/// unless a checker is attached. A schema keyword outside this list is
/// reported rather than skipped, so a contract that grows one cannot pass here
/// by being misread as empty.
enum JSONValue: Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    static func make(_ any: Any) -> JSONValue {
        if any is NSNull { return .null }
        if let number = any as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            return .number(number.doubleValue)
        }
        if let string = any as? String { return .string(string) }
        if let array = any as? [Any] { return .array(array.map(make)) }
        if let object = any as? [String: Any] {
            return .object(object.mapValues(make))
        }
        return .null
    }

    static func parse(_ data: Data) throws -> JSONValue {
        make(try JSONSerialization.jsonObject(with: data, options: []))
    }

    var typeName: String {
        switch self {
        case .null: "null"
        case .bool: "boolean"
        case .number: "number"
        case .string: "string"
        case .array: "array"
        case .object: "object"
        }
    }
}

struct JSONSchemaValidator {
    /// Keyed by file name. The empty key is the document validation starts in.
    private let documents: [String: JSONValue]

    /// Every keyword this validator understands. Anything else in a schema
    /// object is an unsupported-keyword failure rather than a silent pass.
    private static let known: Set<String> = [
        "$schema", "$id", "$defs", "$ref", "title", "description", "format",
        "type", "const", "enum", "properties", "required",
        "additionalProperties", "minProperties", "allOf", "anyOf", "oneOf",
        "if", "then", "else", "items", "contains", "minContains",
        "maxContains", "minItems", "maxItems", "minLength", "pattern",
        "minimum", "exclusiveMinimum",
    ]

    init(schemaURL: URL, siblingFileNames: [String] = []) throws {
        var documents: [String: JSONValue] = [:]
        documents[""] = try JSONValue.parse(try Data(contentsOf: schemaURL))
        let directory = schemaURL.deletingLastPathComponent()
        for name in siblingFileNames {
            documents[name] = try JSONValue.parse(
                try Data(contentsOf: directory.appendingPathComponent(name))
            )
        }
        self.documents = documents
    }

    /// Every reason `instance` is not valid, deepest first, or an empty array.
    func failures(for instance: JSONValue) -> [String] {
        guard let root = documents[""] else { return ["schema document missing"] }
        return validate(instance, against: root, document: "", at: "")
    }

    private func resolve(
        _ reference: String,
        document: String
    ) -> (schema: JSONValue, document: String)? {
        let parts = reference.split(
            separator: "#",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        let file = String(parts.first ?? "")
        let pointer = parts.count > 1 ? String(parts[1]) : ""
        let target = file.isEmpty ? document : file
        guard var node = documents[target] else { return nil }
        for rawToken in pointer.split(separator: "/") {
            let token = rawToken
                .replacingOccurrences(of: "~1", with: "/")
                .replacingOccurrences(of: "~0", with: "~")
            guard case let .object(members) = node,
                  let next = members[token]
            else { return nil }
            node = next
        }
        return (node, target)
    }

    private func validate(
        _ instance: JSONValue,
        against schema: JSONValue,
        document: String,
        at path: String
    ) -> [String] {
        guard case let .object(declared) = schema else {
            return ["\(display(path)): schema is not an object"]
        }
        var failures: [String] = []
        var document = document
        var keywords = declared

        if case let .string(reference)? = keywords["$ref"] {
            guard let resolved = resolve(reference, document: document) else {
                return ["\(display(path)): unresolved $ref \(reference)"]
            }
            failures += validate(
                instance,
                against: resolved.schema,
                document: resolved.document,
                at: path
            )
            keywords["$ref"] = nil
            document = resolved.document
        }

        let unsupported = keywords.keys.filter { !Self.known.contains($0) }
        if !unsupported.isEmpty {
            failures.append(
                "\(display(path)): unsupported schema keyword(s) \(unsupported.sorted())"
            )
        }

        failures += validateType(instance, keywords, at: path)
        failures += validateScalars(instance, keywords, at: path)
        failures += validateObject(
            instance,
            keywords,
            document: document,
            at: path
        )
        failures += validateArray(
            instance,
            keywords,
            document: document,
            at: path
        )
        failures += validateCombinators(
            instance,
            keywords,
            document: document,
            at: path
        )
        return failures
    }

    private func validateType(
        _ instance: JSONValue,
        _ keywords: [String: JSONValue],
        at path: String
    ) -> [String] {
        guard let type = keywords["type"] else { return [] }
        let allowed: [String]
        switch type {
        case let .string(name): allowed = [name]
        case let .array(names): allowed = names.compactMap {
            if case let .string(name) = $0 { return name }
            return nil
        }
        default: return ["\(display(path)): malformed type keyword"]
        }
        let actual = instance.typeName
        // An integer instance is a number; JSON Schema also lets a number with
        // a zero fraction satisfy "integer".
        let matches = allowed.contains { name in
            switch name {
            case actual: true
            case "integer":
                if case let .number(value) = instance {
                    value.rounded() == value
                } else { false }
            default: false
            }
        }
        return matches
            ? []
            : ["\(display(path)): type is \(actual), expected \(allowed.joined(separator: " or "))"]
    }

    private func validateScalars(
        _ instance: JSONValue,
        _ keywords: [String: JSONValue],
        at path: String
    ) -> [String] {
        var failures: [String] = []
        if let expected = keywords["const"], instance != expected {
            failures.append("\(display(path)): value is not the required constant")
        }
        if case let .array(options)? = keywords["enum"],
           !options.contains(instance)
        {
            failures.append("\(display(path)): value is not one of the enumerated options")
        }
        if case let .string(text) = instance {
            if case let .number(minimum)? = keywords["minLength"],
               Double(text.count) < minimum
            {
                failures.append("\(display(path)): shorter than minLength")
            }
            if case let .string(pattern)? = keywords["pattern"],
               text.range(of: pattern, options: .regularExpression) == nil
            {
                failures.append("\(display(path)): does not match \(pattern)")
            }
        }
        if case let .number(value) = instance {
            if case let .number(minimum)? = keywords["minimum"], value < minimum {
                failures.append("\(display(path)): below minimum \(minimum)")
            }
            if case let .number(bound)? = keywords["exclusiveMinimum"],
               value <= bound
            {
                failures.append("\(display(path)): not above exclusiveMinimum \(bound)")
            }
        }
        return failures
    }

    private func validateObject(
        _ instance: JSONValue,
        _ keywords: [String: JSONValue],
        document: String,
        at path: String
    ) -> [String] {
        guard case let .object(members) = instance else { return [] }
        var failures: [String] = []
        if case let .array(names)? = keywords["required"] {
            for case let .string(name) in names where members[name] == nil {
                failures.append("\(display(path)): missing required property \(name)")
            }
        }
        if case let .number(minimum)? = keywords["minProperties"],
           Double(members.count) < minimum
        {
            failures.append("\(display(path)): fewer than minProperties properties")
        }
        var declared: Set<String> = []
        if case let .object(properties)? = keywords["properties"] {
            declared = Set(properties.keys)
            for (name, subschema) in properties {
                guard let value = members[name] else { continue }
                failures += validate(
                    value,
                    against: subschema,
                    document: document,
                    at: path + "/" + name
                )
            }
        }
        if case .bool(false)? = keywords["additionalProperties"] {
            for name in members.keys.sorted() where !declared.contains(name) {
                failures.append("\(display(path)): unexpected property \(name)")
            }
        }
        return failures
    }

    private func validateArray(
        _ instance: JSONValue,
        _ keywords: [String: JSONValue],
        document: String,
        at path: String
    ) -> [String] {
        guard case let .array(elements) = instance else { return [] }
        var failures: [String] = []
        if case let .number(minimum)? = keywords["minItems"],
           Double(elements.count) < minimum
        {
            failures.append("\(display(path)): fewer than minItems items")
        }
        if case let .number(maximum)? = keywords["maxItems"],
           Double(elements.count) > maximum
        {
            failures.append("\(display(path)): more than maxItems items")
        }
        if let subschema = keywords["items"] {
            for (index, element) in elements.enumerated() {
                failures += validate(
                    element,
                    against: subschema,
                    document: document,
                    at: path + "/\(index)"
                )
            }
        }
        if let subschema = keywords["contains"] {
            let matches = elements.filter {
                validate($0, against: subschema, document: document, at: path)
                    .isEmpty
            }.count
            var minimum = 1.0
            if case let .number(value)? = keywords["minContains"] { minimum = value }
            if Double(matches) < minimum {
                failures.append("\(display(path)): too few items match contains")
            }
            if case let .number(maximum)? = keywords["maxContains"],
               Double(matches) > maximum
            {
                failures.append("\(display(path)): too many items match contains")
            }
        }
        return failures
    }

    private func validateCombinators(
        _ instance: JSONValue,
        _ keywords: [String: JSONValue],
        document: String,
        at path: String
    ) -> [String] {
        var failures: [String] = []
        if case let .array(branches)? = keywords["allOf"] {
            for branch in branches {
                failures += validate(
                    instance,
                    against: branch,
                    document: document,
                    at: path
                )
            }
        }
        if case let .array(branches)? = keywords["anyOf"] {
            let results = branches.map {
                validate(instance, against: $0, document: document, at: path)
            }
            if !results.contains(where: \.isEmpty) {
                failures.append(
                    "\(display(path)): matches no anyOf branch (\(results.flatMap { $0 }))"
                )
            }
        }
        if case let .array(branches)? = keywords["oneOf"] {
            let results = branches.map {
                validate(instance, against: $0, document: document, at: path)
            }
            let matched = results.filter(\.isEmpty).count
            if matched != 1 {
                failures.append(
                    "\(display(path)): matched \(matched) oneOf branches (\(results.flatMap { $0 }))"
                )
            }
        }
        if let condition = keywords["if"] {
            let holds = validate(
                instance,
                against: condition,
                document: document,
                at: path
            ).isEmpty
            if holds, let consequent = keywords["then"] {
                failures += validate(
                    instance,
                    against: consequent,
                    document: document,
                    at: path
                )
            }
            if !holds, let alternative = keywords["else"] {
                failures += validate(
                    instance,
                    against: alternative,
                    document: document,
                    at: path
                )
            }
        }
        return failures
    }

    private func display(_ path: String) -> String {
        path.isEmpty ? "(root)" : path
    }
}
