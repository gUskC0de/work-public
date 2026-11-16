using FortiGateDashboard.Core.Options;
using Microsoft.Extensions.Logging;
using Polly;
using Polly.Extensions.Http;
using Polly.Timeout;

namespace FortiGateDashboard.Infrastructure.FortiGateCloud;

/// <summary>
/// Builds the Polly v7 resilience pipeline used for all outbound FortiGate Cloud / PSIRT feed
/// HTTP calls. Composed (outer → inner, i.e. registration order via <c>AddPolicyHandler</c>) as:
///
/// <code>
/// TotalTimeout(TotalTimeoutSeconds)   // bounds the ENTIRE retry sequence
///   → Retry(429/5xx/network, honoring Retry-After capped at MaxRetryAfterSeconds, + jitter)
///     → CircuitBreaker(429/5xx)      // each retry attempt counts toward the breaker
///       → Bulkhead(MaxConcurrentRequests)   // bounds concurrency around the ACTUAL send only
///         → PerAttemptTimeout(TimeoutSeconds) // bounds a single attempt
/// </code>
///
/// Rationale for this ordering (see ServiceCollectionExtensions for exact registration order):
/// - Bulkhead sits INSIDE Retry/CircuitBreaker so a slot is held only during the actual network
///   call, not while waiting out a Retry-After/backoff delay between attempts — a slow/backing-off
///   retry does not starve other concurrent requests of bulkhead capacity.
/// - CircuitBreaker sits INSIDE Retry so each individual attempt counts toward the breaker, but
///   once the breaker is open, the resulting <see cref="Polly.CircuitBreaker.BrokenCircuitException"/>
///   is NOT matched by the retry policy's predicate (it only handles HTTP status codes/
///   <see cref="HttpRequestException"/>), so an open circuit fails fast instead of burning the
///   entire retry budget against a known-down dependency.
/// - PerAttemptTimeout is innermost so it bounds exactly one HTTP call; TotalTimeout is outermost
///   so the caller's overall wait is bounded even across many retries.
///
/// Retries 429/500/502/503/504/408/network failures. Never retries 400/401/403/404 — those
/// are permanent failures for this API contract as currently understood.
/// </summary>
public static class FortiGateResiliencePolicyFactory
{
    public static IAsyncPolicy<HttpResponseMessage> CreateRetryPolicy(FortiGateCloudResiliencyOptions options, ILogger logger) =>
        HttpPolicyExtensions
            .HandleTransientHttpError()
            .OrResult(response => (int)response.StatusCode == 429)
            .WaitAndRetryAsync(
                options.RetryCount,
                sleepDurationProvider: (attempt, outcome, _) => ComputeDelay(attempt, outcome?.Result, options.MaxRetryAfterSeconds),
                onRetryAsync: (outcome, delay, attempt, _) =>
                {
                    var statusCode = outcome.Result is not null ? (int?)outcome.Result.StatusCode : null;
                    logger.LogWarning(
                        "Retrying FortiGate Cloud request (attempt {Attempt}/{MaxAttempts}) after {DelayMs}ms; last status {StatusCode}",
                        attempt, options.RetryCount, delay.TotalMilliseconds, statusCode);
                    return Task.CompletedTask;
                });

    public static IAsyncPolicy<HttpResponseMessage> CreateCircuitBreakerPolicy(FortiGateCloudResiliencyOptions options, ILogger logger) =>
        HttpPolicyExtensions
            .HandleTransientHttpError()
            .OrResult(response => (int)response.StatusCode == 429)
            .CircuitBreakerAsync(
                options.CircuitBreakerFailureThreshold,
                TimeSpan.FromSeconds(options.CircuitBreakerDurationSeconds),
                onBreak: (outcome, breakDelay) => logger.LogError(
                    "FortiGate Cloud circuit breaker opened for {BreakSeconds}s after repeated failures (last status {StatusCode})",
                    breakDelay.TotalSeconds, outcome.Result is not null ? (int?)outcome.Result.StatusCode : null),
                onReset: () => logger.LogInformation("FortiGate Cloud circuit breaker reset"),
                onHalfOpen: () => logger.LogInformation("FortiGate Cloud circuit breaker half-open; testing next request"));

    /// <summary>Bounds a single HTTP attempt.</summary>
    public static IAsyncPolicy<HttpResponseMessage> CreateTimeoutPolicy(FortiGateCloudResiliencyOptions options) =>
        Policy.TimeoutAsync<HttpResponseMessage>(TimeSpan.FromSeconds(options.TimeoutSeconds), TimeoutStrategy.Optimistic);

    /// <summary>Bounds the entire retry sequence (all attempts + backoff waits combined).</summary>
    public static IAsyncPolicy<HttpResponseMessage> CreateTotalTimeoutPolicy(FortiGateCloudResiliencyOptions options) =>
        Policy.TimeoutAsync<HttpResponseMessage>(TimeSpan.FromSeconds(options.TotalTimeoutSeconds), TimeoutStrategy.Optimistic);

    public static IAsyncPolicy<HttpResponseMessage> CreateBulkheadPolicy(FortiGateCloudResiliencyOptions options) =>
        Policy.BulkheadAsync<HttpResponseMessage>(options.MaxConcurrentRequests, options.MaxQueuedRequests);

    /// <summary>
    /// Honors the Retry-After response header when present, capped at <paramref name="maxSeconds"/>
    /// so a malicious/misconfigured upstream cannot force an excessive wait. Otherwise uses
    /// exponential backoff with jitter, also capped at the same maximum.
    /// </summary>
    private static TimeSpan ComputeDelay(int attempt, HttpResponseMessage? response, int maxSeconds)
    {
        var max = TimeSpan.FromSeconds(maxSeconds);

        if (response?.Headers.RetryAfter is { } retryAfter)
        {
            if (retryAfter.Delta is { } delta)
            {
                return delta > max ? max : (delta < TimeSpan.Zero ? TimeSpan.Zero : delta);
            }

            if (retryAfter.Date is { } date)
            {
                var untilDate = date - DateTimeOffset.UtcNow;
                if (untilDate > TimeSpan.Zero)
                {
                    return untilDate > max ? max : untilDate;
                }
            }
        }

        var exponential = TimeSpan.FromSeconds(Math.Pow(2, attempt));
        var jitter = TimeSpan.FromMilliseconds(Random.Shared.Next(0, 500));
        var total = exponential + jitter;
        return total > max ? max : total;
    }
}
