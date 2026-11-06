namespace FortiGateDashboard.Core.Entities;

public enum CloudManagementStatus
{
    Unknown = 0,
    Online = 1,
    Offline = 2,
    Registered = 3,
    Deregistered = 4
}

public class Device
{
    public Guid Id { get; set; }

    /// <summary>Unique FortiGate serial number, e.g. FGT60F1234567890.</summary>
    public string SerialNumber { get; set; } = default!;

    public string Name { get; set; } = default!;

    /// <summary>FortiGate hostname from FortiCloud telemetry, if available.</summary>
    public string? Hostname { get; set; }

    public string Model { get; set; } = default!;

    public string FirmwareVersion { get; set; } = default!;

    public CloudManagementStatus CloudManagementStatus { get; set; }

    /// <summary>The FortiGate Cloud account/tenant this device belongs to (multi-account MSP support).</summary>
    public string AccountId { get; set; } = default!;

    public string? AccountName { get; set; }

    public DateTimeOffset? LastSeenAt { get; set; }

    /// <summary>FortiGate Cloud management tunnel state; null when telemetry has not reported the device.</summary>
    public bool? TunnelAlive { get; set; }

    public string? IpAddress { get; set; }

    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.UtcNow;

    public DateTimeOffset UpdatedAt { get; set; } = DateTimeOffset.UtcNow;

    public ICollection<Subscription> Subscriptions { get; set; } = new List<Subscription>();

    public ICollection<DevicePsirt> DevicePsirts { get; set; } = new List<DevicePsirt>();
}
