using System.Net.Http.Json;
using FortiGateDashboard.Core.Interfaces;
using FortiGateDashboard.Core.Options;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace FortiGateDashboard.Infrastructure.Notifications;

/// <summary>Posts adaptive-card style alerts to a Microsoft Teams incoming webhook.</summary>
public class TeamsNotificationChannel : INotificationChannel
{
    private readonly HttpClient _httpClient;
    private readonly TeamsOptions _options;
    private readonly ILogger<TeamsNotificationChannel> _logger;

    public TeamsNotificationChannel(HttpClient httpClient, IOptions<NotificationOptions> options, ILogger<TeamsNotificationChannel> logger)
    {
        _httpClient = httpClient;
        _options = options.Value.Teams;
        _logger = logger;
    }

    public string Name => "MicrosoftTeams";

    public async Task SendAsync(NotificationEvent notification, CancellationToken cancellationToken = default)
    {
        if (!_options.Enabled)
        {
            return;
        }

        var color = notification.Severity switch
        {
            "Critical" => "attention",
            "High" => "warning",
            _ => "good"
        };

        var card = new
        {
            type = "message",
            attachments = new[]
            {
                new
                {
                    contentType = "application/vnd.microsoft.card.adaptive",
                    content = new
                    {
                        type = "AdaptiveCard",
                        version = "1.4",
                        body = new object[]
                        {
                            new { type = "TextBlock", text = notification.Title, weight = "bolder", size = "medium" },
                            new { type = "TextBlock", text = notification.Message, wrap = true },
                            new { type = "TextBlock", text = notification.DeviceSerialNumber ?? string.Empty, wrap = true, isSubtle = true }
                        },
                        actions = notification.Url is null
                            ? Array.Empty<object>()
                            : new object[] { new { type = "Action.OpenUrl", title = "View advisory", url = notification.Url } },
                        msteams = new { width = "full" }
                    }
                }
            },
            themeColor = color
        };

        try
        {
            using var response = await _httpClient.PostAsJsonAsync(_options.WebhookUrl, card, cancellationToken);
            response.EnsureSuccessStatusCode();
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Failed to send Teams notification for {Type}", notification.Type);
        }
    }
}
