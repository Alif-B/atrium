import ApplicationServices

enum AX {
    /// Literal key string: the `kAXTrustedCheckOptionPrompt` global is not concurrency-safe in Swift 6.
    static func isTrusted(prompt: Bool) -> Bool {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": prompt] as CFDictionary)
    }
}
