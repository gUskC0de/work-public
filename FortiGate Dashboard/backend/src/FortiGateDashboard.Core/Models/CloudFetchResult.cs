namespace FortiGateDashboard.Core.Models;

/// <summary>
/// Wraps a FortiGate Cloud fetch result together with an explicit truncation signal.
/// The actual FortiGate Cloud pagination contract (page/cursor/offset parameters and
/// continuation semantics) is not verified against vendor documentation or captured API
/// fixtures in this repository, so real pagination is intentionally NOT implemented here.
/// Instead, <see cref="IsPossiblyTruncated"/> is a heuristic (record count crossing a
/// configurable threshold) that callers MUST treat as "do not trust this as a complete
/// dataset" rather than silently accepting a partial fetch as a full sync.
/// </summary>
public record CloudFetchResult<T>(IReadOnlyList<T> Items, bool IsPossiblyTruncated, string? TruncationReason);
