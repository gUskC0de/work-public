using FortiGateDashboard.Core.Interfaces;
using Quartz;

namespace FortiGateDashboard.Worker.Jobs;

/// <summary>Runs every 6 hours: synchronizes device inventory, firmware versions and cloud status.</summary>
[DisallowConcurrentExecution]
public class DeviceInventorySyncJob : IJob
{
    private readonly ISyncService _syncService;
    private readonly ILogger<DeviceInventorySyncJob> _logger;

    public DeviceInventorySyncJob(ISyncService syncService, ILogger<DeviceInventorySyncJob> logger)
    {
        _syncService = syncService;
        _logger = logger;
    }

    public async Task Execute(IJobExecutionContext context)
    {
        _logger.LogInformation("Starting scheduled device inventory sync");
        var result = await _syncService.SyncDeviceInventoryAsync(context.CancellationToken);
        _logger.LogInformation(
            "Device inventory sync finished with status {Status}, {Processed} records processed",
            result.Status, result.RecordsProcessed);
    }
}
