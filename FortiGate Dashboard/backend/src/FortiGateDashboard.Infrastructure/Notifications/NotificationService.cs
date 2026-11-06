using FortiGateDashboard.Core.Interfaces;
using Microsoft.Extensions.Logging;

namespace FortiGateDashboard.Infrastructure.Notifications;

/// <summary>Fans a notification event out to every registered, enabled channel.</summary>
public class NotificationService : INotificationService
{
    private readonly IEnumerable<INotificationChannel> _channels;
    private readonly ILogger<NotificationService> _logger;

    public NotificationService(IEnumerable<INotificationChannel> channels, ILogger<NotificationService> logger)
    {
        _channels = channels;
        _logger = logger;
    }

    public async Task PublishAsync(NotificationEvent notification, CancellationToken cancellationToken = default)
    {
        foreach (var channel in _channels)
        {
            try
            {
                await channel.SendAsync(notification, cancellationToken);
            }
            catch (Exception ex)
            {
                _logger.LogWarning(ex, "Notification channel {Channel} failed for event {Type}", channel.Name, notification.Type);
            }
        }
    }
}
