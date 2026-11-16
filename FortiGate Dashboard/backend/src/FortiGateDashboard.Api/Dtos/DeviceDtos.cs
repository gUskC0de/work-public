namespace FortiGateDashboard.Api.Dtos;

public record DeviceListItemDto(
    Guid Id,
    string Name,
    string SerialNumber,
    string Model,
    string FirmwareVersion,
    string CloudManagementStatus,
    string SubscriptionStatus,
    DateOnly? ExpiryDate,
    int CriticalCveCount,
    double HighestCvss,
    string? LatestPsirtUrl,
    /// <summary>
    /// Advisories linked to this device whose correlation could not be confidently evaluated
    /// (unparseable advisory or firmware string). Never implies safety — surfaced separately
    /// from <see cref="CriticalCveCount"/> so uncertainty is never silently folded into "clean".
    /// </summary>
    int UnableToEvaluateCount,
    bool? TunnelAlive,
    string? IpAddress,
    string? Hostname,
    bool? IcmpReachable,
    bool? SshPortOpen,
    bool? HttpsPortOpen,
    bool? Port9443Open,
    DateTimeOffset? ReachabilityCheckedAt,
    /// <summary>Highest effective risk ("Low"/"Medium"/"High") across CONFIRMED affected advisories; null when none.</summary>
    string? HighestRisk,
    IReadOnlyList<AdvisoryRiskDto> AffectedAdvisories);

/// <summary>Organisation-specific risk assessment for an advisory. Risk = Override ?? AutoRisk.</summary>
public record AdvisoryRiskDto(
    string PsirtId,
    string Title,
    string AdvisoryUrl,
    string Severity,
    double CvssScore,
    string Risk,
    string AutoRisk,
    string? OverrideRisk,
    string? Reason);

public record UpdateRiskAssessmentRequest(string? Risk);

public record DeviceDetailDto(
    Guid Id,
    string Name,
    string SerialNumber,
    string Model,
    string FirmwareVersion,
    string CloudManagementStatus,
    DateTimeOffset? LastSeenAt,
    bool? TunnelAlive,
    string? IpAddress,
    string? Hostname,
    bool? IcmpReachable,
    bool? SshPortOpen,
    bool? HttpsPortOpen,
    bool? Port9443Open,
    DateTimeOffset? ReachabilityCheckedAt,
    IReadOnlyList<SubscriptionDto> Subscriptions,
    IReadOnlyList<VulnerabilityDto> Vulnerabilities);

public record SubscriptionDto(
    string SubscriptionName,
    string SubscriptionType,
    DateOnly ExpiryDate,
    int DaysRemaining,
    string Status);

public record VulnerabilityDto(
    string CveId,
    string Severity,
    double CvssScore,
    string PsirtId,
    string AdvisoryUrl,
    /// <summary>"Affected", "UnableToEvaluate", "NotAffected" or "Unknown" — never omitted.</summary>
    string CorrelationStatus);

public record PagedResult<T>(IReadOnlyList<T> Items, int TotalCount, int TotalDeviceCount, int Page, int PageSize);

public record DeviceReachabilityDto(
    Guid Id,
    string SerialNumber,
    string? IpAddress,
    bool IcmpReachable,
    bool SshPortOpen,
    bool HttpsPortOpen,
    bool Port9443Open,
    DateTimeOffset CheckedAt);

public record ReachabilityProbeResultDto(
    int DevicesProbed,
    int DevicesSkippedWithoutIp,
    IReadOnlyList<DeviceReachabilityDto> Results);
