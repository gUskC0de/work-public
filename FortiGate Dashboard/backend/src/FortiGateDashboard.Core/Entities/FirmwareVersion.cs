namespace FortiGateDashboard.Core.Entities;

public class FirmwareVersion
{
    public Guid Id { get; set; }

    /// <summary>e.g. 7.4.4.</summary>
    public string Version { get; set; } = default!;

    public DateOnly? ReleaseDate { get; set; }

    public bool IsEndOfSupport { get; set; }

    public bool IsLatestRecommended { get; set; }
}
