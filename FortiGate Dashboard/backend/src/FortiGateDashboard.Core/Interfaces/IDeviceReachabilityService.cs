using FortiGateDashboard.Core.Models;

namespace FortiGateDashboard.Core.Interfaces;

/// <summary>
/// Probes a device IP for ICMP echo and TCP port (22, 443, 9443) reachability.
/// Results reflect reachability from the dashboard host, not necessarily device health:
/// devices behind NAT or with management services disabled on the probed interface
/// will report as unreachable even when they are up on-site.
/// </summary>
public interface IDeviceReachabilityService
{
    Task<DeviceReachabilityResult> ProbeAsync(string ipAddress, CancellationToken cancellationToken = default);
}
