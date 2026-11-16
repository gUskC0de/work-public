using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using System.Text.Json.Serialization;
using FortiGateDashboard.Core.Interfaces;
using FortiGateDashboard.Core.Models;
using FortiGateDashboard.Core.Options;
using Microsoft.Extensions.Caching.Memory;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace FortiGateDashboard.Infrastructure.FortiGateCloud;

/// <summary>
/// FortiGate Cloud (FortiCare/FortiCloud) REST API client. Handles OAuth2 password-grant
/// token acquisition and automatic refresh, caching the access token in memory.
/// </summary>
/// <remarks>
/// Pagination: NOT VERIFIED against FortiGate Cloud API documentation or captured fixtures.
/// A single request is made per fetch; if the response size crosses
/// <see cref="FortiGateCloudResiliencyOptions.TruncationWarningThreshold"/>, the result is
/// flagged via <see cref="CloudFetchResult{T}.IsPossiblyTruncated"/> rather than silently
/// treated as a complete dataset. Multi-account support (single logical account today,
/// identified as "primary" for token-cache/log-scope purposes) is prepared but not yet wired
/// to <see cref="FortiGateCloudOptions.AdditionalAccounts"/> — see Phase 3 of the remediation plan.
/// </remarks>
public class FortiGateCloudService : IFortiGateCloudService
{
    private const string PrimaryAccountLabel = "primary";
    private const string TokenCacheKeyPrefix = "forticloud_access_token_";
    private const string InventoryExpiryCutoff = "2099-12-31";

    private readonly HttpClient _httpClient;
    private readonly FortiGateCloudOptions _options;
    private readonly FortiGateCloudResiliencyOptions _resiliencyOptions;
    private readonly IMemoryCache _cache;
    private readonly ILogger<FortiGateCloudService> _logger;

    public FortiGateCloudService(
        HttpClient httpClient,
        IOptions<FortiGateCloudOptions> options,
        IOptions<FortiGateCloudResiliencyOptions> resiliencyOptions,
        IMemoryCache cache,
        ILogger<FortiGateCloudService> logger)
    {
        _httpClient = httpClient;
        _options = options.Value;
        _resiliencyOptions = resiliencyOptions.Value;
        _cache = cache;
        _logger = logger;
    }

    public async Task<CloudFetchResult<CloudDeviceRecord>> GetDevicesAsync(CancellationToken cancellationToken = default)
    {
        using var scope = _logger.BeginScope(new Dictionary<string, object> { ["FortiGateCloudAccount"] = PrimaryAccountLabel });

        var token = await GetAccessTokenAsync(cancellationToken);

        using var request = new HttpRequestMessage(HttpMethod.Post, $"{_options.BaseUrl}/products/list");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        request.Content = JsonContent.Create(new { accountId = _options.AccountId, expireBefore = InventoryExpiryCutoff });

        using var response = await _httpClient.SendAsync(request, cancellationToken);
        response.EnsureSuccessStatusCode();

        var payload = await response.Content.ReadFromJsonAsync<FortiGateProductListResponse>(cancellationToken: cancellationToken);
        var assets = payload?.Assets ?? new List<FortiGateAsset>();

        _logger.LogInformation("Fetched {Count} devices from FortiGate Cloud", assets.Count);

        var telemetry = await GetTelemetryBySerialAsync(cancellationToken);

        var records = assets.Select(a =>
        {
            telemetry.TryGetValue(a.SerialNumber, out var live);
            return new CloudDeviceRecord(
                SerialNumber: a.SerialNumber,
                Name: string.IsNullOrWhiteSpace(a.Description) ? a.SerialNumber : a.Description,
                Model: NonBlank(live?.Model) ?? a.ProductModel ?? "Unknown",
                FirmwareVersion: NonBlank(live?.FirmwareVersion) ?? a.FirmwareVersion ?? "Unknown",
                AccountId: _options.ClientId,
                AccountName: null,
                IsOnline: string.Equals(a.Status, "Online", StringComparison.OrdinalIgnoreCase),
                IsRegistered: a.IsRegistered || string.Equals(a.Status, "Registered", StringComparison.OrdinalIgnoreCase),
                LastSeenAt: a.LastSeen,
                TunnelAlive: live?.TunnelAlive,
                IpAddress: NonBlank(live?.Ip),
                Hostname: NonBlank(live?.Hostname));
        })
            // Deduplicate on (account, serial) — a real pagination contract could otherwise
            // return the same asset twice across pages once genuine pagination is implemented.
            .GroupBy(r => (r.AccountId, r.SerialNumber))
            .Select(g => g.First())
            .ToList();

        return BuildFetchResult(records, "GetDevices");
    }

    public async Task<CloudFetchResult<CloudSubscriptionRecord>> GetSubscriptionsAsync(CancellationToken cancellationToken = default)
    {
        using var scope = _logger.BeginScope(new Dictionary<string, object> { ["FortiGateCloudAccount"] = PrimaryAccountLabel });

        var token = await GetAccessTokenAsync(cancellationToken);

        using var request = new HttpRequestMessage(HttpMethod.Post, $"{_options.BaseUrl}/products/list");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        request.Content = JsonContent.Create(new { accountId = _options.AccountId, expireBefore = InventoryExpiryCutoff });

        using var response = await _httpClient.SendAsync(request, cancellationToken);
        response.EnsureSuccessStatusCode();

        var payload = await response.Content.ReadFromJsonAsync<FortiGateProductListResponse>(cancellationToken: cancellationToken);
        var assets = payload?.Assets ?? new List<FortiGateAsset>();

        var records = new List<CloudSubscriptionRecord>();
        foreach (var asset in assets)
        {
            foreach (var entitlement in asset.Entitlements ?? new List<FortiGateEntitlement>())
            {
                if (!DateOnly.TryParse(entitlement.EndDate, out var expiry))
                {
                    continue;
                }

                records.Add(new CloudSubscriptionRecord(
                    DeviceSerialNumber: asset.SerialNumber,
                    SubscriptionName: entitlement.Description ?? entitlement.LevelDescription ?? "Subscription",
                    SubscriptionType: entitlement.Type ?? "Unknown",
                    ExpiryDate: expiry));
            }
        }

        _logger.LogInformation("Fetched {Count} subscriptions from FortiGate Cloud", records.Count);
        return BuildFetchResult(records, "GetSubscriptions");
    }

    /// <summary>
    /// Live FortiGate Cloud device data (firmware, tunnel, IP). Best-effort: inventory sync
    /// must still succeed when telemetry is unavailable or the IAM user lacks FortiGate access.
    /// </summary>
    private async Task<Dictionary<string, FortiGateCloudDevice>> GetTelemetryBySerialAsync(CancellationToken cancellationToken)
    {
        var empty = new Dictionary<string, FortiGateCloudDevice>(StringComparer.OrdinalIgnoreCase);
        if (!_options.TelemetryEnabled)
        {
            return empty;
        }

        try
        {
            var token = await GetAccessTokenAsync(_options.TelemetryClientId, cancellationToken);

            using var request = new HttpRequestMessage(HttpMethod.Get, $"{_options.TelemetryBaseUrl.TrimEnd('/')}/devices");
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);

            using var response = await _httpClient.SendAsync(request, cancellationToken);
            if (!response.IsSuccessStatusCode)
            {
                _logger.LogWarning("FortiGate Cloud telemetry request failed with status {StatusCode}", (int)response.StatusCode);
                return empty;
            }

            var devices = await response.Content.ReadFromJsonAsync<List<FortiGateCloudDevice>>(cancellationToken: cancellationToken)
                ?? new List<FortiGateCloudDevice>();

            foreach (var device in devices.Where(d => !string.IsNullOrWhiteSpace(d.Sn)))
            {
                empty.TryAdd(device.Sn!, device);
            }

            _logger.LogInformation("Fetched telemetry for {Count} devices from FortiGate Cloud", empty.Count);
            return empty;
        }
        catch (Exception ex) when (ex is HttpRequestException or JsonException or NotSupportedException)
        {
            _logger.LogWarning(ex, "FortiGate Cloud telemetry unavailable; continuing with inventory data only");
            return empty;
        }
    }

    private static string? NonBlank(string? value) => string.IsNullOrWhiteSpace(value) ? null : value.Trim();

    private CloudFetchResult<T> BuildFetchResult<T>(List<T> records, string operationName)
    {
        if (records.Count < _resiliencyOptions.TruncationWarningThreshold)
        {
            return new CloudFetchResult<T>(records, IsPossiblyTruncated: false, TruncationReason: null);
        }

        var reason = $"{operationName} returned {records.Count} records (>= configured threshold " +
            $"{_resiliencyOptions.TruncationWarningThreshold}); FortiGate Cloud pagination is unverified " +
            "in this codebase, so this response cannot be confirmed complete.";

        _logger.LogWarning("{Reason}", reason);
        return new CloudFetchResult<T>(records, IsPossiblyTruncated: true, TruncationReason: reason);
    }

    /// <summary>
    /// Per-cache-key locks preventing a "refresh storm" — concurrent calls that miss the cache
    /// for the same account must not each independently issue a token request. Keyed by cache
    /// key (account), so different accounts (once multi-account support lands) never block on
    /// each other's token acquisition.
    /// </summary>
    private static readonly System.Collections.Concurrent.ConcurrentDictionary<string, SemaphoreSlim> TokenAcquisitionLocks = new();

    private Task<string> GetAccessTokenAsync(CancellationToken cancellationToken) =>
        GetAccessTokenAsync(_options.ClientId, cancellationToken);

    private async Task<string> GetAccessTokenAsync(string clientId, CancellationToken cancellationToken)
    {
        var cacheKey = $"{TokenCacheKeyPrefix}{PrimaryAccountLabel}_{clientId}";

        if (_cache.TryGetValue(cacheKey, out string? cachedToken) && cachedToken is not null)
        {
            return cachedToken;
        }

        var gate = TokenAcquisitionLocks.GetOrAdd(cacheKey, _ => new SemaphoreSlim(1, 1));
        await gate.WaitAsync(cancellationToken);
        try
        {
            // Re-check: another caller may have already populated the cache while we waited.
            if (_cache.TryGetValue(cacheKey, out cachedToken) && cachedToken is not null)
            {
                return cachedToken;
            }

            return await AcquireAndCacheTokenAsync(cacheKey, clientId, cancellationToken);
        }
        finally
        {
            gate.Release();
        }
    }

    private async Task<string> AcquireAndCacheTokenAsync(string cacheKey, string clientId, CancellationToken cancellationToken)
    {
        var tokenRequest = new Dictionary<string, string>
        {
            ["username"] = _options.Username,
            ["password"] = _options.Password,
            ["client_id"] = clientId,
            ["grant_type"] = "password"
        };

        // The secret belongs to the inventory client only.
        if (clientId == _options.ClientId && !string.IsNullOrWhiteSpace(_options.ClientSecret))
        {
            tokenRequest["client_secret"] = _options.ClientSecret;
        }

        var tokenRequestBody = JsonSerializer.SerializeToUtf8Bytes(tokenRequest);
        using var tokenContent = new ByteArrayContent(tokenRequestBody);
        tokenContent.Headers.ContentType = new System.Net.Http.Headers.MediaTypeHeaderValue("application/json");
        using var request = new HttpRequestMessage(HttpMethod.Post, _options.TokenUrl)
        {
            Content = tokenContent
        };

        using var response = await _httpClient.SendAsync(request, cancellationToken);

        if (!response.IsSuccessStatusCode)
        {
            // Never log response body/headers here — they may echo back request content.
            _logger.LogError("FortiGate Cloud token request failed with status {StatusCode}", (int)response.StatusCode);
            _cache.Remove(cacheKey);
            response.EnsureSuccessStatusCode();
        }

        var tokenResponse = await response.Content.ReadFromJsonAsync<OAuthTokenResponse>(cancellationToken: cancellationToken)
            ?? throw new InvalidOperationException("FortiGate Cloud token endpoint returned an empty response.");

        // Safety margin before real expiry to avoid using a token that expires mid-request.
        const int safetyMarginSeconds = 60;
        var ttlSeconds = tokenResponse.ExpiresIn - safetyMarginSeconds;

        if (tokenResponse.ExpiresIn <= 0)
        {
            // Non-positive expires_in from the upstream — never cache; treat every call as
            // needing a fresh token rather than risk caching something already expired.
            _logger.LogWarning("FortiGate Cloud token response had a non-positive expires_in; not caching this token");
            return tokenResponse.AccessToken;
        }

        if (ttlSeconds <= 0)
        {
            // Token lifespan is shorter than our safety margin — caching it for any fixed
            // duration risks serving it past its real expiry. Do not cache; every caller gets
            // a fresh token until the upstream issues longer-lived tokens.
            _logger.LogWarning(
                "FortiGate Cloud token expires_in ({ExpiresIn}s) is shorter than the safety margin ({MarginS}s); not caching this token",
                tokenResponse.ExpiresIn, safetyMarginSeconds);
            return tokenResponse.AccessToken;
        }

        var ttl = TimeSpan.FromSeconds(ttlSeconds);
        _cache.Set(cacheKey, tokenResponse.AccessToken, ttl);

        _logger.LogInformation("Obtained new FortiGate Cloud access token, valid for {Ttl}", ttl);

        return tokenResponse.AccessToken;
    }

    private record OAuthTokenResponse(
        [property: JsonPropertyName("access_token")] string AccessToken,
        [property: JsonPropertyName("refresh_token")] string? RefreshToken,
        [property: JsonPropertyName("expires_in")] int ExpiresIn,
        [property: JsonPropertyName("token_type")] string? TokenType);

    private record FortiGateCloudDevice(
        [property: JsonPropertyName("sn")] string? Sn,
        [property: JsonPropertyName("firmwareVersion")] string? FirmwareVersion,
        [property: JsonPropertyName("tunnelAlive")] bool? TunnelAlive,
        [property: JsonPropertyName("model")] string? Model,
        [property: JsonPropertyName("ip")] string? Ip,
        [property: JsonPropertyName("hostname")] string? Hostname);

    private record FortiGateProductListResponse(
        [property: JsonPropertyName("assets")] List<FortiGateAsset>? Assets);

    private record FortiGateAsset(
        [property: JsonPropertyName("serialNumber")] string SerialNumber,
        [property: JsonPropertyName("description")] string? Description,
        [property: JsonPropertyName("productModel")] string? ProductModel,
        [property: JsonPropertyName("firmwareVersion")] string? FirmwareVersion,
        [property: JsonPropertyName("status")] string? Status,
        [property: JsonPropertyName("isRegistered")] bool IsRegistered,
        [property: JsonPropertyName("lastSeen")] DateTimeOffset? LastSeen,
        [property: JsonPropertyName("entitlements")] List<FortiGateEntitlement>? Entitlements);

    private record FortiGateEntitlement(
        [property: JsonPropertyName("type"), JsonConverter(typeof(StringOrNumberConverter))] string? Type,
        [property: JsonPropertyName("description")] string? Description,
        [property: JsonPropertyName("levelDescription")] string? LevelDescription,
        [property: JsonPropertyName("endDate")] string? EndDate);

    private sealed class StringOrNumberConverter : JsonConverter<string?>
    {
        public override string? Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
            reader.TokenType switch
            {
                JsonTokenType.String => reader.GetString(),
                JsonTokenType.Number => JsonDocument.ParseValue(ref reader).RootElement.GetRawText(),
                JsonTokenType.Null => null,
                _ => throw new JsonException("Expected a string or number.")
            };

        public override void Write(Utf8JsonWriter writer, string? value, JsonSerializerOptions options) =>
            writer.WriteStringValue(value);
    }
}
