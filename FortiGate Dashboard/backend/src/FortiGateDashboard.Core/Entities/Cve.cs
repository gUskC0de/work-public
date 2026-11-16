namespace FortiGateDashboard.Core.Entities;

public class Cve
{
    public Guid Id { get; set; }

    /// <summary>e.g. CVE-2024-12345.</summary>
    public string CveId { get; set; } = default!;

    public string? Description { get; set; }

    public double CvssScore { get; set; }

    public Guid PsirtAdvisoryId { get; set; }

    public PsirtAdvisory PsirtAdvisory { get; set; } = default!;
}
