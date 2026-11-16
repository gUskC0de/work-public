namespace FortiGateDashboard.Core.Models;

/// <summary>
/// Tri-state result of evaluating whether a firmware version is affected by a PSIRT advisory.
/// <see cref="UnableToEvaluate"/> must never be treated as "not affected" by callers — it
/// exists specifically so a parsing failure cannot present as a false "all clear".
/// </summary>
public enum FirmwareAffectedStatus
{
    Affected = 0,
    NotAffected = 1,
    UnableToEvaluate = 2
}
