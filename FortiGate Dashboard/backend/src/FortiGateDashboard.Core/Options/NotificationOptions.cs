namespace FortiGateDashboard.Core.Options;

public class PsirtOptions
{
    public const string SectionName = "Psirt";

    public string FeedUrl { get; set; } = "https://filestore.fortinet.com/fortiguard/rss/psirt.xml";
}

public class NotificationOptions
{
    public const string SectionName = "Notifications";

    public ZabbixOptions Zabbix { get; set; } = new();

    public TeamsOptions Teams { get; set; } = new();

    public EmailOptions Email { get; set; } = new();
}

public class ZabbixOptions
{
    public bool Enabled { get; set; }

    public string TrapperUrl { get; set; } = default!;

    public string Host { get; set; } = "fortigate-dashboard";
}

public class TeamsOptions
{
    public bool Enabled { get; set; }

    public string WebhookUrl { get; set; } = default!;
}

public class EmailOptions
{
    public bool Enabled { get; set; }

    public string SmtpHost { get; set; } = default!;

    public int SmtpPort { get; set; } = 587;

    public string FromAddress { get; set; } = default!;

    public List<string> ToAddresses { get; set; } = new();

    public string? Username { get; set; }

    public string? Password { get; set; }
}
