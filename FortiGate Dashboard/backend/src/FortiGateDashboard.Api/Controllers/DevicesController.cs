using FortiGateDashboard.Api.Dtos;
using FortiGateDashboard.Core.Entities;
using FortiGateDashboard.Infrastructure.Data;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.RateLimiting;
using Microsoft.EntityFrameworkCore;

namespace FortiGateDashboard.Api.Controllers;

[ApiController]
[Authorize]
[EnableRateLimiting("general")]
[Route("api/devices")]
public class DevicesController : ControllerBase
{
    private readonly FortiGateDashboardDbContext _db;

    public DevicesController(FortiGateDashboardDbContext db)
    {
        _db = db;
    }

    /// <summary>Paginated, searchable, sortable device inventory.</summary>
    [HttpGet]
    public async Task<ActionResult<PagedResult<DeviceListItemDto>>> GetDevices(
        [FromQuery] string? search,
        [FromQuery] string? subscriptionStatus,
        [FromQuery] string? cloudManagementStatus,
        [FromQuery] bool? hasCriticalCves,
        [FromQuery] bool? hasPsirt,
        [FromQuery] bool? hasUnresolved,
        [FromQuery] double? minimumCvss,
        [FromQuery] bool? tunnelAlive,
        [FromQuery] string sortBy = "name",
        [FromQuery] bool descending = false,
        [FromQuery] int page = 1,
        [FromQuery] int pageSize = 25,
        CancellationToken cancellationToken = default)
    {
        page = Math.Max(page, 1);
        pageSize = Math.Clamp(pageSize, 1, 500);

        var totalDeviceCount = await _db.Devices.CountAsync(cancellationToken);

        var query = _db.Devices
            .Include(d => d.Subscriptions)
            .Include(d => d.DevicePsirts).ThenInclude(dp => dp.PsirtAdvisory)
            .AsNoTracking()
            .AsQueryable();

        if (!string.IsNullOrWhiteSpace(search))
        {
            var term = search.Trim().ToLower();
            query = query.Where(d =>
                d.Name.ToLower().Contains(term) ||
                d.SerialNumber.ToLower().Contains(term) ||
                d.Model.ToLower().Contains(term));
        }

        if (!string.IsNullOrWhiteSpace(cloudManagementStatus) &&
            Enum.TryParse<CloudManagementStatus>(cloudManagementStatus, true, out var cms))
        {
            query = query.Where(d => d.CloudManagementStatus == cms);
        }

        if (!string.IsNullOrWhiteSpace(subscriptionStatus) &&
            Enum.TryParse<SubscriptionStatus>(subscriptionStatus, true, out var subStatus))
        {
            query = query.Where(d => d.Subscriptions.Any(s => s.Status == subStatus));
        }

        if (hasCriticalCves is not null)
        {
            query = hasCriticalCves.Value
                ? query.Where(d => d.DevicePsirts.Any(dp => dp.CorrelationStatus == PsirtCorrelationStatus.Affected && dp.PsirtAdvisory.Severity == PsirtSeverity.Critical))
                : query.Where(d => !d.DevicePsirts.Any(dp => dp.CorrelationStatus == PsirtCorrelationStatus.Affected && dp.PsirtAdvisory.Severity == PsirtSeverity.Critical));
        }

        if (hasPsirt is not null)
        {
            query = hasPsirt.Value
                ? query.Where(d => d.DevicePsirts.Any(dp => dp.CorrelationStatus == PsirtCorrelationStatus.Affected))
                : query.Where(d => !d.DevicePsirts.Any(dp => dp.CorrelationStatus == PsirtCorrelationStatus.Affected));
        }

        if (hasUnresolved is not null)
        {
            query = hasUnresolved.Value
                ? query.Where(d => d.DevicePsirts.Any(dp => dp.CorrelationStatus == PsirtCorrelationStatus.UnableToEvaluate || dp.CorrelationStatus == PsirtCorrelationStatus.Unknown))
                : query.Where(d => !d.DevicePsirts.Any(dp => dp.CorrelationStatus == PsirtCorrelationStatus.UnableToEvaluate || dp.CorrelationStatus == PsirtCorrelationStatus.Unknown));
        }

        if (minimumCvss is not null)
        {
            query = query.Where(d => d.DevicePsirts.Any(dp => dp.CorrelationStatus == PsirtCorrelationStatus.Affected && dp.PsirtAdvisory.CvssScore >= minimumCvss));
        }

        if (tunnelAlive is not null)
        {
            query = query.Where(d => d.TunnelAlive == tunnelAlive);
        }

        query = sortBy.ToLowerInvariant() switch
        {
            "serialnumber" => descending ? query.OrderByDescending(d => d.SerialNumber) : query.OrderBy(d => d.SerialNumber),
            "model" => descending ? query.OrderByDescending(d => d.Model) : query.OrderBy(d => d.Model),
            "firmwareversion" => descending ? query.OrderByDescending(d => d.FirmwareVersion) : query.OrderBy(d => d.FirmwareVersion),
            "cloudmanagementstatus" => descending ? query.OrderByDescending(d => d.CloudManagementStatus).ThenBy(d => d.Name) : query.OrderBy(d => d.CloudManagementStatus).ThenBy(d => d.Name),
            "tunnelalive" => descending ? query.OrderByDescending(d => d.TunnelAlive).ThenBy(d => d.Name) : query.OrderBy(d => d.TunnelAlive).ThenBy(d => d.Name),
            "ipaddress" => descending ? query.OrderByDescending(d => d.IpAddress).ThenBy(d => d.Name) : query.OrderBy(d => d.IpAddress).ThenBy(d => d.Name),
            "subscriptionstatus" => descending ? query.OrderByDescending(d => d.Subscriptions.OrderBy(s => s.ExpiryDate).Select(s => s.Status).FirstOrDefault()).ThenBy(d => d.Name) : query.OrderBy(d => d.Subscriptions.OrderBy(s => s.ExpiryDate).Select(s => s.Status).FirstOrDefault()).ThenBy(d => d.Name),
            "expirydate" => descending
                ? query.OrderBy(d => !d.Subscriptions.Any()).ThenByDescending(d => d.Subscriptions.Min(s => s.ExpiryDate)).ThenBy(d => d.Name)
                : query.OrderBy(d => !d.Subscriptions.Any()).ThenBy(d => d.Subscriptions.Min(s => s.ExpiryDate)).ThenBy(d => d.Name),
            "criticalcvecount" => descending ? query.OrderByDescending(d => d.DevicePsirts.Count(dp => dp.CorrelationStatus == PsirtCorrelationStatus.Affected && dp.PsirtAdvisory.Severity == PsirtSeverity.Critical)).ThenBy(d => d.Name) : query.OrderBy(d => d.DevicePsirts.Count(dp => dp.CorrelationStatus == PsirtCorrelationStatus.Affected && dp.PsirtAdvisory.Severity == PsirtSeverity.Critical)).ThenBy(d => d.Name),
            "highestcvss" => descending ? query.OrderByDescending(d => d.DevicePsirts.Where(dp => dp.CorrelationStatus == PsirtCorrelationStatus.Affected).Max(dp => (double?)dp.PsirtAdvisory.CvssScore) ?? 0).ThenBy(d => d.Name) : query.OrderBy(d => d.DevicePsirts.Where(dp => dp.CorrelationStatus == PsirtCorrelationStatus.Affected).Max(dp => (double?)dp.PsirtAdvisory.CvssScore) ?? 0).ThenBy(d => d.Name),
            "latestpsirturl" => descending ? query.OrderByDescending(d => d.DevicePsirts.Any(dp => dp.CorrelationStatus == PsirtCorrelationStatus.Affected)).ThenBy(d => d.Name) : query.OrderBy(d => d.DevicePsirts.Any(dp => dp.CorrelationStatus == PsirtCorrelationStatus.Affected)).ThenBy(d => d.Name),
            "unabletoevaluatecount" => descending ? query.OrderByDescending(d => d.DevicePsirts.Count(dp => dp.CorrelationStatus == PsirtCorrelationStatus.UnableToEvaluate || dp.CorrelationStatus == PsirtCorrelationStatus.Unknown)).ThenBy(d => d.Name) : query.OrderBy(d => d.DevicePsirts.Count(dp => dp.CorrelationStatus == PsirtCorrelationStatus.UnableToEvaluate || dp.CorrelationStatus == PsirtCorrelationStatus.Unknown)).ThenBy(d => d.Name),
            _ => descending ? query.OrderByDescending(d => d.Name) : query.OrderBy(d => d.Name)
        };

        var totalCount = await query.CountAsync(cancellationToken);

        var devices = await query
            .Skip((page - 1) * pageSize)
            .Take(pageSize)
            .ToListAsync(cancellationToken);

        var items = devices.Select(ToListItemDto).ToList();

        return Ok(new PagedResult<DeviceListItemDto>(items, totalCount, totalDeviceCount, page, pageSize));
    }

    /// <summary>Full detail view for a single device by serial number.</summary>
    [HttpGet("{serial}")]
    public async Task<ActionResult<DeviceDetailDto>> GetDevice(string serial, CancellationToken cancellationToken)
    {
        var device = await _db.Devices
            .Include(d => d.Subscriptions)
            .Include(d => d.DevicePsirts).ThenInclude(dp => dp.PsirtAdvisory).ThenInclude(a => a.Cves)
            .AsNoTracking()
            .FirstOrDefaultAsync(d => d.SerialNumber == serial, cancellationToken);

        if (device is null)
        {
            return NotFound();
        }

        var vulnerabilities = device.DevicePsirts
            .SelectMany(dp => dp.PsirtAdvisory.Cves.DefaultIfEmpty(new Core.Entities.Cve
            {
                CveId = dp.PsirtAdvisory.PsirtId,
                CvssScore = dp.PsirtAdvisory.CvssScore,
                PsirtAdvisory = dp.PsirtAdvisory
            }).Select(c => new VulnerabilityDto(
                c.CveId,
                dp.PsirtAdvisory.Severity.ToString(),
                c.CvssScore == 0 ? dp.PsirtAdvisory.CvssScore : c.CvssScore,
                dp.PsirtAdvisory.PsirtId,
                dp.PsirtAdvisory.AdvisoryUrl,
                dp.CorrelationStatus.ToString())))
            .OrderByDescending(v => v.CvssScore)
            .ToList();

        var dto = new DeviceDetailDto(
            device.Id,
            device.Name,
            device.SerialNumber,
            device.Model,
            device.FirmwareVersion,
            device.CloudManagementStatus.ToString(),
            device.LastSeenAt,
            device.TunnelAlive,
            device.IpAddress,
            device.Hostname,
            device.Subscriptions.Select(s => new SubscriptionDto(
                s.SubscriptionName, s.SubscriptionType, s.ExpiryDate, s.DaysRemaining, s.Status.ToString())).ToList(),
            vulnerabilities);

        return Ok(dto);
    }

    /// <summary>Exports the currently filtered device list as CSV.</summary>
    [HttpGet("export/csv")]
    [EnableRateLimiting("export")]
    public async Task<IActionResult> ExportCsv(CancellationToken cancellationToken)
    {
        var devices = await _db.Devices
            .Include(d => d.Subscriptions)
            .Include(d => d.DevicePsirts).ThenInclude(dp => dp.PsirtAdvisory)
            .AsNoTracking()
            .ToListAsync(cancellationToken);

        var sb = new System.Text.StringBuilder();
        sb.AppendLine("Name,SerialNumber,Model,Firmware,CloudManaged,SubscriptionStatus,ExpiryDate,CriticalCves,HighestCvss,PsirtLink,UnableToEvaluateCount");

        foreach (var d in devices.Select(ToListItemDto))
        {
            sb.AppendLine(string.Join(',', new[]
            {
                Csv(d.Name), Csv(d.SerialNumber), Csv(d.Model), Csv(d.FirmwareVersion),
                Csv(d.CloudManagementStatus), Csv(d.SubscriptionStatus),
                Csv(d.ExpiryDate?.ToString("yyyy-MM-dd") ?? string.Empty),
                d.CriticalCveCount.ToString(), d.HighestCvss.ToString("0.0"), Csv(d.LatestPsirtUrl ?? string.Empty),
                d.UnableToEvaluateCount.ToString()
            }));
        }

        var bytes = System.Text.Encoding.UTF8.GetBytes(sb.ToString());
        return File(bytes, "text/csv", $"fortigate-devices-{DateTime.UtcNow:yyyyMMdd}.csv");
    }

    private static string Csv(string value) => value.Contains(',') ? $"\"{value}\"" : value;

    private static DeviceListItemDto ToListItemDto(Device d)
    {
        var subscription = d.Subscriptions.OrderBy(s => s.ExpiryDate).FirstOrDefault();

        // Only a CONFIRMED (Affected) correlation counts toward "critical CVEs"/"highest CVSS" —
        // an Unknown/UnableToEvaluate row must never inflate a "confirmed vulnerable" tally.
        var confirmedAffected = d.DevicePsirts.Where(dp => dp.CorrelationStatus == PsirtCorrelationStatus.Affected).ToList();
        var criticalCves = confirmedAffected.Count(dp => dp.PsirtAdvisory.Severity == PsirtSeverity.Critical);
        var highestCvss = confirmedAffected.Count > 0 ? confirmedAffected.Max(dp => dp.PsirtAdvisory.CvssScore) : 0;
        var latestPsirt = confirmedAffected.OrderByDescending(dp => dp.PsirtAdvisory.PublishedDate).FirstOrDefault();

        var unableToEvaluateCount = d.DevicePsirts.Count(dp =>
            dp.CorrelationStatus == PsirtCorrelationStatus.UnableToEvaluate || dp.CorrelationStatus == PsirtCorrelationStatus.Unknown);

        return new DeviceListItemDto(
            d.Id,
            d.Name,
            d.SerialNumber,
            d.Model,
            d.FirmwareVersion,
            d.CloudManagementStatus.ToString(),
            subscription?.Status.ToString() ?? "Unknown",
            subscription?.ExpiryDate,
            criticalCves,
            highestCvss,
            latestPsirt?.PsirtAdvisory.AdvisoryUrl,
            unableToEvaluateCount,
            d.TunnelAlive,
            d.IpAddress,
            d.Hostname);
    }
}
