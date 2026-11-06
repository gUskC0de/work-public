using System.ServiceModel.Syndication;
using System.Globalization;
using System.Text.RegularExpressions;
using System.Xml;
using FortiGateDashboard.Core.Interfaces;
using FortiGateDashboard.Core.Models;
using FortiGateDashboard.Core.Options;
using FortiGateDashboard.Infrastructure.Observability;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace FortiGateDashboard.Infrastructure.Psirt;

/// <summary>
/// Retrieves Fortinet PSIRT advisories from the public FortiGuard PSIRT RSS feed and evaluates
/// firmware version affected-range matching used to flag vulnerable devices.
/// </summary>
/// <remarks>
/// Fail-safe design: every extraction step records whether it actually succeeded. A firmware
/// version or affected-range string that cannot be confidently parsed must surface as
/// <see cref="FirmwareAffectedStatus.UnableToEvaluate"/>, never as "not affected" — a parsing
/// regression must never look identical to "this fleet has no vulnerabilities".
/// </remarks>
public partial class PsirtService : IPsirtService
{
    private static readonly Uri DefaultAdvisoryUri = new("https://www.fortiguard.com/psirt");

    private readonly HttpClient _httpClient;
    private readonly PsirtOptions _options;
    private readonly ILogger<PsirtService> _logger;

    public PsirtService(HttpClient httpClient, IOptions<PsirtOptions> options, ILogger<PsirtService> logger)
    {
        _httpClient = httpClient;
        _options = options.Value;
        _logger = logger;
    }

    public async Task<IReadOnlyList<PsirtRecord>> GetAdvisoriesAsync(CancellationToken cancellationToken = default)
    {
        var records = new List<PsirtRecord>();

        try
        {
            await using var stream = await _httpClient.GetStreamAsync(_options.FeedUrl, cancellationToken);
            using var xmlReader = XmlReader.Create(stream);
            var feed = SyndicationFeed.Load(xmlReader);

            foreach (var item in feed.Items)
            {
                cancellationToken.ThrowIfCancellationRequested();

                var psirtId = ExtractPsirtId(item.Links.FirstOrDefault()?.Uri?.ToString())
                    ?? ExtractPsirtId(item.Id)
                    ?? ExtractPsirtId(item.Title.Text)
                    ?? item.Id;
                var summary = item.Summary?.Text ?? string.Empty;
                var cvss = ExtractCvss(summary);
                var affectedRange = ExtractAffectedRange(summary);
                var cves = ExtractCves(summary);

                var advisoryUrl = ResolveSafeAdvisoryUrl(item, psirtId);
                var advisoryDetails = await GetAdvisoryDetailsAsync(advisoryUrl, cancellationToken);
                psirtId = advisoryDetails.PsirtId ?? psirtId;
                cvss = advisoryDetails.CvssScore ?? cvss;
                var severity = advisoryDetails.Severity ?? SeverityFromCvss(cvss);
                // Prefer detailed advisory's affected range if RSS summary didn't have it
                if (string.IsNullOrWhiteSpace(affectedRange) && !string.IsNullOrWhiteSpace(advisoryDetails.AffectedVersionRange))
                {
                    affectedRange = advisoryDetails.AffectedVersionRange;
                }

                // Skip advisories not relevant to FortiGate/FortiOS
                if (!IsFortiGateRelevant(item.Title.Text, summary, advisoryDetails.RawContent))
                {
                    _logger.LogDebug("Skipping PSIRT advisory {PsirtId} '{Title}' - not relevant to FortiGate/FortiOS", psirtId, item.Title.Text);
                    continue;
                }

                // Additional validation: affected version range must contain valid FortiGate version patterns
                // This prevents non-FortiGate products from slipping through if filtering missed them
                if (!string.IsNullOrWhiteSpace(affectedRange) && !ContainsValidFortiGateVersionPattern(affectedRange))
                {
                    _logger.LogDebug("Skipping PSIRT advisory {PsirtId} '{Title}' - affected version range '{Range}' does not match FortiGate version format", psirtId, item.Title.Text, affectedRange);
                    continue;
                }

                var parseStatus = DetermineParseStatus(cvss, affectedRange, cves);
                RecordParseMetric(parseStatus);
                if (parseStatus != PsirtParseStatus.Parsed)
                {
                    _logger.LogWarning(
                        "PSIRT advisory {PsirtId} parsed as {ParseStatus} (cvssFound={CvssFound}, rangeFound={RangeFound}, cveCount={CveCount})",
                        psirtId, parseStatus, cvss > 0, !string.IsNullOrWhiteSpace(affectedRange), cves.Count);
                }

                records.Add(new PsirtRecord(
                    PsirtId: psirtId,
                    Title: item.Title.Text,
                    AdvisoryUrl: advisoryUrl,
                    Severity: severity,
                    CvssScore: cvss,
                    PublishedDate: DateOnly.FromDateTime(item.PublishDate.UtcDateTime == default ? DateTime.UtcNow : item.PublishDate.UtcDateTime),
                    AffectedVersionRange: affectedRange,
                    Cves: cves,
                    ParseStatus: parseStatus));
            }
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception ex)
        {
            // Deliberately do not log ex.Message's full feed content — only the exception type/feed URL.
            _logger.LogError(ex, "Failed to fetch/parse PSIRT feed from {FeedUrl}", _options.FeedUrl);
        }

        return records;
    }

    public FirmwareAffectedStatus EvaluateAffectedStatus(string firmwareVersion, string affectedVersionRange, PsirtParseStatus advisoryParseStatus)
    {
        if (advisoryParseStatus == PsirtParseStatus.Unparseable)
        {
            return FirmwareAffectedStatus.UnableToEvaluate;
        }

        if (string.IsNullOrWhiteSpace(affectedVersionRange) || string.IsNullOrWhiteSpace(firmwareVersion))
        {
            return FirmwareAffectedStatus.UnableToEvaluate;
        }

        if (!TryParseVersion(firmwareVersion, out var version))
        {
            return FirmwareAffectedStatus.UnableToEvaluate;
        }

        // Check if the input contains multiple comma-separated patterns (e.g., "7.6.0 through 7.6.5, 7.4.0 through 7.4.10")
        // For each pattern, evaluate independently and return Affected if ANY pattern matches
        if (affectedVersionRange.Contains(','))
        {
            var allUnevaluable = true;
            var parts = affectedVersionRange.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
            
            foreach (var part in parts)
            {
                var partResult = EvaluateSinglePattern(version, part);
                if (partResult == FirmwareAffectedStatus.Affected)
                {
                    return FirmwareAffectedStatus.Affected;
                }
                if (partResult != FirmwareAffectedStatus.UnableToEvaluate)
                {
                    allUnevaluable = false;
                }
            }

            // Return NotAffected if at least one part was evaluated successfully and none matched
            return allUnevaluable ? FirmwareAffectedStatus.UnableToEvaluate : FirmwareAffectedStatus.NotAffected;
        }

        return EvaluateSinglePattern(version, affectedVersionRange);
    }

    private FirmwareAffectedStatus EvaluateSinglePattern(Version version, string pattern)
    {
        // "7.2.0 through 7.2.7" / "7.2.0 to 7.2.7" / "7.2.0 - 7.2.7"
        var rangeMatch = RangeRegex().Match(pattern);
        if (rangeMatch.Success)
        {
            if (TryParseVersion(rangeMatch.Groups[1].Value, out var low) && TryParseVersion(rangeMatch.Groups[2].Value, out var high))
            {
                return version >= low && version <= high ? FirmwareAffectedStatus.Affected : FirmwareAffectedStatus.NotAffected;
            }

            return FirmwareAffectedStatus.UnableToEvaluate;
        }

        // "before 7.4.5"
        var beforeMatch = BeforeRegex().Match(pattern);
        if (beforeMatch.Success)
        {
            if (TryParseVersion(beforeMatch.Groups[1].Value, out var upperBound))
            {
                return version < upperBound ? FirmwareAffectedStatus.Affected : FirmwareAffectedStatus.NotAffected;
            }

            return FirmwareAffectedStatus.UnableToEvaluate;
        }

        // "7.0 all versions" — affects the entire major.minor branch.
        var allVersionsMatch = AllVersionsRegex().Match(pattern);
        if (allVersionsMatch.Success)
        {
            if (TryParseVersion(allVersionsMatch.Groups[1].Value, out var branch))
            {
                return version.Major == branch.Major && version.Minor == branch.Minor
                    ? FirmwareAffectedStatus.Affected
                    : FirmwareAffectedStatus.NotAffected;
            }

            return FirmwareAffectedStatus.UnableToEvaluate;
        }

        // Exact single version (when not comma-separated, e.g., just "7.4.0")
        if (TryParseVersion(pattern, out var exactVersion))
        {
            return VersionMatches(version, exactVersion) ? FirmwareAffectedStatus.Affected : FirmwareAffectedStatus.NotAffected;
        }

        // Format not recognized by any known pattern — do not guess.
        return FirmwareAffectedStatus.UnableToEvaluate;
    }

    /// <summary>
    /// Compares major/minor/patch, ignoring a missing patch component on the candidate token
    /// (so "7.0" as an exact-match list entry still matches a device reporting "7.0.5").
    /// </summary>
    private static bool VersionMatches(Version device, Version candidate)
    {
        if (device.Major != candidate.Major || device.Minor != candidate.Minor)
        {
            return false;
        }

        return candidate.Build < 0 || device.Build == candidate.Build;
    }

    private string ResolveSafeAdvisoryUrl(SyndicationItem item, string psirtId)
    {
        var rawLink = item.Links.FirstOrDefault()?.Uri;
        if (rawLink is not null && IsSafeAdvisoryUri(rawLink))
        {
            return rawLink.ToString();
        }

        if (rawLink is not null)
        {
            PsirtMetrics.InvalidAdvisoryUrls.Add(1);
            _logger.LogWarning("PSIRT advisory {PsirtId} had an unsafe/invalid advisory URL scheme; falling back to the default PSIRT portal link", psirtId);
        }

        return DefaultAdvisoryUri.ToString();
    }

    private async Task<AdvisoryDetails> GetAdvisoryDetailsAsync(string advisoryUrl, CancellationToken cancellationToken)
    {
        try
        {
            var page = await _httpClient.GetStringAsync(advisoryUrl, cancellationToken);
            var cvss = ExtractCvss(page);
            var affectedRange = ExtractAffectedRangeFromPage(page);
            return new AdvisoryDetails(
                ExtractPsirtId(page),
                cvss > 0 ? cvss : null,
                ExtractSeverity(page),
                !string.IsNullOrWhiteSpace(affectedRange) ? affectedRange : null,
                page);
        }
        catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException)
        {
            _logger.LogWarning(ex, "Failed to retrieve PSIRT advisory details from {AdvisoryUrl}", advisoryUrl);
            return new AdvisoryDetails(null, null, null, null, null);
        }
    }

    /// <summary>Only absolute HTTPS URIs are ever surfaced to the frontend as clickable advisory links.</summary>
    private static bool IsSafeAdvisoryUri(Uri uri) =>
        uri.IsAbsoluteUri && uri.Scheme.Equals(Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase);

    private static PsirtParseStatus DetermineParseStatus(double cvss, string affectedRange, IReadOnlyList<CveRecord> cves)
    {
        var signals = 0;
        if (cvss > 0) signals++;
        if (!string.IsNullOrWhiteSpace(affectedRange)) signals++;
        if (cves.Count > 0) signals++;

        return signals switch
        {
            3 => PsirtParseStatus.Parsed,
            0 => PsirtParseStatus.Unparseable,
            _ => PsirtParseStatus.PartiallyParsed
        };
    }

    private static void RecordParseMetric(PsirtParseStatus status)
    {
        switch (status)
        {
            case PsirtParseStatus.Parsed:
                PsirtMetrics.AdvisoriesParsed.Add(1);
                break;
            case PsirtParseStatus.PartiallyParsed:
                PsirtMetrics.AdvisoriesPartiallyParsed.Add(1);
                break;
            default:
                PsirtMetrics.AdvisoriesUnparseable.Add(1);
                break;
        }
    }

    private static bool TryParseVersion(string raw, out Version version)
    {
        var cleaned = VersionCleanupRegex().Match(raw);
        return Version.TryParse(cleaned.Success ? cleaned.Value : raw, out version!);
    }

    private static string? ExtractPsirtId(string? text)
    {
        if (string.IsNullOrWhiteSpace(text))
        {
            return null;
        }

        var match = PsirtIdRegex().Match(text);
        return match.Success ? match.Value : null;
    }

    private static double ExtractCvss(string text)
    {
        var match = CvssRegex().Match(NormalizeHtml(text));
        var value = match.Groups[1].Success ? match.Groups[1].Value : match.Groups[2].Value;
        return double.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out var score) ? score : 0d;
    }

    private static string? ExtractSeverity(string text)
    {
        var match = SeverityRegex().Match(NormalizeHtml(text));
        return match.Success ? match.Groups[1].Value.Trim() : null;
    }

    private static string NormalizeHtml(string text) =>
        WhitespaceRegex().Replace(HtmlTagRegex().Replace(System.Net.WebUtility.HtmlDecode(text), " "), " ").Trim();

    private static string SeverityFromCvss(double cvss) => cvss switch
    {
        >= 9.0 => "Critical",
        >= 7.0 => "High",
        >= 4.0 => "Medium",
        _ => "Low"
    };

    private static string ExtractAffectedRange(string text)
    {
        // Try main "Affected Versions:" pattern first
        var match = AffectedRegex().Match(text);
        if (match.Success)
        {
            var captured = match.Groups[1].Value.Trim();
            if (!string.IsNullOrWhiteSpace(captured) && captured.Length < 200)
            {
                return captured;
            }
        }

        // Fallback: look for patterns like "7.0.0 - 7.4.5", "before 7.4.6", etc.
        // This catches cases where the advisory just lists versions inline without explicit "Affected Versions:" label
        var versionMatch = Regex.Match(text, @"(?:FortiOS|FortiGate|version).*?([0-9]+\.[0-9]+\.[0-9]+ (?:to|-|through) [0-9]+\.[0-9]+\.[0-9]+|(?:before|earlier than|prior to) [0-9]+\.[0-9]+\.[0-9]+|[0-9]+\.[0-9]+ all versions)", RegexOptions.IgnoreCase | RegexOptions.Singleline);
        if (versionMatch.Success)
        {
            return versionMatch.Groups[1].Value.Trim();
        }

        return string.Empty;
    }

    private static string ExtractAffectedRangeFromPage(string text)
    {
        // Normalize HTML and try multiple patterns
        var normalized = NormalizeHtml(text);
        
        // Try: "Affected Versions: 7.0.0 - 7.4.5" (with multiline support)
        var match = AffectedPageRegex().Match(normalized);
        if (match.Success)
        {
            var captured = match.Groups[1].Value.Trim();
            // Remove excessive punctuation/next section but preserve the version range
            var endMarks = new[] { "Fixed version", "Resolution", "Impact", "Solution" };
            foreach (var mark in endMarks)
            {
                var idx = captured.IndexOf(mark, StringComparison.OrdinalIgnoreCase);
                if (idx > 0)
                {
                    captured = captured.Substring(0, idx).Trim();
                }
            }
            
            if (!string.IsNullOrWhiteSpace(captured) && captured.Length < 200)
            {
                return captured;
            }
        }

        // Fallback: search for version patterns in tables or structured content
        // Look for patterns: "7.0.0 - 7.4.5" or "before 7.4.6" or "all versions"
        var tablePattern = Regex.Match(normalized, @"(?:FortiOS|FortiGate).*?([0-9]+\.[0-9]+\.[0-9]+ (?:to|-|through|–) [0-9]+\.[0-9]+\.[0-9]+|(?:before|earlier than|prior to|< |up to) [0-9]+\.[0-9]+\.[0-9]+|[0-9]+\.[0-9]+ all versions)", RegexOptions.IgnoreCase | RegexOptions.Singleline);
        if (tablePattern.Success)
        {
            var captured = tablePattern.Groups[1].Value.Trim();
            if (!string.IsNullOrWhiteSpace(captured) && captured.Length < 200)
            {
                return captured;
            }
        }

        return string.Empty;
    }

    private static List<CveRecord> ExtractCves(string text)
    {
        return CveRegex().Matches(text)
            .Select(m => new CveRecord(m.Value, null, 0))
            .DistinctBy(c => c.CveId)
            .ToList();
    }

    private sealed record AdvisoryDetails(string? PsirtId, double? CvssScore, string? Severity, string? AffectedVersionRange = null, string? RawContent = null);

    /// <summary>
    /// Determines if an advisory is relevant to FortiGate/FortiOS products.
    /// Filters out advisories for other products (FortiPAM, FortiProxy, FortiMail, Linux Kernel, OpenSSH, etc.)
    /// by checking both the title AND the affected version range text for product identifiers.
    /// </summary>
    private static bool IsFortiGateRelevant(string title, string summary, string? rawContent)
    {
        var titleLower = title?.ToLowerInvariant() ?? string.Empty;
        var summaryLower = summary?.ToLowerInvariant() ?? string.Empty;
        var contentLower = rawContent?.ToLowerInvariant() ?? string.Empty;

        // STRICT: Must explicitly mention FortiGate or FortiOS in title or summary
        // (Not just anywhere in page content, which could match unrelated products)
        var hasFortiGateInTitleOrSummary = 
            titleLower.Contains("fortigate") || titleLower.Contains("fortios") ||
            summaryLower.Contains("fortigate") || summaryLower.Contains("fortios");

        if (!hasFortiGateInTitleOrSummary)
        {
            return false;
        }

        // Exclude known non-FortiGate Fortinet products
        // (in case title is misleading like "Critical Issue Affecting Fortinet Products")
        var isNonFortiGateProduct = 
            titleLower.Contains("openssh") ||
            titleLower.Contains("openssl") ||
            titleLower.Contains("apache") ||
            titleLower.Contains("http/2") ||
            titleLower.Contains("fortisandbox") ||
            titleLower.Contains("fortianalyzer") ||
            titleLower.Contains("fortimanager") ||
            titleLower.Contains("fortiproxy") ||
            titleLower.Contains("fortimail") ||
            titleLower.Contains("fortiedr") ||
            titleLower.Contains("forticlient") ||
            titleLower.Contains("fortipam") ||
            titleLower.Contains("fortiweb") ||
            titleLower.Contains("forticwp") ||
            titleLower.Contains("forticonnect") ||
            titleLower.Contains("fortiextender") ||
            titleLower.Contains("fortitoken") ||
            titleLower.Contains("fortisiem") ||
            titleLower.Contains("forticnapp") ||
            titleLower.Contains("fortidevicemanager") ||
            summaryLower.Contains("openssh") ||
            summaryLower.Contains("openssl") ||
            summaryLower.Contains("apache") ||
            summaryLower.Contains("fortisandbox") ||
            summaryLower.Contains("fortianalyzer") ||
            summaryLower.Contains("fortimanager") ||
            summaryLower.Contains("fortiproxy") ||
            summaryLower.Contains("fortimail") ||
            summaryLower.Contains("fortiedr") ||
            summaryLower.Contains("forticlient") ||
            summaryLower.Contains("fortipam") ||
            summaryLower.Contains("fortiweb") ||
            summaryLower.Contains("forticwp") ||
            summaryLower.Contains("forticonnect") ||
            summaryLower.Contains("fortiextender") ||
            summaryLower.Contains("fortitoken") ||
            summaryLower.Contains("fortisiem") ||
            summaryLower.Contains("forticnapp") ||
            summaryLower.Contains("fortidevicemanager") ||
            contentLower.Contains("fortisandbox") ||     // Malware analysis/detonation
            contentLower.Contains("fortianalyzer") ||    // Log aggregation/analytics
            contentLower.Contains("fortimanager") ||     // Device management/orchestration
            contentLower.Contains("fortiproxy") ||       // HTTP proxy/content filter
            contentLower.Contains("fortimail") ||        // Email security gateway
            contentLower.Contains("fortiedr") ||         // Endpoint Detection & Response
            contentLower.Contains("forticlient") ||      // Endpoint client/VPN
            contentLower.Contains("fortipam") ||         // Privileged Access Management
            contentLower.Contains("fortiweb") ||         // Web Application Firewall
            contentLower.Contains("forticwp") ||         // Cloud Web Protection
            contentLower.Contains("forticonnect") ||     // Zero Trust Network Access
            contentLower.Contains("fortiextender") ||    // Network edge connectivity
            contentLower.Contains("fortitoken") ||       // Hardware token/2FA
            contentLower.Contains("fortisiem") ||        // FortiSIEM
            contentLower.Contains("monitorsight") ||     // FortiMonitorOnSight
            contentLower.Contains("authenticator") ||    // FortiAuthenticator
            contentLower.Contains("openssh") ||
            contentLower.Contains("openssl") ||
            contentLower.Contains("apache") ||
            contentLower.Contains("linux kernel") ||
            contentLower.Contains("kernel driver") ||
            contentLower.Contains("kernel module") ||
            contentLower.Contains("chrome extension");

        return !isNonFortiGateProduct;
    }

    /// <summary>
    /// Validates that an affected version range string contains FortiGate version patterns.
    /// FortiGate uses X.Y.Z versioning (e.g., 7.4.0, 6.2.5). This prevents non-FortiGate 
    /// products with incompatible version schemes from matching FortiGate devices.
    /// </summary>
    /// <remarks>
    /// Valid patterns: "7.4.0 through 7.4.5", "before 7.0.0", "7.2.5", "all versions" etc.
    /// Invalid: "2.1" (OpenSSH), "2.4.x" (Apache), "5.0.2" (FortiSandbox), "8.0.3" (FortiAuthenticator)
    /// FortiGate valid major versions: 4.x, 5.x, 6.x, 7.x, 8.x (rare future), with historical 3.x
    /// OpenSSH/Apache are in 2.x range, FortiSandbox/Authenticator/others use 5.0, 8.0, etc. which
    /// are never FortiGate versions since FortiGate follows different versioning (major.minor.patch).
    /// </remarks>
    private static bool ContainsValidFortiGateVersionPattern(string affectedVersionRange)
    {
        if (string.IsNullOrWhiteSpace(affectedVersionRange))
        {
            return false;
        }

        // FortiGate major versions: 3.x (legacy), 4.x, 5.x, 6.x, 7.x, 8.x (future)
        // Reject obvious non-FortiGate patterns: 2.x (OpenSSH/Apache), 9.x+ (unlikely), etc.
        var hasValidMajorVersion = Regex.IsMatch(
            affectedVersionRange,
            @"[3-8]\.[0-9]+(?:\.[0-9]+)?", // e.g., 7.4, 7.4.0, 6.2.11, 5.0.0
            RegexOptions.IgnoreCase | RegexOptions.Singleline);

        if (!hasValidMajorVersion)
        {
            return false;
        }

        // Additional check: reject "all versions" without any specific version reference
        // (these are typically non-FortiGate products like FortiSandbox PaaS)
        var hasAnyVersionNumber = Regex.IsMatch(affectedVersionRange, @"[0-9]\.[0-9]");
        if (!hasAnyVersionNumber && affectedVersionRange.Contains("all versions"))
        {
            return false;
        }

        return true;
    }

    [GeneratedRegex(@"FG-IR-\d{2}-\d{3,4}")]
    private static partial Regex PsirtIdRegex();

    [GeneratedRegex(@"CVSSv3\s*Score:?\s*([\d.]+)|CVSS Score:?\s*([\d.]+)", RegexOptions.IgnoreCase)]
    private static partial Regex CvssRegex();

    [GeneratedRegex(@"Severity\s*:?[\s|]+(Critical|High|Medium|Low)", RegexOptions.IgnoreCase)]
    private static partial Regex SeverityRegex();

    [GeneratedRegex(@"<[^>]+>")]
    private static partial Regex HtmlTagRegex();

    [GeneratedRegex(@"\s+")]
    private static partial Regex WhitespaceRegex();

    [GeneratedRegex(@"CVE-\d{4}-\d{4,7}")]
    private static partial Regex CveRegex();

    [GeneratedRegex(@"Affected\s+[Vv]ersions?:?\s*(.+?)(?:[,.]?\s*(?:Fixed|Resolution|Impact|Solution)|$)", RegexOptions.Singleline)]
    private static partial Regex AffectedRegex();

    [GeneratedRegex(@"Affected\s+[Vv]ersions?:?\s*(.+?)(?=Fixed|Resolution|Impact|Solution|$)", RegexOptions.Singleline | RegexOptions.IgnoreCase)]
    private static partial Regex AffectedPageRegex();

    [GeneratedRegex(@"([\d]+\.[\d]+(?:\.[\d]+)?)\s*(?:through|to|-)\s*([\d]+\.[\d]+(?:\.[\d]+)?)")]
    private static partial Regex RangeRegex();

    [GeneratedRegex(@"before\s+([\d]+\.[\d]+(?:\.[\d]+)?)", RegexOptions.IgnoreCase)]
    private static partial Regex BeforeRegex();

    [GeneratedRegex(@"([\d]+\.[\d]+(?:\.[\d]+)?)\s+all\s+versions", RegexOptions.IgnoreCase)]
    private static partial Regex AllVersionsRegex();

    [GeneratedRegex(@"\d+\.\d+(\.\d+)?")]
    private static partial Regex VersionCleanupRegex();
}
