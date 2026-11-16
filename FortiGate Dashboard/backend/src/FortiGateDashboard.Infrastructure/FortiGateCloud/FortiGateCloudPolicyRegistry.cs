using FortiGateDashboard.Core.Options;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using Polly;

namespace FortiGateDashboard.Infrastructure.FortiGateCloud;

/// <summary>
/// Holds singleton instances of the stateful FortiGate Cloud resilience policies (circuit
/// breaker, bulkhead). These MUST be shared across the lifetime of the application rather than
/// rebuilt on every <c>IHttpClientFactory</c> handler rotation (~2 min) — recreating a circuit
/// breaker or bulkhead per rotation would silently reset their state and defeat the purpose.
/// </summary>
public class FortiGateCloudPolicyRegistry
{
    public IAsyncPolicy<HttpResponseMessage> Bulkhead { get; }

    public IAsyncPolicy<HttpResponseMessage> CircuitBreaker { get; }

    public IAsyncPolicy<HttpResponseMessage> Retry { get; }

    public IAsyncPolicy<HttpResponseMessage> Timeout { get; }

    public IAsyncPolicy<HttpResponseMessage> TotalTimeout { get; }

    public FortiGateCloudPolicyRegistry(IOptions<FortiGateCloudResiliencyOptions> options, ILoggerFactory loggerFactory)
    {
        var value = options.Value;
        Bulkhead = FortiGateResiliencePolicyFactory.CreateBulkheadPolicy(value);
        CircuitBreaker = FortiGateResiliencePolicyFactory.CreateCircuitBreakerPolicy(value, loggerFactory.CreateLogger("FortiGateCloud.CircuitBreaker"));
        Retry = FortiGateResiliencePolicyFactory.CreateRetryPolicy(value, loggerFactory.CreateLogger("FortiGateCloud.Retry"));
        Timeout = FortiGateResiliencePolicyFactory.CreateTimeoutPolicy(value);
        TotalTimeout = FortiGateResiliencePolicyFactory.CreateTotalTimeoutPolicy(value);
    }
}
