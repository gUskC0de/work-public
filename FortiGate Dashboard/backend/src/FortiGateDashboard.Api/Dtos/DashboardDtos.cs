namespace FortiGateDashboard.Api.Dtos;

public record DashboardSummaryDto(
    int TotalDevices,
    int RegisteredDevices,
    int SubscriptionsExpiring30Days,
    int SubscriptionsExpiring90Days,
    /// <summary>Devices with at least one CONFIRMED (Affected) critical PSIRT correlation only.</summary>
    int DevicesWithCriticalPsirts,
    int OldFirmwareDevices,
    /// <summary>
    /// Devices with at least one PSIRT correlation that could not be confidently evaluated.
    /// Tracked separately from <see cref="DevicesWithCriticalPsirts"/> so uncertain results are
    /// never silently folded into either the "confirmed vulnerable" or "clean" counts.
    /// </summary>
    int DevicesWithUnresolvedPsirtEvaluations);

public record PsirtAdvisoryDto(
    string PsirtId,
    string Title,
    string AdvisoryUrl,
    string Severity,
    double CvssScore,
    DateOnly PublishedDate,
    string AffectedVersionRange,
    int AffectedDeviceCount,
    /// <summary>"Parsed", "PartiallyParsed", "Unparseable" or "Unknown" (legacy/unassessed).</summary>
    string ParseStatus);

public record ExpiringSubscriptionDto(
    string DeviceName,
    string SerialNumber,
    string SubscriptionName,
    string SubscriptionType,
    DateOnly ExpiryDate,
    int DaysRemaining,
    string Status);

public record CloudConnectionStatusDto(
    bool CredentialsConfigured,
    IReadOnlyList<string> MissingSettings,
    IReadOnlyList<SyncStageStatusDto> Stages);

public record SyncStageStatusDto(
    string Name,
    string? Status,
    DateTimeOffset? LastStartedAt,
    DateTimeOffset? LastCompletedAt,
    int? RecordsProcessed);
