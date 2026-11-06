namespace FortiGateDashboard.Core.Entities;

using FortiGateDashboard.Core.Models;

public enum PsirtSeverity
{
    Low = 0,
    Medium = 1,
    High = 2,
    Critical = 3
}

public class PsirtAdvisory
{
    public Guid Id { get; set; }

    /// <summary>Fortinet PSIRT advisory identifier, e.g. FG-IR-24-001.</summary>
    public string PsirtId { get; set; } = default!;

    public string Title { get; set; } = default!;

    public string AdvisoryUrl { get; set; } = default!;

    public PsirtSeverity Severity { get; set; }

    public double CvssScore { get; set; }

    public DateOnly PublishedDate { get; set; }

    /// <summary>Affected firmware version ranges, e.g. "FortiOS 7.0.0 - 7.0.12".</summary>
    public string AffectedVersionRange { get; set; } = default!;

    /// <summary>How much structured data could be confidently extracted from the raw advisory text.</summary>
    public PsirtParseStatus ParseStatus { get; set; } = PsirtParseStatus.Unknown;

    public ICollection<Cve> Cves { get; set; } = new List<Cve>();

    public ICollection<DevicePsirt> DevicePsirts { get; set; } = new List<DevicePsirt>();
}
