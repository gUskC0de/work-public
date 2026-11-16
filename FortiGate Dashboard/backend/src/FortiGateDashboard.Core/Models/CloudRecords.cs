namespace FortiGateDashboard.Core.Models;

/// <summary>Raw device inventory record as returned by the FortiGate Cloud API.</summary>
public record CloudDeviceRecord(
    string SerialNumber,
    string Name,
    string Model,
    string FirmwareVersion,
    string AccountId,
    string? AccountName,
    bool IsOnline,
    bool IsRegistered,
    DateTimeOffset? LastSeenAt,
    bool? TunnelAlive = null,
    string? IpAddress = null,
    string? Hostname = null);

/// <summary>Raw subscription record as returned by the FortiGate Cloud API.</summary>
public record CloudSubscriptionRecord(
    string DeviceSerialNumber,
    string SubscriptionName,
    string SubscriptionType,
    DateOnly ExpiryDate);
