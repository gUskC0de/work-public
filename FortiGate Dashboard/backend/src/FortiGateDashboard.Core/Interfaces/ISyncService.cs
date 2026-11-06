namespace FortiGateDashboard.Core.Interfaces;

using FortiGateDashboard.Core.Entities;

/// <summary>Orchestrates synchronization between FortiGate Cloud / PSIRT feeds and the local database.</summary>
public interface ISyncService
{
    Task<SyncHistory> SyncDeviceInventoryAsync(CancellationToken cancellationToken = default);

    Task<SyncHistory> SyncSubscriptionsAsync(CancellationToken cancellationToken = default);

    Task<SyncHistory> SyncPsirtAsync(CancellationToken cancellationToken = default);
}
