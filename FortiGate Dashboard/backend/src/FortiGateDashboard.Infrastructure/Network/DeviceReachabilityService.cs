using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using FortiGateDashboard.Core.Interfaces;
using FortiGateDashboard.Core.Models;
using Microsoft.Extensions.Logging;

namespace FortiGateDashboard.Infrastructure.Network;

/// <summary>
/// Probes device IPs with an ICMP echo and TCP connects to ports 22, 443 and 9443.
/// A port counts as "open" only when the TCP handshake completes within the timeout;
/// ICMP failures of any kind (timeout, unreachable, resolution error) count as unreachable.
/// </summary>
public class DeviceReachabilityService : IDeviceReachabilityService
{
    private static readonly TimeSpan ProbeTimeout = TimeSpan.FromSeconds(2);
    private const int SshPort = 22;
    private const int HttpsPort = 443;
    private const int AltPort = 9443;

    private readonly ILogger<DeviceReachabilityService> _logger;

    public DeviceReachabilityService(ILogger<DeviceReachabilityService> logger)
    {
        _logger = logger;
    }

    public async Task<DeviceReachabilityResult> ProbeAsync(string ipAddress, CancellationToken cancellationToken = default)
    {
        // Only probe literal IP addresses that are already stored for a device — never
        // resolve hostnames or accept arbitrary targets, so the API can't be used as a scanner.
        if (!IPAddress.TryParse(ipAddress, out var address))
        {
            _logger.LogWarning("Skipping reachability probe for unparseable IP address {IpAddress}", ipAddress);
            return new DeviceReachabilityResult(false, false, false, false, DateTimeOffset.UtcNow);
        }

        var icmpTask = ProbeIcmpAsync(address, cancellationToken);
        var sshTask = ProbeTcpPortAsync(address, SshPort, cancellationToken);
        var httpsTask = ProbeTcpPortAsync(address, HttpsPort, cancellationToken);
        var altTask = ProbeTcpPortAsync(address, AltPort, cancellationToken);

        await Task.WhenAll(icmpTask, sshTask, httpsTask, altTask);

        return new DeviceReachabilityResult(
            icmpTask.Result,
            sshTask.Result,
            httpsTask.Result,
            altTask.Result,
            DateTimeOffset.UtcNow);
    }

    private async Task<bool> ProbeIcmpAsync(IPAddress address, CancellationToken cancellationToken)
    {
        try
        {
            using var ping = new Ping();
            var reply = await ping.SendPingAsync(address, ProbeTimeout, cancellationToken: cancellationToken);
            return reply.Status == IPStatus.Success;
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception ex)
        {
            // PingException also covers hosts where unprivileged ICMP sockets are unavailable.
            _logger.LogDebug(ex, "ICMP probe failed for {Address}", address);
            return false;
        }
    }

    private async Task<bool> ProbeTcpPortAsync(IPAddress address, int port, CancellationToken cancellationToken)
    {
        try
        {
            using var client = new TcpClient(address.AddressFamily);
            using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeoutCts.CancelAfter(ProbeTimeout);
            await client.ConnectAsync(address, port, timeoutCts.Token);
            return true;
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception ex)
        {
            _logger.LogDebug(ex, "TCP probe failed for {Address}:{Port}", address, port);
            return false;
        }
    }
}
