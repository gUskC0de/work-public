namespace FortiGateDashboard.Core.Entities;

/// <summary>How a device/advisory correlation was determined; never implies "confirmed safe".</summary>
public enum PsirtCorrelationStatus
{
    /// <summary>
    /// No correlation logic has evaluated this row yet (e.g. a legacy row migrated before
    /// correlation-status tracking existed). Must never be treated as a confirmed vulnerability
    /// nor as confirmed safe — it means "not yet assessed by the current parser/matcher".
    /// </summary>
    Unknown = 0,

    /// <summary>Firmware version was confidently matched inside the advisory's affected range.</summary>
    Affected = 1,

    /// <summary>
    /// Firmware version was confidently confirmed OUTSIDE the advisory's affected range.
    /// Not currently persisted (no row is created for a confirmed-safe pairing), reserved for
    /// a future explicit "confirmed not affected" audit trail.
    /// </summary>
    NotAffected = 2,

    /// <summary>
    /// The advisory or firmware version could not be confidently parsed/compared. This is
    /// still recorded (not dropped) so the fleet is never presented as clean by omission.
    /// </summary>
    UnableToEvaluate = 3
}

/// <summary>Join entity linking a Device to a PsirtAdvisory that affects its current firmware.</summary>
public class DevicePsirt
{
    public Guid Id { get; set; }

    public Guid DeviceId { get; set; }

    public Device Device { get; set; } = default!;

    public Guid PsirtAdvisoryId { get; set; }

    public PsirtAdvisory PsirtAdvisory { get; set; } = default!;

    public DateTimeOffset DetectedAt { get; set; } = DateTimeOffset.UtcNow;

    /// <summary>Set when a subsequent sync confirms the device is no longer affected (Phase 5 lifecycle work).</summary>
    public bool Resolved { get; set; }

    public PsirtCorrelationStatus CorrelationStatus { get; set; } = PsirtCorrelationStatus.Unknown;
}
