namespace FortiGateDashboard.Core.Models;

/// <summary>Raw PSIRT advisory record as returned by the Fortinet PSIRT feed.</summary>
public record PsirtRecord(
    string PsirtId,
    string Title,
    string AdvisoryUrl,
    string Severity,
    double CvssScore,
    DateOnly PublishedDate,
    string AffectedVersionRange,
    IReadOnlyList<CveRecord> Cves,
    PsirtParseStatus ParseStatus);

public record CveRecord(string CveId, string? Description, double CvssScore);
