using System.Net;
using System.Net.Http.Json;
using FortiGateDashboard.Core.Entities;
using FortiGateDashboard.Infrastructure.Data;
using FluentAssertions;
using Microsoft.Extensions.DependencyInjection;

namespace FortiGateDashboard.IntegrationTests;

public class PsirtUncertaintyApiTests : IClassFixture<ApiWebApplicationFactory>
{
    private readonly ApiWebApplicationFactory _factory;

    public PsirtUncertaintyApiTests(ApiWebApplicationFactory factory)
    {
        _factory = factory;
    }

    [Fact]
    public async Task PsirtEndpoint_ExposesUnknownParseStatus_AndDoesNotCountUnknownCorrelationAsAffected()
    {
        var client = _factory.CreateClient();
        client.DefaultRequestHeaders.Add(FortiGateDashboard.Api.Auth.TestAuthHandler.UserHeaderName, "psirt-api-test-user");

        using (var scope = _factory.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<FortiGateDashboardDbContext>();
            db.PsirtAdvisories.Add(new PsirtAdvisory
            {
                Id = Guid.NewGuid(),
                PsirtId = "FG-IR-25-001",
                Title = "Legacy unassessed advisory",
                AdvisoryUrl = "https://www.fortiguard.com/psirt/FG-IR-25-001",
                Severity = PsirtSeverity.Critical,
                CvssScore = 9.8,
                PublishedDate = DateOnly.FromDateTime(DateTime.UtcNow),
                AffectedVersionRange = "",
                ParseStatus = FortiGateDashboard.Core.Models.PsirtParseStatus.Unknown
            });
            await db.SaveChangesAsync();
        }

        var response = await client.GetAsync("/api/psirt");
        response.StatusCode.Should().Be(HttpStatusCode.OK);

        var json = await response.Content.ReadAsStringAsync();
        json.Should().Contain("Unknown");
        json.Should().Contain("affectedDeviceCount");
    }

    [Fact]
    public async Task DashboardEndpoint_ExposesUnresolvedEvaluationCountSeparately()
    {
        var client = _factory.CreateClient();
        client.DefaultRequestHeaders.Add(FortiGateDashboard.Api.Auth.TestAuthHandler.UserHeaderName, "dashboard-uncertainty-test-user");

        using (var scope = _factory.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<FortiGateDashboardDbContext>();
            var device = new Device
            {
                Id = Guid.NewGuid(),
                SerialNumber = "FGT-UNCERTAIN-001",
                Name = "uncertain-device",
                Model = "FortiGate",
                FirmwareVersion = "unknown",
                AccountId = "account"
            };
            var advisory = new PsirtAdvisory
            {
                Id = Guid.NewGuid(),
                PsirtId = "FG-IR-25-002",
                Title = "Uncertain advisory",
                AdvisoryUrl = "https://www.fortiguard.com/psirt/FG-IR-25-002",
                Severity = PsirtSeverity.Critical,
                AffectedVersionRange = "unknown",
                ParseStatus = FortiGateDashboard.Core.Models.PsirtParseStatus.PartiallyParsed
            };
            db.Devices.Add(device);
            db.PsirtAdvisories.Add(advisory);
            db.DevicePsirts.Add(new DevicePsirt
            {
                Id = Guid.NewGuid(),
                DeviceId = device.Id,
                PsirtAdvisoryId = advisory.Id,
                CorrelationStatus = PsirtCorrelationStatus.UnableToEvaluate
            });
            await db.SaveChangesAsync();
        }

        var response = await client.GetAsync("/api/dashboard");
        response.StatusCode.Should().Be(HttpStatusCode.OK);

        var json = await response.Content.ReadAsStringAsync();
        json.Should().Contain("devicesWithUnresolvedPsirtEvaluations");
        json.Should().Contain("devicesWithCriticalPsirts");
    }
}
