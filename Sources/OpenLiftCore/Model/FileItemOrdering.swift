import Foundation

/// Sorting and grouping helpers shared by every browser mode.
public enum FileItemOrdering {

    /// Sorts a listing according to `descriptor`.
    ///
    /// Comparison is localized and case-insensitive for names, directories
    /// optionally float to the top, and ties fall back to name so the result
    /// is stable across refreshes.
    public static func sorted(_ items: [FileItem], by descriptor: SortDescriptor) -> [FileItem] {
        items.sorted { lhs, rhs in
            if descriptor.foldersFirst, lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory
            }

            let primary = compare(lhs, rhs, key: descriptor.key)
            if primary != .orderedSame {
                return descriptor.ascending ? primary == .orderedAscending
                                            : primary == .orderedDescending
            }

            // Stable tie-breaker on name.
            let name = lhs.name.localizedStandardCompare(rhs.name)
            if name != .orderedSame {
                return name == .orderedAscending
            }
            return lhs.url.path < rhs.url.path
        }
    }

    private static func compare(_ lhs: FileItem, _ rhs: FileItem, key: SortKey) -> ComparisonResult {
        switch key {
        case .name:
            return lhs.name.localizedStandardCompare(rhs.name)
        case .kind:
            let result = lhs.kind.localizedStandardCompare(rhs.kind)
            return result == .orderedSame ? lhs.name.localizedStandardCompare(rhs.name) : result
        case .size:
            let left = lhs.size ?? 0
            let right = rhs.size ?? 0
            if left == right { return .orderedSame }
            return left < right ? .orderedAscending : .orderedDescending
        case .modified:
            return compareDates(lhs.modified, rhs.modified)
        case .created:
            return compareDates(lhs.created, rhs.created)
        }
    }

    private static func compareDates(_ lhs: Date?, _ rhs: Date?) -> ComparisonResult {
        switch (lhs, rhs) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedAscending
        case (_, nil): return .orderedDescending
        case (let l?, let r?):
            if l == r { return .orderedSame }
            return l < r ? .orderedAscending : .orderedDescending
        }
    }

    /// Groups an already-sorted listing.
    public static func grouped(_ items: [FileItem], by key: GroupKey) -> [(title: String, items: [FileItem])] {
        guard key != .none else {
            return items.isEmpty ? [] : [("", items)]
        }

        var buckets: [String: [FileItem]] = [:]
        for item in items {
            let title: String
            switch key {
            case .kind:
                title = item.kind
            case .name, .none:
                let first = item.name.first.map(String.init) ?? "#"
                title = first.uppercased()
            }
            buckets[title, default: []].append(item)
        }

        return buckets.keys
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { ($0, buckets[$0] ?? []) }
    }
}
