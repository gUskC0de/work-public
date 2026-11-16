namespace FortiGateDashboard.Core.Models;

/// <summary>
/// Organisation-specific risk of an advisory, assessed against the baseline that firewall
/// management is never reachable from the internet and is restricted to specific source IPs.
/// </summary>
public enum PsirtRiskLevel
{
    Low = 1,
    Medium = 2,
    High = 3
}
