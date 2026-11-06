using FortiGateDashboard.Core.Entities;
using FortiGateDashboard.Core.Interfaces;
using FortiGateDashboard.Core.Models;
using FortiGateDashboard.Infrastructure.Data;
using FortiGateDashboard.Infrastructure.Sync;
using FluentAssertions;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Logging.Abstractions;
using Moq;

namespace FortiGateDashboard.UnitTests.Sync;

public class SyncServiceTests
{
    private static FortiGateDashboardDbContext CreateDb()
    {
        var options = new DbContextOptionsBuilder<FortiGateDashboardDbContext>()
            .UseInMemoryDatabase(Guid.NewGuid().ToString())
            .Options;
        return new FortiGateDashboardDbContext(options);
    }

    [Fact]
    public async Task SyncDeviceInventoryAsync_AddsNewDevices()
    {
        await using var db = CreateDb();
        var cloudService = new Mock<IFortiGateCloudService>();
        cloudService.Setup(c => c.GetDevicesAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(new CloudFetchResult<CloudDeviceRecord>(
                new List<CloudDeviceRecord>
                {
                    new("FGT60F1234567890", "branch-fw-1", "FortiGate 60F", "7.4.4", "acct-1", "Acme Corp", true, true, DateTimeOffset.UtcNow)
                },
                IsPossiblyTruncated: false,
                TruncationReason: null));

        var sut = new SyncService(
            db,
            cloudService.Object,
            Mock.Of<IPsirtService>(),
            Mock.Of<INotificationService>(),
            NullLogger<SyncService>.Instance);

        var result = await sut.SyncDeviceInventoryAsync();

        result.Status.Should().Be(SyncStatus.Succeeded);
        result.RecordsProcessed.Should().Be(1);
        (await db.Devices.SingleAsync()).SerialNumber.Should().Be("FGT60F1234567890");
    }

    [Fact]
    public async Task SyncSubscriptionsAsync_CalculatesCriticalStatusAndNotifies()
    {
        await using var db = CreateDb();
        var device = new Device
        {
            Id = Guid.NewGuid(),
            SerialNumber = "FGT60F1234567890",
            Name = "branch-fw-1",
            Model = "FortiGate 60F",
            FirmwareVersion = "7.4.4",
            AccountId = "acct-1"
        };
        db.Devices.Add(device);
        await db.SaveChangesAsync();

        var cloudService = new Mock<IFortiGateCloudService>();
        cloudService.Setup(c => c.GetSubscriptionsAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(new CloudFetchResult<CloudSubscriptionRecord>(
                new List<CloudSubscriptionRecord>
                {
                    new(device.SerialNumber, "FortiGuard UTP", "UTP", DateOnly.FromDateTime(DateTime.UtcNow.AddDays(10)))
                },
                IsPossiblyTruncated: false,
                TruncationReason: null));

        var notificationService = new Mock<INotificationService>();

        var sut = new SyncService(
            db,
            cloudService.Object,
            Mock.Of<IPsirtService>(),
            notificationService.Object,
            NullLogger<SyncService>.Instance);

        var result = await sut.SyncSubscriptionsAsync();

        result.Status.Should().Be(SyncStatus.Succeeded);
        var subscription = await db.Subscriptions.SingleAsync();
        subscription.Status.Should().Be(SubscriptionStatus.Critical);
        notificationService.Verify(n => n.PublishAsync(
            It.Is<NotificationEvent>(e => e.Type == NotificationEventType.SubscriptionExpiringSoon),
            It.IsAny<CancellationToken>()), Times.Once);
    }

    [Fact]
    public async Task SyncDeviceInventoryAsync_MarksSyncPartiallySucceeded_WhenFetchIsPossiblyTruncated()
    {
        await using var db = CreateDb();
        var cloudService = new Mock<IFortiGateCloudService>();
        cloudService.Setup(c => c.GetDevicesAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(new CloudFetchResult<CloudDeviceRecord>(
                new List<CloudDeviceRecord>(),
                IsPossiblyTruncated: true,
                TruncationReason: "test-forced-truncation"));

        var sut = new SyncService(
            db,
            cloudService.Object,
            Mock.Of<IPsirtService>(),
            Mock.Of<INotificationService>(),
            NullLogger<SyncService>.Instance);

        var result = await sut.SyncDeviceInventoryAsync();

        // A possibly-truncated fetch must never be reported as a fully successful sync.
        result.Status.Should().Be(SyncStatus.PartiallySucceeded);
    }

    [Fact]
    public async Task SyncPsirtAsync_PersistsUnableToEvaluateCorrelation_InsteadOfSilentlyDroppingIt()
    {
        await using var db = CreateDb();
        var device = new Device
        {
            Id = Guid.NewGuid(),
            SerialNumber = "FGT60F1234567890",
            Name = "branch-fw-1",
            Model = "FortiGate 60F",
            FirmwareVersion = "7.4.4",
            AccountId = "acct-1"
        };
        db.Devices.Add(device);
        await db.SaveChangesAsync();

        var psirtService = new Mock<IPsirtService>();
        psirtService.Setup(p => p.GetAdvisoriesAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(new List<PsirtRecord>
            {
                new("FG-IR-24-001", "Test advisory", "https://www.fortiguard.com/psirt/FG-IR-24-001", "Critical", 9.8,
                    DateOnly.FromDateTime(DateTime.UtcNow), "affects multiple product families, see advisory text",
                    new List<CveRecord> { new("CVE-2024-0001", null, 9.8) }, PsirtParseStatus.PartiallyParsed)
            });
        psirtService.Setup(p => p.EvaluateAffectedStatus(It.IsAny<string>(), It.IsAny<string>(), It.IsAny<PsirtParseStatus>()))
            .Returns(FirmwareAffectedStatus.UnableToEvaluate);

        var sut = new SyncService(
            db,
            Mock.Of<IFortiGateCloudService>(),
            psirtService.Object,
            Mock.Of<INotificationService>(),
            NullLogger<SyncService>.Instance);

        await sut.SyncPsirtAsync();

        var link = await db.DevicePsirts.SingleAsync();
        link.CorrelationStatus.Should().Be(PsirtCorrelationStatus.UnableToEvaluate);
    }
}
