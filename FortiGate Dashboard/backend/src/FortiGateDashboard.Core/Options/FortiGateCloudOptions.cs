namespace FortiGateDashboard.Core.Options;

/// <summary>
/// Configuration for one or more FortiGate Cloud (FortiCloud) accounts. Client secrets are
/// bound from environment variables / secret managers, never plaintext config files.
/// </summary>
public class FortiGateCloudOptions
{
    public const string SectionName = "FortiGateCloud";

    public string BaseUrl { get; set; } = "https://support.fortinet.com/ES/api/registration/v3";

    public string TokenUrl { get; set; } = "https://customerapiauth.fortinet.com/api/v1/oauth/token/";

    public string ClientId { get; set; } = default!;

    public string ClientSecret { get; set; } = default!;

    public string Username { get; set; } = default!;

    public string Password { get; set; } = default!;

    public long AccountId { get; set; }

    public bool TelemetryEnabled { get; set; } = true;

    /// <summary>Regional host: api (global), usapi, euapi or jpapi.fortigate.forticloud.com.</summary>
    public string TelemetryBaseUrl { get; set; } = "https://euapi.fortigate.forticloud.com/forticloudapi/v1";

    public string TelemetryClientId { get; set; } = "fortigatecloud";

    /// <summary>
    /// NOT YET CONSUMED. Reserved for future multi-account support (see remediation Phase 3);
    /// <see cref="FortiGateCloudService"/> currently only ever uses the primary
    /// ClientId/ClientSecret/Username/Password above — entries here have no runtime effect
    /// today. Do not configure this expecting multi-account behavior yet.
    /// </summary>
    public List<FortiGateCloudAccount> AdditionalAccounts { get; set; } = new();
}

public class FortiGateCloudAccount
{
    public string AccountId { get; set; } = default!;

    public string AccountName { get; set; } = default!;

    public string ClientId { get; set; } = default!;

    public string ClientSecret { get; set; } = default!;
}
