namespace FortiGateDashboard.Core.Options;

/// <summary>
/// Strongly typed, startup-validated rate limiting configuration. Each policy maps to an
/// ASP.NET Core fixed-window rate limiter partitioned by authenticated user (falling back to
/// remote IP for unauthenticated/health traffic where the policy allows it).
/// </summary>
public class RateLimitingOptions
{
    public const string SectionName = "RateLimiting";

    public RateLimitPolicyOptions General { get; set; } = new() { PermitLimit = 120, WindowSeconds = 60, QueueLimit = 0 };

    public RateLimitPolicyOptions Sync { get; set; } = new() { PermitLimit = 1, WindowSeconds = 60, QueueLimit = 0 };

    public RateLimitPolicyOptions Export { get; set; } = new() { PermitLimit = 5, WindowSeconds = 60, QueueLimit = 0 };
}

public class RateLimitPolicyOptions
{
    /// <summary>Maximum number of requests allowed per window, per partition key.</summary>
    public int PermitLimit { get; set; }

    /// <summary>Fixed window duration, in seconds.</summary>
    public int WindowSeconds { get; set; }

    /// <summary>Number of requests allowed to queue once the limit is hit (0 = reject immediately).</summary>
    public int QueueLimit { get; set; }
}
