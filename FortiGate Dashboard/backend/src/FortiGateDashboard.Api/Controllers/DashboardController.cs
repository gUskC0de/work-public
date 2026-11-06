using FortiGateDashboard.Api.Dtos;
using FortiGateDashboard.Core.Entities;
using FortiGateDashboard.Core.Options;
using FortiGateDashboard.Infrastructure.Data;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.RateLimiting;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Options;

namespace FortiGateDashboard.Api.Controllers;

[ApiController]
[Authorize]
[EnableRateLimiting("general")]
[Route("api/dashboard")]
public class DashboardController : ControllerBase
{
    private readonly FortiGateDashboardDbContext _db;
    private readonly FortiGateCloudOptions _cloudOptions;
    private const int OldFirmwareMajorVersionThreshold = 7; // Devices on FortiOS < 7.x considered outdated.

    public DashboardController(FortiGateDashboardDbContext db, IOptions<FortiGateCloudOptions> cloudOptions)
    {
        _db = db;
        _cloudOptions = cloudOptions.Value;
    }

    /// <summary>Summary KPI cards for the main dashboard view.</summary>
    [HttpGet]
    public async Task<ActionResult<DashboardSummaryDto>> GetSummary(CancellationToken cancellationToken)
    {
        var totalDevices = await _db.Devices.CountAsync(cancellationToken);
        var registered = await _db.Devices.CountAsync(d => d.CloudManagementStatus == CloudManagementStatus.Registered, cancellationToken);

        var expiring30 = await _db.Subscriptions.CountAsync(s => s.DaysRemaining >= 0 && s.DaysRemaining < 30, cancellationToken);
        var expiring90 = await _db.Subscriptions.CountAsync(s => s.DaysRemaining >= 0 && s.DaysRemaining < 90, cancellationToken);

        var criticalPsirtDevices = await _db.DevicePsirts
            .Where(dp => dp.PsirtAdvisory.Severity == PsirtSeverity.Critical && dp.CorrelationStatus == PsirtCorrelationStatus.Affected)
            .Select(dp => dp.DeviceId)
            .Distinct()
            .CountAsync(cancellationToken);

        // Tracked separately from confirmed-critical: an unparseable advisory or firmware
        // string must never be silently folded into either "confirmed vulnerable" or "clean".
        var unresolvedPsirtDevices = await _db.DevicePsirts
            .Where(dp => dp.CorrelationStatus == PsirtCorrelationStatus.UnableToEvaluate || dp.CorrelationStatus == PsirtCorrelationStatus.Unknown)
            .Select(dp => dp.DeviceId)
            .Distinct()
            .CountAsync(cancellationToken);

        var oldFirmwareDevices = await _db.Devices
            .CountAsync(d => d.FirmwareVersion.StartsWith("6.") || d.FirmwareVersion.StartsWith("5."), cancellationToken);

        var summary = new DashboardSummaryDto(
            totalDevices,
            registered,
            expiring30,
            expiring90,
            criticalPsirtDevices,
            oldFirmwareDevices,
            unresolvedPsirtDevices);

        return Ok(summary);
    }

    /// <summary>Safe setup and latest synchronization state; credential values are never returned.</summary>
    [HttpGet("connection")]
    public async Task<ActionResult<CloudConnectionStatusDto>> GetConnectionStatus(CancellationToken cancellationToken)
    {
        var missingSettings = new List<string>();
        if (string.IsNullOrWhiteSpace(_cloudOptions.ClientId)) missingSettings.Add("Client ID");
        if (string.IsNullOrWhiteSpace(_cloudOptions.Username)) missingSettings.Add("Username");
        if (string.IsNullOrWhiteSpace(_cloudOptions.Password)) missingSettings.Add("Password");
        if (_cloudOptions.AccountId <= 0) missingSettings.Add("Account ID");

        var latestSyncs = await _db.SyncHistories
            .AsNoTracking()
            .GroupBy(history => history.SyncType)
            .Select(group => group.OrderByDescending(history => history.StartedAt).First())
            .ToListAsync(cancellationToken);

        var stages = Enum.GetValues<SyncType>()
            .Select(syncType =>
            {
                var latest = latestSyncs.FirstOrDefault(history => history.SyncType == syncType);
                return new SyncStageStatusDto(
                    syncType.ToString(),
                    latest?.Status.ToString(),
                    latest?.StartedAt,
                    latest?.CompletedAt,
                    latest?.RecordsProcessed);
            })
            .ToList();

        return Ok(new CloudConnectionStatusDto(missingSettings.Count == 0, missingSettings, stages));
    }
}
