namespace FortiGateDashboard.Core.Entities;

public enum SubscriptionStatus
{
    Healthy = 0,
    Warning = 1,
    Critical = 2,
    Expired = 3
}

public class Subscription
{
    public Guid Id { get; set; }

    public Guid DeviceId { get; set; }

    public Device Device { get; set; } = default!;

    public string SubscriptionName { get; set; } = default!;

    public string SubscriptionType { get; set; } = default!;

    public DateOnly ExpiryDate { get; set; }

    /// <summary>Computed at sync/query time: (ExpiryDate - today).</summary>
    public int DaysRemaining { get; set; }

    public SubscriptionStatus Status { get; set; }

    public DateTimeOffset UpdatedAt { get; set; } = DateTimeOffset.UtcNow;

    public static SubscriptionStatus CalculateStatus(int daysRemaining) => daysRemaining switch
    {
        < 0 => SubscriptionStatus.Expired,
        < 30 => SubscriptionStatus.Critical,
        < 90 => SubscriptionStatus.Warning,
        _ => SubscriptionStatus.Healthy
    };
}
