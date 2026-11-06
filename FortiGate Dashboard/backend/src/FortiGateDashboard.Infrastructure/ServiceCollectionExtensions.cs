using FortiGateDashboard.Core.Interfaces;
using FortiGateDashboard.Core.Options;
using FortiGateDashboard.Infrastructure.Data;
using FortiGateDashboard.Infrastructure.FortiGateCloud;
using FortiGateDashboard.Infrastructure.Notifications;
using FortiGateDashboard.Infrastructure.Psirt;
using FortiGateDashboard.Infrastructure.Sync;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;

namespace FortiGateDashboard.Infrastructure;

public static class ServiceCollectionExtensions
{
    public static IServiceCollection AddFortiGateDashboardInfrastructure(
        this IServiceCollection services,
        IConfiguration configuration,
        bool useInMemoryDatabase = false)
    {
        services.AddOptions<FortiGateCloudOptions>()
            .Bind(configuration.GetSection(FortiGateCloudOptions.SectionName));

        services.AddOptions<PsirtOptions>().Bind(configuration.GetSection(PsirtOptions.SectionName));
        services.AddOptions<NotificationOptions>().Bind(configuration.GetSection(NotificationOptions.SectionName));

        services.AddOptions<FortiGateCloudResiliencyOptions>()
            .Bind(configuration.GetSection(FortiGateCloudResiliencyOptions.SectionName))
            .Validate(o => o.RetryCount >= 0, "RetryCount must be >= 0")
            .Validate(o => o.TimeoutSeconds > 0, "TimeoutSeconds must be > 0")
            .Validate(o => o.TotalTimeoutSeconds > 0, "TotalTimeoutSeconds must be > 0")
            .Validate(o => o.TotalTimeoutSeconds >= o.TimeoutSeconds, "TotalTimeoutSeconds must be >= TimeoutSeconds")
            .Validate(o => o.MaxRetryAfterSeconds > 0, "MaxRetryAfterSeconds must be > 0")
            .Validate(o => o.CircuitBreakerFailureThreshold > 0, "CircuitBreakerFailureThreshold must be > 0")
            .Validate(o => o.CircuitBreakerDurationSeconds > 0, "CircuitBreakerDurationSeconds must be > 0")
            .Validate(o => o.MaxConcurrentRequests > 0, "MaxConcurrentRequests must be > 0")
            .Validate(o => o.MaxQueuedRequests >= 0, "MaxQueuedRequests must be >= 0")
            .Validate(o => o.TruncationWarningThreshold > 0, "TruncationWarningThreshold must be > 0")
            .ValidateOnStart();

        services.AddMemoryCache();

        if (useInMemoryDatabase)
        {
            services.AddDbContext<FortiGateDashboardDbContext>(options =>
                options.UseInMemoryDatabase("FortiGateDashboardTestDb"));
        }
        else
        {
            services.AddDbContext<FortiGateDashboardDbContext>(options =>
                options.UseNpgsql(configuration.GetConnectionString("Default"),
                    npgsql => npgsql.EnableRetryOnFailure(3)));
        }

        services.AddSingleton<FortiGateCloudPolicyRegistry>();

        services.AddHttpClient<IFortiGateCloudService, FortiGateCloudService>()
            // Outer -> inner: TotalTimeout bounds the whole retry sequence; Retry retries
            // 429/5xx/network; CircuitBreaker counts each attempt and fails fast once open;
            // Bulkhead bounds concurrency around only the actual network send (not backoff
            // waits); PerAttemptTimeout bounds a single HTTP call. See
            // FortiGateResiliencePolicyFactory's XML doc for the full rationale.
            .AddPolicyHandler((sp, _) => sp.GetRequiredService<FortiGateCloudPolicyRegistry>().TotalTimeout)
            .AddPolicyHandler((sp, _) => sp.GetRequiredService<FortiGateCloudPolicyRegistry>().Retry)
            .AddPolicyHandler((sp, _) => sp.GetRequiredService<FortiGateCloudPolicyRegistry>().CircuitBreaker)
            .AddPolicyHandler((sp, _) => sp.GetRequiredService<FortiGateCloudPolicyRegistry>().Bulkhead)
            .AddPolicyHandler((sp, _) => sp.GetRequiredService<FortiGateCloudPolicyRegistry>().Timeout);

        services.AddHttpClient<IPsirtService, PsirtService>()
            .AddPolicyHandler((sp, _) => sp.GetRequiredService<FortiGateCloudPolicyRegistry>().TotalTimeout)
            .AddPolicyHandler((sp, _) => sp.GetRequiredService<FortiGateCloudPolicyRegistry>().Retry)
            .AddPolicyHandler((sp, _) => sp.GetRequiredService<FortiGateCloudPolicyRegistry>().Timeout);

        services.AddHttpClient<INotificationChannel, ZabbixNotificationChannel>();
        services.AddHttpClient<INotificationChannel, TeamsNotificationChannel>();
        services.AddScoped<INotificationChannel, EmailNotificationChannel>();

        services.AddScoped<INotificationService, NotificationService>();
        services.AddScoped<ISyncService, SyncService>();

        return services;
    }
}
