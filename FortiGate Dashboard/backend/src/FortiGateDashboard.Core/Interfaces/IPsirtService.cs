namespace FortiGateDashboard.Core.Interfaces;

using FortiGateDashboard.Core.Models;

/// <summary>Abstraction over the Fortinet PSIRT advisory feed / API.</summary>
public interface IPsirtService
{
    /// <summary>Fetches all known PSIRT advisories (with associated CVEs).</summary>
    Task<IReadOnlyList<PsirtRecord>> GetAdvisoriesAsync(CancellationToken cancellationToken = default);

    /// <summary>
    /// Evaluates whether a firmware version is affected by the given advisory range. Returns
    /// <see cref="FirmwareAffectedStatus.UnableToEvaluate"/> — never a false "not affected" —
    /// whenever the firmware version or the affected-range text cannot be confidently parsed.
    /// </summary>
    FirmwareAffectedStatus EvaluateAffectedStatus(string firmwareVersion, string affectedVersionRange, PsirtParseStatus advisoryParseStatus);

    /// <summary>
    /// Fetches a stored advisory's page and classifies its risk. Used to backfill advisories that
    /// have dropped out of the RSS feed. Returns null if the page could not be retrieved.
    /// </summary>
    Task<(PsirtRiskLevel Risk, string Reason)?> AssessRiskAsync(string title, string advisoryUrl, CancellationToken cancellationToken = default);
}
