using System.Net;
using System.Net.Mail;
using FortiGateDashboard.Core.Interfaces;
using FortiGateDashboard.Core.Options;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace FortiGateDashboard.Infrastructure.Notifications;

public class EmailNotificationChannel : INotificationChannel
{
    private readonly EmailOptions _options;
    private readonly ILogger<EmailNotificationChannel> _logger;

    public EmailNotificationChannel(IOptions<NotificationOptions> options, ILogger<EmailNotificationChannel> logger)
    {
        _options = options.Value.Email;
        _logger = logger;
    }

    public string Name => "Email";

    public async Task SendAsync(NotificationEvent notification, CancellationToken cancellationToken = default)
    {
        if (!_options.Enabled || _options.ToAddresses.Count == 0)
        {
            return;
        }

        using var message = new MailMessage
        {
            From = new MailAddress(_options.FromAddress),
            Subject = $"[FortiGate Dashboard] {notification.Title}",
            Body = notification.Message + (notification.Url is null ? string.Empty : $"\n\n{notification.Url}"),
            IsBodyHtml = false
        };

        foreach (var to in _options.ToAddresses)
        {
            message.To.Add(to);
        }

        using var client = new SmtpClient(_options.SmtpHost, _options.SmtpPort)
        {
            EnableSsl = true,
            Credentials = _options.Username is null
                ? null
                : new NetworkCredential(_options.Username, _options.Password)
        };

        try
        {
            await client.SendMailAsync(message, cancellationToken);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Failed to send email notification for {Type}", notification.Type);
        }
    }
}
