import Foundation

/// One consistent epoch-millisecond clock for the shell — used for both copy
/// timestamps and the search recency reference, as the C API requires.
public func clipdNowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
