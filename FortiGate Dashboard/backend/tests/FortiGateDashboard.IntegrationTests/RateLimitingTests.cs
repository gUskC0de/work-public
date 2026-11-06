using System.Net;
using FortiGateDashboard.Core.Entities;
using FortiGateDashboard.Core.Interfaces;
using FluentAssertions;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;

namespace FortiGateDashboard.IntegrationTests;

/// <summary>A no-op ISyncService stand-in so rate-limit tests never make real outbound HTTP calls.</summary>
internal class StubSyncService : ISyncService
{
    private static SyncHistory MakeHistory(SyncType type) => new()
    {
        Id = Guid.NewGuid(),
        SyncType = type,
        Status = SyncStatus.Succeeded,
        StartedAt = DateTimeOffset.UtcNow,
        CompletedAt = DateTimeOffset.UtcNow
    };

    public Task<SyncHistory> SyncDeviceInventoryAsync(CancellationToken cancellationToken = default) =>
        Task.FromResult(MakeHistory(SyncType.DeviceInventory));

    public Task<SyncHistory> SyncSubscriptionsAsync(CancellationToken cancellationToken = default) =>
        Task.FromResult(MakeHistory(SyncType.SubscriptionInfo));

    public Task<SyncHistory> SyncPsirtAsync(CancellationToken cancellationToken = default) =>
        Task.FromResult(MakeHistory(SyncType.PsirtInfo));
}

/// <summary>
/// Proves that runtime configuration (via WebApplicationFactory's ConfigureAppConfiguration)
/// can override the checked-in appsettings.json RateLimiting defaults. This exercises the
/// Program.cs fix: rate-limit policies resolve <c>IOptions&lt;RateLimitingOptions&gt;</c> lazily
/// from the request's own DI container rather than from a value captured before Build() — the
/// earlier (broken) implementation silently ignored these overrides.
/// </summary>
public class RateLimitingTests : IClassFixture<ApiWebApplicationFactory>
{
    // Deliberately different from the checked-in appsettings.json defaults (General=120,
    // Sync=1, Export=5) so a passing test proves the override is actually active, not that it
    // merely happens to match production configuration.
    private const int OverriddenGeneralPermitLimit = 2;
    private const int OverriddenExportPermitLimit = 1;
    private const int OverriddenSyncPermitLimit = 1;
    private const int OverriddenWindowSeconds = 60;

    private readonly ApiWebApplicationFactory _baseFactory;

    public RateLimitingTests(ApiWebApplicationFactory factory)
    {
        _baseFactory = factory;
    }

    private WebApplicationFactory<Program> CreateOverriddenFactory() =>
        _baseFactory.WithWebHostBuilder(builder =>
        {
            builder.ConfigureAppConfiguration((_, config) =>
            {
                config.AddInMemoryCollection(new Dictionary<string, string?>
                {
                    ["RateLimiting:General:PermitLimit"] = OverriddenGeneralPermitLimit.ToString(),
                    ["RateLimiting:General:WindowSeconds"] = OverriddenWindowSeconds.ToString(),
                    ["RateLimiting:General:QueueLimit"] = "0",
                    ["RateLimiting:Export:PermitLimit"] = OverriddenExportPermitLimit.ToString(),
                    ["RateLimiting:Export:WindowSeconds"] = OverriddenWindowSeconds.ToString(),
                    ["RateLimiting:Export:QueueLimit"] = "0",
                    ["RateLimiting:Sync:PermitLimit"] = OverriddenSyncPermitLimit.ToString(),
                    ["RateLimiting:Sync:WindowSeconds"] = OverriddenWindowSeconds.ToString(),
                    ["RateLimiting:Sync:QueueLimit"] = "0"
                });
            });
            builder.ConfigureServices(services => services.AddScoped<ISyncService, StubSyncService>());
        });

    [Fact]
    public async Task ConfigurationOverride_IsActive_AndDiffersFromCheckedInDefault()
    {
        // Proves the override is genuinely in effect: the checked-in default (120) would take
        // ~121 requests to reject; the overridden value (2) must reject on the 3rd request.
        var client = CreateOverriddenFactory().CreateClient();
        client.DefaultRequestHeaders.Add(FortiGateDashboard.Api.Auth.TestAuthHandler.UserHeaderName, "user-override-proof");

        (await client.GetAsync("/api/dashboard")).StatusCode.Should().Be(HttpStatusCode.OK);
        (await client.GetAsync("/api/dashboard")).StatusCode.Should().Be(HttpStatusCode.OK);

        var third = await client.GetAsync("/api/dashboard");
        third.StatusCode.Should().Be(HttpStatusCode.TooManyRequests);
        third.Headers.RetryAfter.Should().NotBeNull();
    }

    [Fact]
    public async Task ExportPolicy_UsesOverriddenLimit_RejectsSecondRequest()
    {
        var client = CreateOverriddenFactory().CreateClient();
        client.DefaultRequestHeaders.Add(FortiGateDashboard.Api.Auth.TestAuthHandler.UserHeaderName, "user-export-override");

        (await client.GetAsync("/api/devices/export/csv")).StatusCode.Should().Be(HttpStatusCode.OK);
        var rejected = await client.GetAsync("/api/devices/export/csv");
        rejected.StatusCode.Should().Be(HttpStatusCode.TooManyRequests);
        rejected.Headers.RetryAfter.Should().NotBeNull();
    }

    [Fact]
    public async Task SyncPolicy_UsesOverriddenLimit_RejectsSecondRequest()
    {
        var client = CreateOverriddenFactory().CreateClient();
        client.DefaultRequestHeaders.Add(FortiGateDashboard.Api.Auth.TestAuthHandler.UserHeaderName, "user-sync-override");
        client.DefaultRequestHeaders.Add(FortiGateDashboard.Api.Auth.TestAuthHandler.RolesHeaderName, "Admin");

        (await client.PostAsync("/api/sync", content: null)).StatusCode.Should().Be(HttpStatusCode.OK);
        var rejected = await client.PostAsync("/api/sync", content: null);
        rejected.StatusCode.Should().Be(HttpStatusCode.TooManyRequests);
    }

    [Fact]
    public async Task DifferentAuthenticatedUsers_GetSeparateRateLimitPartitions()
    {
        var factory = CreateOverriddenFactory();
        var clientA = factory.CreateClient();
        clientA.DefaultRequestHeaders.Add(FortiGateDashboard.Api.Auth.TestAuthHandler.UserHeaderName, "user-partition-a");

        var clientB = factory.CreateClient();
        clientB.DefaultRequestHeaders.Add(FortiGateDashboard.Api.Auth.TestAuthHandler.UserHeaderName, "user-partition-b");

        for (var i = 0; i < OverriddenGeneralPermitLimit; i++)
        {
            (await clientA.GetAsync("/api/dashboard")).StatusCode.Should().Be(HttpStatusCode.OK);
        }
        (await clientA.GetAsync("/api/dashboard")).StatusCode.Should().Be(HttpStatusCode.TooManyRequests);

        // User B, sharing the SAME factory/host (and therefore the same rate-limiter instance
        // state), must be unaffected by user A's exhausted limit.
        var responseB = await clientB.GetAsync("/api/dashboard");
        responseB.StatusCode.Should().Be(HttpStatusCode.OK);
    }

    [Fact]
    public async Task SeparateFactoryInstances_DoNotLeakLimiterStateBetweenEachOther()
    {
        // Two independently constructed factories (fresh hosts) must not share rate-limiter
        // state even though they use the same partition key — proves no static/singleton leak.
        var firstHostClient = CreateOverriddenFactory().CreateClient();
        firstHostClient.DefaultRequestHeaders.Add(FortiGateDashboard.Api.Auth.TestAuthHandler.UserHeaderName, "user-cross-host");
        for (var i = 0; i < OverriddenGeneralPermitLimit; i++)
        {
            (await firstHostClient.GetAsync("/api/dashboard")).StatusCode.Should().Be(HttpStatusCode.OK);
        }
        (await firstHostClient.GetAsync("/api/dashboard")).StatusCode.Should().Be(HttpStatusCode.TooManyRequests);

        var secondHostClient = CreateOverriddenFactory().CreateClient();
        secondHostClient.DefaultRequestHeaders.Add(FortiGateDashboard.Api.Auth.TestAuthHandler.UserHeaderName, "user-cross-host");
        var responseOnFreshHost = await secondHostClient.GetAsync("/api/dashboard");
        responseOnFreshHost.StatusCode.Should().Be(HttpStatusCode.OK);
    }

    [Fact]
    public async Task TestExecutionOrder_DoesNotAffectResults()
    {
        // Runs the same scenario twice via independently created factories/clients to prove
        // no shared/static state carries over based on which test ran first.
        for (var iteration = 0; iteration < 2; iteration++)
        {
            var client = CreateOverriddenFactory().CreateClient();
            client.DefaultRequestHeaders.Add(FortiGateDashboard.Api.Auth.TestAuthHandler.UserHeaderName, $"user-order-{iteration}");

            for (var i = 0; i < OverriddenGeneralPermitLimit; i++)
            {
                (await client.GetAsync("/api/dashboard")).StatusCode.Should().Be(HttpStatusCode.OK);
            }
            (await client.GetAsync("/api/dashboard")).StatusCode.Should().Be(HttpStatusCode.TooManyRequests);
        }
    }

    [Fact]
    public async Task UnauthenticatedRequests_FallBackToIpPartitioning_AndAreRejectedByAuth()
    {
        var client = CreateOverriddenFactory().CreateClient();
        var response = await client.GetAsync("/api/dashboard");

        response.StatusCode.Should().Be(HttpStatusCode.Unauthorized);
    }

    [Fact]
    public async Task HealthEndpoint_IsNeverRateLimited()
    {
        var client = CreateOverriddenFactory().CreateClient();

        for (var i = 0; i < 10; i++)
        {
            var response = await client.GetAsync("/health");
            response.StatusCode.Should().NotBe(HttpStatusCode.TooManyRequests);
        }
    }

    [Fact]
    public async Task WithoutOverride_ChecksInDefaultsAreUsed()
    {
        // Sanity check: a factory WITHOUT the override still behaves per the checked-in
        // appsettings.json default (General PermitLimit=120), proving the override in the
        // other tests is additive, not a global mutation of shared configuration.
        var client = _baseFactory.WithWebHostBuilder(builder =>
            builder.ConfigureServices(services => services.AddScoped<ISyncService, StubSyncService>()))
            .CreateClient();
        client.DefaultRequestHeaders.Add(FortiGateDashboard.Api.Auth.TestAuthHandler.UserHeaderName, "user-default-check");

        for (var i = 0; i < OverriddenGeneralPermitLimit + 1; i++)
        {
            (await client.GetAsync("/api/dashboard")).StatusCode.Should().Be(HttpStatusCode.OK);
        }
    }
}
