import Foundation

/// Minimal, total ordering over `MAJOR.MINOR.PATCH` with an optional pre-release
/// suffix. Pre-release builds sort below the corresponding final release.
public enum SemanticVersion {
    public static func normalise(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("v") || value.hasPrefix("V") { value.removeFirst() }
        return value
    }

    public static func components(_ raw: String) -> (numbers: [Int], prerelease: String?) {
        let normalised = normalise(raw)
        let parts = normalised.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numeric = parts[0].split(separator: ".").map { Int($0) ?? 0 }
        let prerelease = parts.count > 1 && !parts[1].isEmpty ? String(parts[1]) : nil
        return (numeric, prerelease)
    }

    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let lhs = components(candidate)
        let rhs = components(current)

        let count = max(lhs.numbers.count, rhs.numbers.count)
        for index in 0..<count {
            let left = index < lhs.numbers.count ? lhs.numbers[index] : 0
            let right = index < rhs.numbers.count ? rhs.numbers[index] : 0
            if left != right { return left > right }
        }

        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil): return false
        case (nil, .some): return true      // 1.2.0 beats 1.2.0-beta.1
        case (.some, nil): return false
        case let (.some(left), .some(right)): return left.compare(right, options: .numeric) == .orderedDescending
        }
    }
}
