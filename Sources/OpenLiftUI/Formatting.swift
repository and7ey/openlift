import Foundation

/// Shared value formatters for the browser UI.
@MainActor
public enum Formatting {
    public static let bytes: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.isAdaptive = true
        return formatter
    }()

    public static let date: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    public static func size(_ bytes: Int64?) -> String {
        guard let bytes else { return "—" }
        if bytes < 1000 { return "\(bytes) bytes" }
        return bytesFormatter.string(fromByteCount: bytes)
    }

    public static func modified(_ date: Date?) -> String {
        guard let date else { return "—" }
        return self.date.string(from: date)
    }

    private static var bytesFormatter: ByteCountFormatter { bytes }
}
