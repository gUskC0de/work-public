namespace FortiGateDashboard.Core.Options;

/// <summary>
/// Controls ASP.NET Core's forwarded-headers middleware. Left empty by default (safe default:
/// trust nothing), so `X-Forwarded-For`/`X-Forwarded-Proto` are ignored unless an operator
/// explicitly lists their reverse proxy's IP/network here, per deployment topology.
/// </summary>
public class ForwardedHeadersSettings
{
    public const string SectionName = "ForwardedHeaders";

    public bool Enabled { get; set; }

    /// <summary>Exact IP addresses of trusted reverse proxies (e.g. "10.0.0.5").</summary>
    public List<string> KnownProxies { get; set; } = new();

    /// <summary>CIDR ranges of trusted proxy networks (e.g. "10.0.0.0/24").</summary>
    public List<string> KnownNetworks { get; set; } = new();
}
