namespace FortiGateDashboard.Core.Interfaces;

using FortiGateDashboard.Core.Models;

/// <summary>
/// Abstraction over the FortiGate Cloud REST API. Implementations handle OAuth2 token
/// acquisition/refresh and pagination transparently.
/// </summary>
/// <remarks>
/// Pagination status: NOT VERIFIED. This repository does not contain FortiGate Cloud API
/// documentation, captured response fixtures, or evidence of the real pagination contract
/// (whether it uses page numbers, offsets, or cursors). Implementations must not fabricate
/// pagination parameters; see <see cref="CloudFetchResult{T}"/> for how truncation risk is
/// surfaced to callers instead.
/// </remarks>
public interface IFortiGateCloudService
{
    /// <summary>Fetches the full device inventory across all configured FortiGate Cloud accounts.</summary>
    Task<CloudFetchResult<CloudDeviceRecord>> GetDevicesAsync(CancellationToken cancellationToken = default);

    /// <summary>Fetches subscription/license information for all devices.</summary>
    Task<CloudFetchResult<CloudSubscriptionRecord>> GetSubscriptionsAsync(CancellationToken cancellationToken = default);
}
