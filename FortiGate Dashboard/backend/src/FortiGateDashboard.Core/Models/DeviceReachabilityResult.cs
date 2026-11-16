namespace FortiGateDashboard.Core.Models;

/// <summary>Outcome of probing a single device IP for ICMP and TCP port reachability.</summary>
public record DeviceReachabilityResult(
    bool IcmpReachable,
    bool SshPortOpen,
    bool HttpsPortOpen,
    bool Port9443Open,
    DateTimeOffset CheckedAt);
