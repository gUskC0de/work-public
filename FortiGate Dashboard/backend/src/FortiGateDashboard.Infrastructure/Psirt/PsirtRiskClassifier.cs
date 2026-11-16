using System.Text.RegularExpressions;
using FortiGateDashboard.Core.Models;

namespace FortiGateDashboard.Infrastructure.Psirt;

/// <summary>
/// Classifies a FortiOS advisory against the baseline that no firewall management access is
/// exposed to the internet and all management access is restricted to specific source IPs.
/// </summary>
/// <remarks>
/// Order matters: data-plane/exposed-service indicators win over management-plane ones, because
/// e.g. the SSL-VPN web portal is served by the GUI component. Anything unclear defaults to Medium.
/// </remarks>
public static partial class PsirtRiskClassifier
{
    private static readonly string[] ExposedServiceKeywords =
    [
        "ssl-vpn", "ssl vpn", "sslvpn", "sslvpnd", "ipsec", "ike", "ikev1", "ikev2", "iked",
        "captive portal", "web proxy", "explicit proxy", "transparent proxy",
        "dns", "dhcp", "ztna", "agentless vpn", "web portal",
        "traffic through", "packets through", "traversing", "inspected traffic", "ips engine",
        "flow-based", "proxy-based", "antivirus", "web filter"
    ];

    private static readonly string[] ManagementKeywords =
    [
        "administrative interface", "management interface", "admin interface", "administrator",
        "administrative", "admin", "gui", "rest api", "cli", "console", "https management",
        "http management", "forticloud sso", "single sign-on", "fgfm", "fgfmd", "sso login", "privileged",
        "local attacker", "local authenticated", "physical access", "super_admin", "read-only admin",
        "authenticated attacker with", "admin profile", "management plane", "ssh access"
    ];

    private static readonly string[] ManagementComponents =
    [
        "gui", "rest api", "cli", "fgfm", "admin", "management", "ha", "system", "sso", "forticloud"
    ];

    private static readonly string[] ExposedComponents =
    [
        "ssl-vpn", "sslvpn", "ssl vpn", "ipsec", "ike", "vpn", "proxy", "captive portal", "ips",
        "web filter", "antivirus", "dns", "ztna", "wad"
    ];

    public static (PsirtRiskLevel Risk, string Reason) Classify(string? title, string? rssSummary, string? advisoryPage)
    {
        var normalizedPage = string.IsNullOrWhiteSpace(advisoryPage) ? string.Empty : Normalize(advisoryPage);
        var summary = ExtractSummary(normalizedPage);
        var component = ExtractField(ComponentRegex(), normalizedPage);
        var attackType = ExtractField(AttackTypeRegex(), normalizedPage);

        var text = $" {title} {(string.IsNullOrWhiteSpace(summary) ? Normalize(rssSummary ?? string.Empty) : summary)} "
            .ToLowerInvariant();
        var componentLower = component?.ToLowerInvariant() ?? string.Empty;

        var unauthenticated = attackType?.Contains("unauthenticated", StringComparison.OrdinalIgnoreCase) == true
            || (attackType is null && (text.Contains("unauthenticated") || text.Contains("unauthorized") || text.Contains("remote attacker")));

        var componentLabel = string.IsNullOrWhiteSpace(component) ? string.Empty : $" (component: {component})";

        var exposedHit = FirstMatch(componentLower, ExposedComponents) ?? FirstMatch(text, ExposedServiceKeywords);
        if (exposedHit is not null)
        {
            return unauthenticated
                ? (PsirtRiskLevel.High, $"Affects an internet-facing service ('{exposedHit.Trim()}'){componentLabel} and is exploitable without authentication — not mitigated by restricted management access.")
                : (PsirtRiskLevel.Medium, $"Affects an internet-facing service ('{exposedHit.Trim()}'){componentLabel} but requires authentication.");
        }

        var managementHit = FirstMatch(componentLower, ManagementComponents) ?? FirstMatch(text, ManagementKeywords);
        if (managementHit is not null)
        {
            return (PsirtRiskLevel.Low, $"Requires access to the management plane ('{managementHit.Trim()}'){componentLabel} — mitigated because management is not exposed to the internet and is restricted to specific IPs.");
        }

        return (PsirtRiskLevel.Medium, $"Attack surface could not be determined automatically{componentLabel} — review manually.");
    }

    private static string? FirstMatch(string haystack, IEnumerable<string> needles)
    {
        if (string.IsNullOrEmpty(haystack))
        {
            return null;
        }

        return needles.FirstOrDefault(needle =>
            Regex.IsMatch(haystack, $@"(?<![a-z0-9_]){Regex.Escape(needle)}(?![a-z0-9_])"));
    }

    /// <summary>Only the advisory's Summary section is used so site navigation text cannot skew the result.</summary>
    private static string ExtractSummary(string normalizedPage)
    {
        if (string.IsNullOrEmpty(normalizedPage))
        {
            return string.Empty;
        }

        var end = SummaryEndRegex().Match(normalizedPage);
        var endIndex = end.Success ? end.Index : normalizedPage.Length;
        var start = normalizedPage.LastIndexOf(" Summary ", endIndex, StringComparison.Ordinal);
        if (start < 0)
        {
            return string.Empty;
        }

        start += " Summary ".Length;
        var length = Math.Min(endIndex - start, 4000);
        return length > 0 ? normalizedPage.Substring(start, length).Trim() : string.Empty;
    }

    private static string? ExtractField(Regex regex, string normalizedPage)
    {
        var match = regex.Match(normalizedPage);
        return match.Success && match.Groups[1].Value.Trim().Length is > 0 and < 80 ? match.Groups[1].Value.Trim() : null;
    }

    private static string Normalize(string html)
    {
        var withoutBlocks = ScriptStyleRegex().Replace(html, " ");
        var withoutTags = TagRegex().Replace(withoutBlocks, " ");
        return " " + WhitespaceRegex().Replace(System.Net.WebUtility.HtmlDecode(withoutTags), " ").Trim() + " ";
    }

    [GeneratedRegex(@"<script[\s\S]*?</script>|<style[\s\S]*?</style>", RegexOptions.IgnoreCase)]
    private static partial Regex ScriptStyleRegex();

    [GeneratedRegex(@"<[^>]+>")]
    private static partial Regex TagRegex();

    [GeneratedRegex(@"\s+")]
    private static partial Regex WhitespaceRegex();

    [GeneratedRegex(@" (?:Version Affected|Affected Products|Affected Versions|Solutions?|Workarounds?) ")]
    private static partial Regex SummaryEndRegex();

    [GeneratedRegex(@" Component (.+?) Severity ")]
    private static partial Regex ComponentRegex();

    [GeneratedRegex(@" Attack Type (.+?) (?:Known Exploited|CVSSv3|Impact|CVE ID) ")]
    private static partial Regex AttackTypeRegex();
}
