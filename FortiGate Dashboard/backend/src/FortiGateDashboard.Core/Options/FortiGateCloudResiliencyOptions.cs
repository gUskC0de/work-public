namespace FortiGateDashboard.Core.Options;

/// <summary>
/// Resiliency tuning for outbound FortiGate Cloud / PSIRT feed HTTP calls (retry, circuit
/// breaker, per-attempt timeout, bounded concurrency). Validated at startup.
/// </summary>
public class FortiGateCloudResiliencyOptions
{
    public const string SectionName = "FortiGateCloudResiliency";

    /// <summary>Number of retry attempts for transient failures (429/5xx/network/timeout).</summary>
    public int RetryCount { get; set; } = 3;

    /// <summary>Per-attempt request timeout, in seconds.</summary>
    public int TimeoutSeconds { get; set; } = 30;

    /// <summary>
    /// Upper bound on the ENTIRE operation (all retries + backoff waits combined), in seconds.
    /// Bounds the complete action independently of per-attempt timeouts, so a caller can never
    /// be blocked indefinitely by a long retry sequence even if every individual attempt is fast.
    /// </summary>
    public int TotalTimeoutSeconds { get; set; } = 120;

    /// <summary>
    /// Upper bound on any delay honored from an upstream `Retry-After` header, in seconds. A
    /// malicious or misconfigured upstream cannot force an excessively long wait.
    /// </summary>
    public int MaxRetryAfterSeconds { get; set; } = 30;

    /// <summary>Consecutive failures before the circuit breaker opens.</summary>
    public int CircuitBreakerFailureThreshold { get; set; } = 5;

    /// <summary>How long the circuit stays open before allowing a trial request, in seconds.</summary>
    public int CircuitBreakerDurationSeconds { get; set; } = 30;

    /// <summary>Maximum number of concurrent in-flight requests to FortiGate Cloud.</summary>
    public int MaxConcurrentRequests { get; set; } = 4;

    /// <summary>Additional requests allowed to queue once <see cref="MaxConcurrentRequests"/> is reached.</summary>
    public int MaxQueuedRequests { get; set; } = 8;

    /// <summary>
    /// If a single fetch returns at least this many records, the response is flagged as
    /// possibly truncated (see remarks on <c>IFortiGateCloudService</c> pagination uncertainty).
    /// </summary>
    public int TruncationWarningThreshold { get; set; } = 1000;
}
