import Foundation

/// How a batch of items should be renamed.
public struct BatchRenameOptions: Sendable, Equatable {
    /// Placeholders: `{name}`, `{ext}`, `{n}`…`{nnnn}`, `{date}`.
    public var template: String
    public var find: String
    public var replace: String
    public var caseSensitive: Bool
    public var startNumber: Int
    public var numberPadding: Int

    public init(
        template: String = "{name}{ext}",
        find: String = "",
        replace: String = "",
        caseSensitive: Bool = false,
        startNumber: Int = 1,
        numberPadding: Int = 1
    ) {
        self.template = template
        self.find = find
        self.replace = replace
        self.caseSensitive = caseSensitive
        self.startNumber = startNumber
        self.numberPadding = numberPadding
    }
}

public struct BatchRenameEntry: Sendable, Equatable {
    public let source: URL
    public let originalName: String
    public let proposedName: String
    /// `nil` when the rename is safe; otherwise a user-facing reason.
    public let issue: String?

    public init(source: URL, originalName: String, proposedName: String, issue: String?) {
        self.source = source
        self.originalName = originalName
        self.proposedName = proposedName
        self.issue = issue
    }

    public var target: URL {
        source.deletingLastPathComponent().appendingPathComponent(proposedName)
    }

    public var isValid: Bool { issue == nil }
    public var isChange: Bool { proposedName != originalName }
}

public struct BatchRenamePlan: Sendable {
    public let entries: [BatchRenameEntry]

    public init(entries: [BatchRenameEntry]) {
        self.entries = entries
    }

    public var hasChanges: Bool { entries.contains(where: \.isChange) }
    public var isValid: Bool { !entries.isEmpty && entries.allSatisfy(\.isValid) }
}

/// Builds a rename plan for a selection.
///
/// Names are produced in a stable order (localized name order), so numbering is
/// predictable. Conflicts with existing items outside the selection and
/// duplicate proposals are reported instead of guessed:
/// two items may swap names, but nothing is overwritten.
public struct BatchRenamePlanner: Sendable {
    public init() {}

    public func plan(urls: [URL], options: BatchRenameOptions) -> BatchRenamePlan {
        let sorted = urls.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        let selectedPaths = Set(sorted.map { $0.standardizedFileURL.path })
        let selectedPathsLower = Set(sorted.map { $0.standardizedFileURL.path.lowercased() })

        var proposed: [(url: URL, original: String, base: String, ext: String, name: String)] = []
        var number = max(0, options.startNumber)

        for url in sorted {
            let original = url.lastPathComponent
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let base: String
            let ext: String
            if isDirectory {
                base = original
                ext = ""
            } else {
                base = url.deletingPathExtension().lastPathComponent
                ext = url.pathExtension
            }

            let replacedBase = replace(
                in: base,
                find: options.find,
                with: options.replace,
                caseSensitive: options.caseSensitive
            )
            let name = expand(
                template: options.template,
                name: replacedBase,
                ext: isDirectory ? "" : ext,
                number: number,
                padding: max(1, options.numberPadding)
            )
            proposed.append((url, original, base, ext, name))
            number += 1
        }

        // Case-insensitive name collisions inside the batch.
        var counts: [String: Int] = [:]
        for item in proposed {
            counts[batchKey(for: item.url, name: item.name), default: 0] += 1
        }

        let entries = proposed.map { item -> BatchRenameEntry in
            let issue = issue(
                for: item.url,
                proposedName: item.name,
                counts: counts,
                selectedPaths: selectedPaths,
                selectedPathsLower: selectedPathsLower
            )
            return BatchRenameEntry(
                source: item.url,
                originalName: item.original,
                proposedName: item.name,
                issue: issue
            )
        }
        return BatchRenamePlan(entries: entries)
    }

    // MARK: - Names

    private func issue(
        for source: URL,
        proposedName: String,
        counts: [String: Int],
        selectedPaths: Set<String>,
        selectedPathsLower: Set<String>
    ) -> String? {
        if proposedName.isEmpty { return "Name is empty" }
        if proposedName == "." || proposedName == ".." { return "Reserved name" }
        if proposedName.contains("/") { return "Name contains “/”" }
        if proposedName.utf8.count > 255 { return "Name is too long" }
        if proposedName == source.lastPathComponent { return nil }

        if counts[batchKey(for: source, name: proposedName), default: 0] > 1 {
            return "Duplicate name in the batch"
        }

        guard FileManager.default.fileExists(atPath: source.path) else {
            return "Source no longer exists"
        }

        let target = source.deletingLastPathComponent().appendingPathComponent(proposedName)
        let targetPath = target.standardizedFileURL.path
        let sourcePath = source.standardizedFileURL.path
        let isSelf = targetPath == sourcePath
        let isCaseOnly = targetPath.lowercased() == sourcePath.lowercased()
        let isSelected = selectedPaths.contains(targetPath) || selectedPathsLower.contains(targetPath.lowercased())

        if FileManager.default.fileExists(atPath: targetPath), !isSelf, !isCaseOnly, !isSelected {
            return "An item with this name already exists"
        }
        return nil
    }

    private func batchKey(for url: URL, name: String) -> String {
        let parent = url.deletingLastPathComponent().standardizedFileURL.path
        let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return parent + "\u{0}" + folded
    }

    private func replace(in text: String, find: String, with replacement: String, caseSensitive: Bool) -> String {
        guard !find.isEmpty else { return text }
        var result = text
        var searchStart = result.startIndex
        let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]

        while searchStart < result.endIndex,
              let range = result.range(of: find, options: options, range: searchStart..<result.endIndex) {
            result.replaceSubrange(range, with: replacement)
            guard let next = result.index(range.lowerBound, offsetBy: replacement.count, limitedBy: result.endIndex) else {
                break
            }
            searchStart = next
        }
        return result
    }

    private func expand(
        template: String,
        name: String,
        ext: String,
        number: Int,
        padding: Int
    ) -> String {
        var result = template
            .replacingOccurrences(of: "{name}", with: name)
            .replacingOccurrences(of: "{ext}", with: ext.isEmpty ? "" : ".\(ext)")
            .replacingOccurrences(of: "{date}", with: Self.dateString())

        // Replace {n}, {nn}, {nnn}, … with a zero-padded sequence number.
        let pattern = try? NSRegularExpression(pattern: "\\{(n+)\\}")
        if let pattern {
            let matches = pattern.matches(
                in: result,
                range: NSRange(result.startIndex..<result.endIndex, in: result)
            )
            for match in matches.reversed() {
                guard let range = Range(match.range(at: 0), in: result),
                      let countRange = Range(match.range(at: 1), in: result) else { continue }
                let width = max(padding, result[countRange].count)
                let value = String(format: "%0\(width)d", number)
                result.replaceSubrange(range, with: value)
            }
        }
        return result
    }

    private static func dateString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}

/// Applies a validated plan with a staging pass, so swapping names and
/// case-only renames never overwrite a source half-way through.
public struct BatchRenameExecutor: Sendable {
    public init() {}

    public func execute(_ plan: BatchRenamePlan) throws -> [FileOperationRecord.Pair] {
        let changes = plan.entries.filter(\.isChange)
        guard plan.isValid else {
            throw BatchRenameError.invalidPlan
        }
        guard !changes.isEmpty else { return [] }

        let manager = FileManager.default
        var staged: [(original: URL, temporary: URL, target: URL)] = []

        func rollbackStaged() {
            for item in staged.reversed() {
                try? manager.moveItem(at: item.temporary, to: item.original)
            }
        }

        for entry in changes {
            let temporary = entry.source
                .deletingLastPathComponent()
                .appendingPathComponent(".openlift-rename-\(UUID().uuidString.prefix(8)).tmp")
            do {
                try manager.moveItem(at: entry.source, to: temporary)
                staged.append((entry.source, temporary, entry.target))
            } catch {
                rollbackStaged()
                throw error
            }
        }

        var completed: [Int] = []
        for (index, item) in staged.enumerated() {
            do {
                try manager.moveItem(at: item.temporary, to: item.target)
                completed.append(index)
            } catch {
                // Put already-finished targets back under their staging names,
                // then restore every source.
                for done in completed.reversed() {
                    let finished = staged[done]
                    try? manager.moveItem(at: finished.target, to: finished.temporary)
                }
                rollbackStaged()
                throw error
            }
        }

        return staged.map {
            FileOperationRecord.Pair(source: $0.original, target: $0.target)
        }
    }
}

public enum BatchRenameError: Error, LocalizedError {
    case invalidPlan

    public var errorDescription: String? {
        switch self {
        case .invalidPlan:
            return "The batch rename contains conflicts."
        }
    }
}
