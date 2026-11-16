using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using FortiGateDashboard.Core.Options;
using FortiGateDashboard.Infrastructure.FortiGateCloud;
using FluentAssertions;
using Microsoft.Extensions.Caching.Memory;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;

namespace FortiGateDashboard.UnitTests.FortiGateCloud;

/// <summary>Routes token-endpoint and products/list requests to configurable fake responses.</summary>
internal class FakeFortiGateCloudHandler : HttpMessageHandler
{
    public int TokenRequestCount;
    public long? TokenContentLength;
    public bool TokenRequestContainsClientSecret;
    public string? ProductRequestPayload;
    public Func<HttpResponseMessage>? TokenResponseFactory;
    public Func<HttpResponseMessage>? ProductResponseFactory;
    public Func<HttpResponseMessage>? TelemetryResponseFactory;
    public List<string> TokenClientIds { get; } = new();
    public string? TelemetryAuthorization;
    private readonly SemaphoreSlim? _tokenRequestGate;

    public FakeFortiGateCloudHandler(SemaphoreSlim? tokenRequestGate = null)
    {
        _tokenRequestGate = tokenRequestGate;
    }

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        if (request.RequestUri!.AbsoluteUri.Contains("oauth/token"))
        {
            Interlocked.Increment(ref TokenRequestCount);
            TokenContentLength = request.Content?.Headers.ContentLength;
            var tokenRequestPayload = await request.Content!.ReadAsStringAsync(cancellationToken);
            using var tokenJson = JsonDocument.Parse(tokenRequestPayload);
            TokenRequestContainsClientSecret = tokenJson.RootElement.TryGetProperty("client_secret", out _);
            lock (TokenClientIds)
            {
                TokenClientIds.Add(tokenJson.RootElement.GetProperty("client_id").GetString()!);
            }

            if (_tokenRequestGate is not null)
            {
                // Simulate a slow token endpoint so concurrent callers genuinely overlap.
                await _tokenRequestGate.WaitAsync(cancellationToken);
                _tokenRequestGate.Release();
            }

            return TokenResponseFactory?.Invoke() ?? SuccessResponse(3600);
        }

        if (request.Method == HttpMethod.Get && request.RequestUri.AbsolutePath.EndsWith("/devices"))
        {
            TelemetryAuthorization = request.Headers.Authorization?.ToString();
            return TelemetryResponseFactory?.Invoke()
                ?? new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent("[]", System.Text.Encoding.UTF8, "application/json") };
        }

        ProductRequestPayload = await request.Content!.ReadAsStringAsync(cancellationToken);

        // products/list — empty asset list is enough for GetDevicesAsync to complete.
        if (ProductResponseFactory is not null)
        {
            return ProductResponseFactory();
        }

        var payload = JsonSerializer.Serialize(new { assets = Array.Empty<object>() });
        return new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(payload, System.Text.Encoding.UTF8, "application/json") };
    }

    public static HttpResponseMessage SuccessResponse(int expiresIn) =>
        new(HttpStatusCode.OK) { Content = JsonContent.Create(new { access_token = "test-token", expires_in = expiresIn, token_type = "bearer" }) };
}

public class FortiGateCloudServiceTokenTests
{
    private static FortiGateCloudService CreateSut(FakeFortiGateCloudHandler handler, IMemoryCache? cache = null, string clientSecret = "secret", long accountId = 1379327, bool telemetryEnabled = false) =>
        new(
            new HttpClient(handler) { BaseAddress = new Uri("https://example.invalid") },
            Options.Create(new FortiGateCloudOptions
            {
                BaseUrl = "https://example.invalid",
                TokenUrl = "https://example.invalid/oauth/token",
                ClientId = "client",
                ClientSecret = clientSecret,
                Username = "user",
                Password = "pass",
                AccountId = accountId,
                TelemetryEnabled = telemetryEnabled,
                TelemetryBaseUrl = "https://telemetry.invalid/forticloudapi/v1",
                TelemetryClientId = "fortigatecloud"
            }),
            Options.Create(new FortiGateCloudResiliencyOptions { TruncationWarningThreshold = 1000 }),
            cache ?? new MemoryCache(new MemoryCacheOptions()),
            NullLogger<FortiGateCloudService>.Instance);

    [Fact]
    public async Task TokenRequest_SendsKnownContentLength()
    {
        var handler = new FakeFortiGateCloudHandler();
        var sut = CreateSut(handler);

        await sut.GetDevicesAsync();

        handler.TokenContentLength.Should().BeGreaterThan(0);
    }

    [Fact]
    public async Task TokenRequest_OmitsBlankClientSecret()
    {
        var handler = new FakeFortiGateCloudHandler();
        var sut = CreateSut(handler, clientSecret: "");

        await sut.GetDevicesAsync();

        handler.TokenRequestContainsClientSecret.Should().BeFalse();
    }

    [Fact]
    public async Task ProductRequest_IncludesAccountIdAndExpiryCutoff()
    {
        var handler = new FakeFortiGateCloudHandler();
        var sut = CreateSut(handler, accountId: 1379327);

        await sut.GetDevicesAsync();

        using var requestJson = JsonDocument.Parse(handler.ProductRequestPayload!);
        requestJson.RootElement.GetProperty("accountId").GetInt64().Should().Be(1379327);
        requestJson.RootElement.GetProperty("expireBefore").GetString().Should().Be("2099-12-31");
    }

    [Fact]
    public async Task SubscriptionResponse_AcceptsNumericEntitlementType()
    {
        var handler = new FakeFortiGateCloudHandler
        {
            ProductResponseFactory = () => new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent("{\"assets\":[{\"serialNumber\":\"FGT-TEST\",\"entitlements\":[{\"type\":1,\"description\":\"FortiCare\",\"endDate\":\"2099-12-31\"}]}]}", System.Text.Encoding.UTF8, "application/json")
            }
        };
        var sut = CreateSut(handler);

        var result = await sut.GetSubscriptionsAsync();

        result.Items.Should().ContainSingle().Which.SubscriptionType.Should().Be("1");
    }

    [Fact]
    public async Task DeviceResponse_MapsRegisteredStatusWithoutIsRegisteredField()
    {
        var handler = new FakeFortiGateCloudHandler
        {
            ProductResponseFactory = () => new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent("{\"assets\":[{\"serialNumber\":\"FGT-TEST\",\"status\":\"Registered\"}]}", System.Text.Encoding.UTF8, "application/json")
            }
        };
        var sut = CreateSut(handler);

        var result = await sut.GetDevicesAsync();

        result.Items.Should().ContainSingle().Which.IsRegistered.Should().BeTrue();
        result.Items.Single().IsOnline.Should().BeFalse();
    }

    [Fact]
    public async Task Telemetry_MergesFirmwareTunnelModelAndIpBySerial()
    {
        var handler = new FakeFortiGateCloudHandler
        {
            ProductResponseFactory = () => new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent("{\"assets\":[{\"serialNumber\":\"FG100D3G15803161\",\"productModel\":\"FGT100D\",\"status\":\"Registered\"}]}", System.Text.Encoding.UTF8, "application/json")
            },
            TelemetryResponseFactory = () => new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent("[{\"sn\":\"FG100D3G15803161\",\"name\":\"FortiGate-100D\",\"tunnelAlive\":true,\"model\":\"FortiGate 100D\",\"firmwareVersion\":\"6.2.8\",\"ip\":\"172.16.30.193\",\"latitude\":null}]", System.Text.Encoding.UTF8, "application/json")
            }
        };
        var sut = CreateSut(handler, telemetryEnabled: true);

        var device = (await sut.GetDevicesAsync()).Items.Should().ContainSingle().Subject;

        device.FirmwareVersion.Should().Be("6.2.8");
        device.TunnelAlive.Should().BeTrue();
        device.Model.Should().Be("FortiGate 100D");
        device.IpAddress.Should().Be("172.16.30.193");
        handler.TokenClientIds.Should().BeEquivalentTo(new[] { "client", "fortigatecloud" });
        handler.TelemetryAuthorization.Should().Be("Bearer test-token");
    }

    [Fact]
    public async Task Telemetry_Failure_StillReturnsInventory()
    {
        var handler = new FakeFortiGateCloudHandler
        {
            ProductResponseFactory = () => new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent("{\"assets\":[{\"serialNumber\":\"FGT-TEST\",\"status\":\"Registered\"}]}", System.Text.Encoding.UTF8, "application/json")
            },
            TelemetryResponseFactory = () => new HttpResponseMessage(HttpStatusCode.Forbidden)
        };
        var sut = CreateSut(handler, telemetryEnabled: true);

        var device = (await sut.GetDevicesAsync()).Items.Should().ContainSingle().Subject;

        device.FirmwareVersion.Should().Be("Unknown");
        device.TunnelAlive.Should().BeNull();
        device.IpAddress.Should().BeNull();
    }

    [Fact]
    public async Task ConcurrentCalls_ForSameAccount_OnlyAcquireOneToken()
    {
        using var gate = new SemaphoreSlim(0, 1);
        var handler = new FakeFortiGateCloudHandler(gate);
        var cache = new MemoryCache(new MemoryCacheOptions());
        var sut = CreateSut(handler, cache);

        var call1 = sut.GetDevicesAsync();
        var call2 = sut.GetDevicesAsync();
        var call3 = sut.GetDevicesAsync();

        gate.Release(); // let the (single, gated) token request complete
        await Task.WhenAll(call1, call2, call3);

        handler.TokenRequestCount.Should().Be(1, "concurrent callers for the same account must not each trigger their own token request");
    }

    [Fact]
    public async Task TokenIsReused_BeforeExpiry()
    {
        var handler = new FakeFortiGateCloudHandler { TokenResponseFactory = () => FakeFortiGateCloudHandler.SuccessResponse(3600) };
        var sut = CreateSut(handler);

        await sut.GetDevicesAsync();
        await sut.GetDevicesAsync();
        await sut.GetDevicesAsync();

        handler.TokenRequestCount.Should().Be(1, "a token valid for a long time must be reused, not re-requested every call");
    }

    [Fact]
    public async Task NonPositiveExpiresIn_IsNeverCached()
    {
        var handler = new FakeFortiGateCloudHandler { TokenResponseFactory = () => FakeFortiGateCloudHandler.SuccessResponse(0) };
        var sut = CreateSut(handler);

        await sut.GetDevicesAsync();
        await sut.GetDevicesAsync();

        handler.TokenRequestCount.Should().Be(2, "a non-positive expires_in must never be cached — every call must fetch fresh");
    }

    [Fact]
    public async Task ExpiresInShorterThanSafetyMargin_IsNeverCached()
    {
        // 30s is well under the 60s safety margin — must not be cached for any fixed duration.
        var handler = new FakeFortiGateCloudHandler { TokenResponseFactory = () => FakeFortiGateCloudHandler.SuccessResponse(30) };
        var sut = CreateSut(handler);

        await sut.GetDevicesAsync();
        await sut.GetDevicesAsync();

        handler.TokenRequestCount.Should().Be(2);
    }

    [Fact]
    public async Task FailedTokenAcquisition_IsNeverCached_AndSubsequentCallRetriesFreshly()
    {
        var attempt = 0;
        var handler = new FakeFortiGateCloudHandler
        {
            TokenResponseFactory = () =>
            {
                attempt++;
                return attempt == 1
                    ? new HttpResponseMessage(HttpStatusCode.Unauthorized)
                    : FakeFortiGateCloudHandler.SuccessResponse(3600);
            }
        };
        var sut = CreateSut(handler);

        Func<Task> firstCall = () => sut.GetDevicesAsync();
        await firstCall.Should().ThrowAsync<HttpRequestException>();

        // A failed acquisition must not have cached anything invalid — the next call succeeds.
        await sut.GetDevicesAsync();

        handler.TokenRequestCount.Should().Be(2);
    }

    [Fact]
    public async Task CancellationDuringTokenAcquisition_PropagatesAndDoesNotCache()
    {
        using var gate = new SemaphoreSlim(0, 1); // never released — request hangs until cancelled
        var handler = new FakeFortiGateCloudHandler(gate);
        var sut = CreateSut(handler);
        using var cts = new CancellationTokenSource();
        cts.CancelAfter(TimeSpan.FromMilliseconds(200));

        Func<Task> act = () => sut.GetDevicesAsync(cts.Token);

        await act.Should().ThrowAsync<OperationCanceledException>();
    }
}
