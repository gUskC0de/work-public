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

/// <summary>
/// Proves the Phase 1.1 safe-default/re-evaluation semantics: legacy rows are never presented
/// as confirmed-safe or confirmed-parsed, and a subsequent successful evaluation can promote
/// (or demote) a previously recorded correlation.
/// </summary>
public class PsirtSafetyTests
{
    private static FortiGateDashboardDbContext CreateDb()
    {
        var options = new DbContextOptionsBuilder<FortiGateDashboardDbContext>()
            .UseInMemoryDatabase(Guid.NewGuid().ToString())
            .Options;
        return new FortiGateDashboardDbContext(options);
    }

    [Fact]
    public void PsirtAdvisory_DefaultsTo_UnknownParseStatus()
    {
        // Simulates a legacy row migrated before parse-status tracking existed — the entity's
        // own default must never claim a successful parse it never actually performed.
        var advisory = new PsirtAdvisory { Id = Guid.NewGuid(), PsirtId = "FG-IR-20-999" };

        advisory.ParseStatus.Should().Be(PsirtParseStatus.Unknown);
    }

    [Fact]
    public void DevicePsirt_DefaultsTo_UnknownCorrelationStatus()
    {
        var link = new DevicePsirt { Id = Guid.NewGuid(), DeviceId = Guid.NewGuid(), PsirtAdvisoryId = Guid.NewGuid() };

        link.CorrelationStatus.Should().Be(PsirtCorrelationStatus.Unknown);
    }

    [Fact]
    public async Task CorrelateDevices_PromotesLegacyUnknownRow_WhenReEvaluationConfirmsAffected()
    {
        await using var db = CreateDb();

        var device = new Device
        {
            Id = Guid.NewGuid(),
            SerialNumber = "FGT60F1234567890",
            Name = "branch-fw-1",
            Model = "FortiGate 60F",
            FirmwareVersion = "7.0.5",
            AccountId = "acct-1"
        };
        var advisory = new PsirtAdvisory
        {
            Id = Guid.NewGuid(),
            PsirtId = "FG-IR-24-001",
            Title = "Legacy advisory",
            AdvisoryUrl = "https://www.fortiguard.com/psirt/FG-IR-24-001",
            Severity = PsirtSeverity.Critical,
            CvssScore = 9.8,
            AffectedVersionRange = "7.0.0 - 7.0.12",
            ParseStatus = PsirtParseStatus.Parsed
        };
        // A legacy row created before correlation-status tracking existed — still Unknown.
        var legacyLink = new DevicePsirt
        {
            Id = Guid.NewGuid(),
            DeviceId = device.Id,
            PsirtAdvisoryId = advisory.Id,
            CorrelationStatus = PsirtCorrelationStatus.Unknown
        };

        db.Devices.Add(device);
        db.PsirtAdvisories.Add(advisory);
        db.DevicePsirts.Add(legacyLink);
        await db.SaveChangesAsync();

        var psirtService = new Mock<IPsirtService>();
        psirtService.Setup(p => p.GetAdvisoriesAsync(It.IsAny<CancellationToken>())).ReturnsAsync(new List<PsirtRecord>());
        psirtService.Setup(p => p.EvaluateAffectedStatus(device.FirmwareVersion, advisory.AffectedVersionRange, advisory.ParseStatus))
            .Returns(FirmwareAffectedStatus.Affected);

        var sut = new SyncService(db, Mock.Of<IFortiGateCloudService>(), psirtService.Object, Mock.Of<INotificationService>(), NullLogger<SyncService>.Instance);

        await sut.SyncPsirtAsync();

        var updatedLink = await db.DevicePsirts.SingleAsync();
        updatedLink.CorrelationStatus.Should().Be(PsirtCorrelationStatus.Affected);
    }

    [Theory]
    [InlineData(PsirtParseStatus.Unparseable)]
    [InlineData(PsirtParseStatus.PartiallyParsed)]
    public void EvaluateAffectedStatus_NeverReturnsNotAffected_WhenAdvisoryCannotBeConfidentlyParsed(PsirtParseStatus parseStatus)
    {
        var sut = new FortiGateDashboard.Infrastructure.Psirt.PsirtService(
            new HttpClient(),
            Microsoft.Extensions.Options.Options.Create(new FortiGateDashboard.Core.Options.PsirtOptions()),
            NullLogger<FortiGateDashboard.Infrastructure.Psirt.PsirtService>.Instance);

        // Unrecognized grammar / unparseable advisory: must be UnableToEvaluate, never NotAffected
        // (a "not affected" result must only ever come from a confidently-parsed comparison).
        var result = sut.EvaluateAffectedStatus("7.0.5", "affects some devices, see advisory text", parseStatus);

        result.Should().Be(FirmwareAffectedStatus.UnableToEvaluate);
        result.Should().NotBe(FirmwareAffectedStatus.NotAffected);
    }
}
