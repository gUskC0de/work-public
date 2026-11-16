using FortiGateDashboard.Core.Entities;
using FortiGateDashboard.Core.Interfaces;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.RateLimiting;

namespace FortiGateDashboard.Api.Controllers;

[ApiController]
[Authorize(Roles = "Admin,Operator")]
[EnableRateLimiting("sync")]
[Route("api/sync")]
public class SyncController : ControllerBase
{
    private readonly ISyncService _syncService;

    public SyncController(ISyncService syncService)
    {
        _syncService = syncService;
    }

    /// <summary>Triggers an on-demand full synchronization (inventory, subscriptions, PSIRT).</summary>
    [HttpPost]
    public async Task<ActionResult<IReadOnlyList<SyncHistory>>> TriggerSync(CancellationToken cancellationToken)
    {
        var results = new List<SyncHistory>
        {
            await _syncService.SyncDeviceInventoryAsync(cancellationToken),
            await _syncService.SyncSubscriptionsAsync(cancellationToken),
            await _syncService.SyncPsirtAsync(cancellationToken)
        };

        return Ok(results);
    }
}
