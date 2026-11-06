using System.Net;
using FortiGateDashboard.Api.Auth;
using FortiGateDashboard.Core.Entities;
using FortiGateDashboard.Infrastructure.Data;
using FluentAssertions;
using Microsoft.Extensions.DependencyInjection;

namespace FortiGateDashboard.IntegrationTests;

public class CloudConnectionStatusTests : IClassFixture<ApiWebApplicationFactory>
{
    private readonly ApiWebApplicationFactory _factory;

    public CloudConnectionStatusTests(ApiWebApplicationFactory factory)
    {
        _factory = factory;
    }

    [Fact]
    public async Task ConnectionStatus_ReportsMissingSettingsAndDoesNotReturnSecretValues()
    {
        var client = _factory.CreateClient();
        client.DefaultRequestHeaders.Add(TestAuthHandler.UserHeaderName, "connection-status-test");

        var response = await client.GetAsync("/api/dashboard/connection");

        response.StatusCode.Should().Be(HttpStatusCode.OK);
        var body = await response.Content.ReadAsStringAsync();
        body.Should().Contain("credentialsConfigured");
        body.Should().Contain("Client ID");
        body.Should().Contain("Username");
        body.Should().Contain("Password");
        body.Should().Contain("Account ID");
        body.Should().NotContain("access_token");
        body.Should().NotContain("client_secret");
    }

    [Fact]
    public async Task ConnectionStatus_ReportsLatestSyncOutcomesByStage()
    {
        using (var scope = _factory.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<FortiGateDashboardDbContext>();
            db.SyncHistories.AddRange(
                new SyncHistory
                {
                    Id = Guid.NewGuid(),
                    SyncType = SyncType.DeviceInventory,
                    Status = SyncStatus.Failed,
                    StartedAt = DateTimeOffset.UtcNow.AddMinutes(-10),
                    CompletedAt = DateTimeOffset.UtcNow.AddMinutes(-9),
                    ErrorMessage = "Do not expose arbitrary upstream error text"
                },
                new SyncHistory
                {
                    Id = Guid.NewGuid(),
                    SyncType = SyncType.DeviceInventory,
                    Status = SyncStatus.Succeeded,
                    StartedAt = DateTimeOffset.UtcNow.AddMinutes(-2),
                    CompletedAt = DateTimeOffset.UtcNow.AddMinutes(-1),
                    RecordsProcessed = 17
                });
            await db.SaveChangesAsync();
        }

        var client = _factory.CreateClient();
        client.DefaultRequestHeaders.Add(TestAuthHandler.UserHeaderName, "connection-status-latest-sync");
        var response = await client.GetAsync("/api/dashboard/connection");

        response.StatusCode.Should().Be(HttpStatusCode.OK);
        var body = await response.Content.ReadAsStringAsync();
        body.Should().Contain("Succeeded");
        body.Should().Contain("17");
        body.Should().NotContain("Do not expose arbitrary upstream error text");
    }
}
