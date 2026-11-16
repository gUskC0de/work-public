namespace FortiGateDashboard.Core.Models;

/// <summary>Outcome of attempting to extract structured data from a single PSIRT advisory.</summary>
public enum PsirtParseStatus
{
    /// <summary>
    /// No parser has evaluated this advisory yet (e.g. a legacy row migrated before parse
    /// tracking existed). Must never be treated as equivalent to a confirmed successful parse.
    /// </summary>
    Unknown = 0,

    /// <summary>CVSS, affected-version range and at least one CVE were all extracted.</summary>
    Parsed = 1,

    /// <summary>Some, but not all, of CVSS/affected-range/CVE data could be extracted.</summary>
    PartiallyParsed = 2,

    /// <summary>Nothing usable could be extracted from the advisory text.</summary>
    Unparseable = 3
}
