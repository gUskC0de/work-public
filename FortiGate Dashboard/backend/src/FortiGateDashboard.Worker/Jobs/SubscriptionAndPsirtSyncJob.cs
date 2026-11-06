using FortiGateDashboard.Core.Interfaces;
using Quartz;

namespace FortiGateDashboard.Worker.Jobs;

/// <summary>Runs daily: synchronizes subscription/license information and PSIRT advisories.</summary>
[DisallowConcurrentExecution]
public class SubscriptionAndPsirtSyncJob : IJob
{
    private readonly ISyncService _syncService;
    private readonly ILogger<SubscriptionAndPsirtSyncJob> _logger;

    public SubscriptionAndPsirtSyncJob(ISyncService syncService, ILogger<SubscriptionAndPsirtSyncJob> logger)
    {
        _syncService = syncService;
        _logger = logger;
    }

    public async Task Execute(IJobExecutionContext context)
    {
        _logger.LogInformation("Starting scheduled subscription sync");
        var subscriptionResult = await _syncService.SyncSubscriptionsAsync(context.CancellationToken);
        _logger.LogInformation(
            "Subscription sync finished with status {Status}, {Processed} records processed",
            subscriptionResult.Status, subscriptionResult.RecordsProcessed);

        _logger.LogInformation("Starting scheduled PSIRT sync");
        var psirtResult = await _syncService.SyncPsirtAsync(context.CancellationToken);
        _logger.LogInformation(
            "PSIRT sync finished with status {Status}, {Processed} records processed",
            psirtResult.Status, psirtResult.RecordsProcessed);
    }
}
