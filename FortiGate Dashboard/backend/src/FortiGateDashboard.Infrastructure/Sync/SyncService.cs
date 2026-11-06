using FortiGateDashboard.Core.Entities;
using FortiGateDashboard.Core.Interfaces;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Logging;
using FortiGateDashboard.Infrastructure.Data;

namespace FortiGateDashboard.Infrastructure.Sync;

/// <summary>
/// Orchestrates synchronization between the FortiGate Cloud / PSIRT feeds and the local
/// database, and raises notifications for critical PSIRTs / soon-to-expire subscriptions.
/// </summary>
public class SyncService : ISyncService
{
    private readonly FortiGateDashboardDbContext _db;
    private readonly IFortiGateCloudService _cloudService;
    private readonly IPsirtService _psirtService;
    private readonly INotificationService _notificationService;
    private readonly ILogger<SyncService> _logger;

    public SyncService(
        FortiGateDashboardDbContext db,
        IFortiGateCloudService cloudService,
        IPsirtService psirtService,
        INotificationService notificationService,
        ILogger<SyncService> logger)
    {
        _db = db;
        _cloudService = cloudService;
        _psirtService = psirtService;
        _notificationService = notificationService;
        _logger = logger;
    }

    public async Task<SyncHistory> SyncDeviceInventoryAsync(CancellationToken cancellationToken = default)
    {
        var history = new SyncHistory { SyncType = SyncType.DeviceInventory, Status = SyncStatus.Running };
        _db.SyncHistories.Add(history);
        await _db.SaveChangesAsync(cancellationToken);

        try
        {
            var fetchResult = await _cloudService.GetDevicesAsync(cancellationToken);
            var existing = await _db.Devices.ToDictionaryAsync(d => d.SerialNumber, cancellationToken);
            var processed = 0;

            foreach (var record in fetchResult.Items)
            {
                if (!existing.TryGetValue(record.SerialNumber, out var device))
                {
                    device = new Device { Id = Guid.NewGuid(), SerialNumber = record.SerialNumber, CreatedAt = DateTimeOffset.UtcNow };
                    _db.Devices.Add(device);
                    existing[record.SerialNumber] = device;
                }

                device.Name = record.Name;
                device.Model = record.Model;
                if (record.FirmwareVersion != "Unknown" || string.IsNullOrWhiteSpace(device.FirmwareVersion))
                {
                    device.FirmwareVersion = record.FirmwareVersion;
                }

                device.AccountId = record.AccountId;
                device.AccountName = record.AccountName;
                device.LastSeenAt = record.LastSeenAt;
                // Absent telemetry means "not reported this run", so keep the last known values.
                device.TunnelAlive = record.TunnelAlive ?? device.TunnelAlive;
                device.IpAddress = record.IpAddress ?? device.IpAddress;
                device.Hostname = record.Hostname ?? device.Hostname;
                device.UpdatedAt = DateTimeOffset.UtcNow;
                device.CloudManagementStatus = record switch
                {
                    { IsOnline: true } => CloudManagementStatus.Online,
                    { IsRegistered: true } => CloudManagementStatus.Registered,
                    _ => CloudManagementStatus.Offline
                };

                processed++;
            }

            await _db.SaveChangesAsync(cancellationToken);

            if (fetchResult.IsPossiblyTruncated)
            {
                // A truncated fetch must never be reported as a fully successful sync — the
                // pagination contract for this endpoint is unverified (see CloudFetchResult<T>).
                history.Status = SyncStatus.PartiallySucceeded;
                history.ErrorMessage = $"Response possibly truncated: {fetchResult.TruncationReason}";
                _logger.LogWarning("Device inventory sync possibly truncated: {Reason}", fetchResult.TruncationReason);
            }
            else
            {
                history.Status = SyncStatus.Succeeded;
            }

            history.RecordsProcessed = processed;
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Device inventory sync failed");
            history.Status = SyncStatus.Failed;
            history.ErrorMessage = ex.Message;
        }
        finally
        {
            history.CompletedAt = DateTimeOffset.UtcNow;
            await _db.SaveChangesAsync(cancellationToken);
        }

        return history;
    }

    public async Task<SyncHistory> SyncSubscriptionsAsync(CancellationToken cancellationToken = default)
    {
        var history = new SyncHistory { SyncType = SyncType.SubscriptionInfo, Status = SyncStatus.Running };
        _db.SyncHistories.Add(history);
        await _db.SaveChangesAsync(cancellationToken);

        try
        {
            var fetchResult = await _cloudService.GetSubscriptionsAsync(cancellationToken);
            var devicesBySerial = await _db.Devices.ToDictionaryAsync(d => d.SerialNumber, cancellationToken);
            var today = DateOnly.FromDateTime(DateTime.UtcNow);
            var processed = 0;

            foreach (var record in fetchResult.Items)
            {
                if (!devicesBySerial.TryGetValue(record.DeviceSerialNumber, out var device))
                {
                    continue;
                }

                var subscription = await _db.Subscriptions.FirstOrDefaultAsync(
                    s => s.DeviceId == device.Id && s.SubscriptionType == record.SubscriptionType,
                    cancellationToken);

                if (subscription is null)
                {
                    subscription = new Subscription { Id = Guid.NewGuid(), DeviceId = device.Id };
                    _db.Subscriptions.Add(subscription);
                }

                var daysRemaining = record.ExpiryDate.DayNumber - today.DayNumber;
                var previousStatus = subscription.Status;

                subscription.SubscriptionName = record.SubscriptionName;
                subscription.SubscriptionType = record.SubscriptionType;
                subscription.ExpiryDate = record.ExpiryDate;
                subscription.DaysRemaining = daysRemaining;
                subscription.Status = Subscription.CalculateStatus(daysRemaining);
                subscription.UpdatedAt = DateTimeOffset.UtcNow;

                if (subscription.Status == SubscriptionStatus.Critical && previousStatus != SubscriptionStatus.Critical)
                {
                    await _notificationService.PublishAsync(new NotificationEvent(
                        NotificationEventType.SubscriptionExpiringSoon,
                        "Subscription expiring soon",
                        $"Device {device.Name} ({device.SerialNumber}) subscription '{subscription.SubscriptionName}' expires in {daysRemaining} days.",
                        device.SerialNumber,
                        "Critical",
                        null), cancellationToken);
                }

                processed++;
            }

            await _db.SaveChangesAsync(cancellationToken);

            if (fetchResult.IsPossiblyTruncated)
            {
                history.Status = SyncStatus.PartiallySucceeded;
                history.ErrorMessage = $"Response possibly truncated: {fetchResult.TruncationReason}";
                _logger.LogWarning("Subscription sync possibly truncated: {Reason}", fetchResult.TruncationReason);
            }
            else
            {
                history.Status = SyncStatus.Succeeded;
            }

            history.RecordsProcessed = processed;
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Subscription sync failed");
            history.Status = SyncStatus.Failed;
            history.ErrorMessage = ex.Message;
        }
        finally
        {
            history.CompletedAt = DateTimeOffset.UtcNow;
            await _db.SaveChangesAsync(cancellationToken);
        }

        return history;
    }

    public async Task<SyncHistory> SyncPsirtAsync(CancellationToken cancellationToken = default)
    {
        var history = new SyncHistory { SyncType = SyncType.PsirtInfo, Status = SyncStatus.Running };
        _db.SyncHistories.Add(history);
        await _db.SaveChangesAsync(cancellationToken);

        try
        {
            var advisories = await _psirtService.GetAdvisoriesAsync(cancellationToken);
            var existingAdvisories = await _db.PsirtAdvisories.Include(p => p.Cves).ToDictionaryAsync(p => p.PsirtId, cancellationToken);
            var existingAdvisoriesByUrl = existingAdvisories.Values
                .Where(p => !string.IsNullOrWhiteSpace(p.AdvisoryUrl))
                .ToDictionary(p => p.AdvisoryUrl, StringComparer.OrdinalIgnoreCase);
            var processed = 0;

            foreach (var record in advisories)
            {
                if (!existingAdvisories.TryGetValue(record.PsirtId, out var advisory))
                {
                    if (!existingAdvisoriesByUrl.TryGetValue(record.AdvisoryUrl, out advisory))
                    {
                        advisory = new PsirtAdvisory { Id = Guid.NewGuid(), PsirtId = record.PsirtId };
                        _db.PsirtAdvisories.Add(advisory);
                        existingAdvisoriesByUrl[record.AdvisoryUrl] = advisory;
                    }

                    advisory.PsirtId = record.PsirtId;
                    existingAdvisories[record.PsirtId] = advisory;
                }

                var isNew = advisory.Title is null;
                advisory.Title = record.Title;
                advisory.AdvisoryUrl = record.AdvisoryUrl;
                advisory.Severity = Enum.TryParse<PsirtSeverity>(record.Severity, true, out var sev) ? sev : PsirtSeverity.Low;
                advisory.CvssScore = record.CvssScore;
                advisory.PublishedDate = record.PublishedDate;
                advisory.AffectedVersionRange = record.AffectedVersionRange;
                advisory.ParseStatus = record.ParseStatus;

                foreach (var cveRecord in record.Cves)
                {
                    if (advisory.Cves.All(c => c.CveId != cveRecord.CveId))
                    {
                        advisory.Cves.Add(new Cve
                        {
                            Id = Guid.NewGuid(),
                            CveId = cveRecord.CveId,
                            Description = cveRecord.Description,
                            CvssScore = cveRecord.CvssScore == 0 ? record.CvssScore : cveRecord.CvssScore,
                            PsirtAdvisoryId = advisory.Id
                        });
                    }
                }

                if (isNew && advisory.Severity == PsirtSeverity.Critical)
                {
                    await _notificationService.PublishAsync(new NotificationEvent(
                        NotificationEventType.NewCriticalPsirt,
                        "New critical PSIRT advisory",
                        $"{advisory.PsirtId}: {advisory.Title} (CVSS {advisory.CvssScore})",
                        null,
                        "Critical",
                        advisory.AdvisoryUrl), cancellationToken);
                }

                processed++;
            }

            await _db.SaveChangesAsync(cancellationToken);

            await CorrelateDevicesWithAdvisoriesAsync(cancellationToken);

            history.Status = SyncStatus.Succeeded;
            history.RecordsProcessed = processed;
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "PSIRT sync failed");
            history.Status = SyncStatus.Failed;
            history.ErrorMessage = ex.Message;
        }
        finally
        {
            history.CompletedAt = DateTimeOffset.UtcNow;
            await _db.SaveChangesAsync(cancellationToken);
        }

        return history;
    }

    private async Task CorrelateDevicesWithAdvisoriesAsync(CancellationToken cancellationToken)
    {
        var devices = await _db.Devices.ToListAsync(cancellationToken);
        var advisories = await _db.PsirtAdvisories.ToListAsync(cancellationToken);
        var existingLinks = await _db.DevicePsirts.ToListAsync(cancellationToken);
        var linkByKey = existingLinks.ToDictionary(l => (l.DeviceId, l.PsirtAdvisoryId));

        _logger.LogInformation($"Starting correlation: {devices.Count} devices, {advisories.Count} advisories, {existingLinks.Count} existing links");

        foreach (var device in devices)
        {
            // Skip devices with unknown firmware — cannot reliably evaluate whether they're affected
            // These devices likely don't have telemetry data or aren't in the supported region
            if (device.FirmwareVersion == "Unknown" || string.IsNullOrWhiteSpace(device.FirmwareVersion))
            {
                // Clean up any stale correlations for this device
                var staleLinks = existingLinks.Where(l => l.DeviceId == device.Id).ToList();
                foreach (var staleLink in staleLinks)
                {
                    _db.DevicePsirts.Remove(staleLink);
                    linkByKey.Remove((device.Id, staleLink.PsirtAdvisoryId));
                }
                continue;
            }

            foreach (var advisory in advisories)
            {
                // Skip advisories that appear to not be relevant to FortiGate (no affected version range)
                // These are typically Linux kernel or other non-FortiGate product advisories
                if (string.IsNullOrWhiteSpace(advisory.AffectedVersionRange))
                {
                    // Check if this advisory is already linked; if so, remove it to clean up old data
                    if (linkByKey.TryGetValue((device.Id, advisory.Id), out var existingStaleLink))
                    {
                        _db.DevicePsirts.Remove(existingStaleLink);
                        linkByKey.Remove((device.Id, advisory.Id));
                    }
                    continue;
                }

                var status = _psirtService.EvaluateAffectedStatus(device.FirmwareVersion, advisory.AffectedVersionRange, advisory.ParseStatus);

                if (status == Core.Models.FirmwareAffectedStatus.NotAffected)
                {
                    // Confirmed not affected — no row is persisted (same as before).
                    continue;
                }

                var correlationStatus = status == Core.Models.FirmwareAffectedStatus.Affected
                    ? PsirtCorrelationStatus.Affected
                    : PsirtCorrelationStatus.UnableToEvaluate;

                if (correlationStatus == PsirtCorrelationStatus.Affected)
                {
                    Observability.PsirtMetrics.CorrelationsAffected.Add(1);
                }
                else
                {
                    Observability.PsirtMetrics.CorrelationsUnableToEvaluate.Add(1);
                }

                if (linkByKey.TryGetValue((device.Id, advisory.Id), out var existingLink))
                {
                    // Re-evaluate: if the outcome changed since the last sync, keep the record current.
                    existingLink.CorrelationStatus = correlationStatus;
                    continue;
                }

                var newLink = new DevicePsirt
                {
                    Id = Guid.NewGuid(),
                    DeviceId = device.Id,
                    PsirtAdvisoryId = advisory.Id,
                    CorrelationStatus = correlationStatus,
                    DetectedAt = DateTimeOffset.UtcNow,
                    Resolved = false
                };
                _db.DevicePsirts.Add(newLink);
                linkByKey[(device.Id, advisory.Id)] = newLink;
                _logger.LogInformation($"Created correlation: Device {device.FirmwareVersion}, Advisory {advisory.PsirtId}, Status {correlationStatus}");

                // Only a confidently confirmed Critical match triggers an alert — an
                // "unable to evaluate" result must never be presented as an active vulnerability.
                if (correlationStatus == PsirtCorrelationStatus.Affected && advisory.Severity == PsirtSeverity.Critical)
                {
                    await _notificationService.PublishAsync(new NotificationEvent(
                        NotificationEventType.DeviceAffectedByCriticalCve,
                        "Device affected by critical PSIRT",
                        $"Device {device.Name} ({device.SerialNumber}) runs firmware {device.FirmwareVersion}, affected by {advisory.PsirtId}.",
                        device.SerialNumber,
                        "Critical",
                        advisory.AdvisoryUrl), cancellationToken);
                }
            }
        }

        await _db.SaveChangesAsync(cancellationToken);
    }
}
