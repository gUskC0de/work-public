namespace FortiGateDashboard.Core.Interfaces;

public enum NotificationEventType
{
    NewCriticalPsirt,
    SubscriptionExpiringSoon,
    DeviceAffectedByCriticalCve
}

public record NotificationEvent(
    NotificationEventType Type,
    string Title,
    string Message,
    string? DeviceSerialNumber,
    string? Severity,
    string? Url);

/// <summary>Fan-out abstraction for alerting integrations (Zabbix, Teams, Email, ServiceNow...).</summary>
public interface INotificationChannel
{
    string Name { get; }

    Task SendAsync(NotificationEvent notification, CancellationToken cancellationToken = default);
}

/// <summary>Dispatches notification events to all enabled channels.</summary>
public interface INotificationService
{
    Task PublishAsync(NotificationEvent notification, CancellationToken cancellationToken = default);
}
