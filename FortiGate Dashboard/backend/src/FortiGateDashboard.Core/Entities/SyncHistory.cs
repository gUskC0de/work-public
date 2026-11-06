namespace FortiGateDashboard.Core.Entities;

public enum SyncType
{
    DeviceInventory = 0,
    SubscriptionInfo = 1,
    PsirtInfo = 2
}

public enum SyncStatus
{
    Running = 0,
    Succeeded = 1,
    Failed = 2,
    PartiallySucceeded = 3
}

public class SyncHistory
{
    public Guid Id { get; set; }

    public SyncType SyncType { get; set; }

    public SyncStatus Status { get; set; }

    public DateTimeOffset StartedAt { get; set; } = DateTimeOffset.UtcNow;

    public DateTimeOffset? CompletedAt { get; set; }

    public int RecordsProcessed { get; set; }

    public int RecordsFailed { get; set; }

    public string? ErrorMessage { get; set; }
}
