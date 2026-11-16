using System.Net.Http.Json;
using FortiGateDashboard.Core.Interfaces;
using FortiGateDashboard.Core.Options;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace FortiGateDashboard.Infrastructure.Notifications;

/// <summary>Sends alerts to a Zabbix server via the trapper HTTP endpoint (zabbix_sender-compatible JSON).</summary>
public class ZabbixNotificationChannel : INotificationChannel
{
    private readonly HttpClient _httpClient;
    private readonly ZabbixOptions _options;
    private readonly ILogger<ZabbixNotificationChannel> _logger;

    public ZabbixNotificationChannel(HttpClient httpClient, IOptions<NotificationOptions> options, ILogger<ZabbixNotificationChannel> logger)
    {
        _httpClient = httpClient;
        _options = options.Value.Zabbix;
        _logger = logger;
    }

    public string Name => "Zabbix";

    public async Task SendAsync(NotificationEvent notification, CancellationToken cancellationToken = default)
    {
        if (!_options.Enabled)
        {
            return;
        }

        var payload = new
        {
            request = "sender data",
            data = new[]
            {
                new
                {
                    host = _options.Host,
                    key = $"fortigate.alert.{notification.Type}".ToLowerInvariant(),
                    value = notification.Message
                }
            }
        };

        try
        {
            using var response = await _httpClient.PostAsJsonAsync(_options.TrapperUrl, payload, cancellationToken);
            response.EnsureSuccessStatusCode();
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Failed to send Zabbix notification for {Type}", notification.Type);
        }
    }
}
