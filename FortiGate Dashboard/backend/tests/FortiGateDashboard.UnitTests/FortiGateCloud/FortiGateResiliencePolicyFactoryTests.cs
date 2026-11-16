using System.Net;
using FortiGateDashboard.Core.Options;
using FortiGateDashboard.Infrastructure.FortiGateCloud;
using FluentAssertions;
using Microsoft.Extensions.Logging.Abstractions;
using Polly.CircuitBreaker;
using Polly.Bulkhead;
using Polly.Timeout;

namespace FortiGateDashboard.UnitTests.FortiGateCloud;

public class FortiGateResiliencePolicyFactoryTests
{
    private static FortiGateCloudResiliencyOptions FastOptions() => new()
    {
        RetryCount = 3,
        TimeoutSeconds = 1,
        TotalTimeoutSeconds = 5,
        MaxRetryAfterSeconds = 1,
        CircuitBreakerFailureThreshold = 2,
        CircuitBreakerDurationSeconds = 1,
        MaxConcurrentRequests = 2,
        MaxQueuedRequests = 0,
        TruncationWarningThreshold = 1000
    };

    [Fact]
    public async Task RetryPolicy_Retries_On429()
    {
        var options = FastOptions();
        var policy = FortiGateResiliencePolicyFactory.CreateRetryPolicy(options, NullLogger.Instance);
        var callCount = 0;

        var response = await policy.ExecuteAsync(_ =>
        {
            callCount++;
            var status = callCount < 3 ? (HttpStatusCode)429 : HttpStatusCode.OK;
            return Task.FromResult(new HttpResponseMessage(status));
        }, CancellationToken.None);

        callCount.Should().Be(3);
        response.StatusCode.Should().Be(HttpStatusCode.OK);
    }

    [Fact]
    public async Task RetryPolicy_HonorsRetryAfterHeader()
    {
        var options = FastOptions();
        var policy = FortiGateResiliencePolicyFactory.CreateRetryPolicy(options, NullLogger.Instance);
        var callCount = 0;
        var stopwatch = System.Diagnostics.Stopwatch.StartNew();

        await policy.ExecuteAsync(_ =>
        {
            callCount++;
            if (callCount == 1)
            {
                var rejected = new HttpResponseMessage((HttpStatusCode)429);
                rejected.Headers.RetryAfter = new System.Net.Http.Headers.RetryConditionHeaderValue(TimeSpan.FromMilliseconds(200));
                return Task.FromResult(rejected);
            }

            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK));
        }, CancellationToken.None);

        stopwatch.Stop();
        callCount.Should().Be(2);
        stopwatch.ElapsedMilliseconds.Should().BeGreaterThanOrEqualTo(190);
    }

    [Fact]
    public async Task RetryPolicy_Retries_On500()
    {
        var options = FastOptions();
        var policy = FortiGateResiliencePolicyFactory.CreateRetryPolicy(options, NullLogger.Instance);
        var callCount = 0;

        var response = await policy.ExecuteAsync(_ =>
        {
            callCount++;
            var status = callCount < 2 ? HttpStatusCode.InternalServerError : HttpStatusCode.OK;
            return Task.FromResult(new HttpResponseMessage(status));
        }, CancellationToken.None);

        callCount.Should().Be(2);
        response.StatusCode.Should().Be(HttpStatusCode.OK);
    }

    [Theory]
    [InlineData(HttpStatusCode.Unauthorized)]
    [InlineData(HttpStatusCode.Forbidden)]
    [InlineData(HttpStatusCode.BadRequest)]
    [InlineData(HttpStatusCode.NotFound)]
    public async Task RetryPolicy_DoesNotRetry_OnPermanentFailures(HttpStatusCode statusCode)
    {
        var options = FastOptions();
        var policy = FortiGateResiliencePolicyFactory.CreateRetryPolicy(options, NullLogger.Instance);
        var callCount = 0;

        var response = await policy.ExecuteAsync(_ =>
        {
            callCount++;
            return Task.FromResult(new HttpResponseMessage(statusCode));
        }, CancellationToken.None);

        callCount.Should().Be(1);
        response.StatusCode.Should().Be(statusCode);
    }

    [Fact]
    public async Task CircuitBreaker_Opens_AfterConsecutiveFailures()
    {
        var options = FastOptions();
        var policy = FortiGateResiliencePolicyFactory.CreateCircuitBreakerPolicy(options, NullLogger.Instance);

        // Trip the breaker (threshold = 2).
        for (var i = 0; i < options.CircuitBreakerFailureThreshold; i++)
        {
            await policy.ExecuteAsync(_ => Task.FromResult(new HttpResponseMessage(HttpStatusCode.InternalServerError)), CancellationToken.None);
        }

        Func<Task> act = () => policy.ExecuteAsync(_ => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)), CancellationToken.None);

        await act.Should().ThrowAsync<BrokenCircuitException>();
    }

    [Fact]
    public async Task TimeoutPolicy_ThrowsTimeoutRejectedException_WhenExceeded()
    {
        var options = FastOptions();
        var policy = FortiGateResiliencePolicyFactory.CreateTimeoutPolicy(options);

        Func<Task> act = () => policy.ExecuteAsync(async ct =>
        {
            await Task.Delay(TimeSpan.FromSeconds(options.TimeoutSeconds + 2), ct);
            return new HttpResponseMessage(HttpStatusCode.OK);
        }, CancellationToken.None);

        await act.Should().ThrowAsync<TimeoutRejectedException>();
    }

    [Fact]
    public async Task BulkheadPolicy_RejectsWhenConcurrencyExceeded()
    {
        var options = FastOptions();
        var policy = FortiGateResiliencePolicyFactory.CreateBulkheadPolicy(options);

        var gate = new TaskCompletionSource();
        var inFlightTasks = Enumerable.Range(0, options.MaxConcurrentRequests)
            .Select(_ => policy.ExecuteAsync(async () =>
            {
                await gate.Task;
                return new HttpResponseMessage(HttpStatusCode.OK);
            }))
            .ToList();

        Func<Task> act = () => policy.ExecuteAsync(() => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)));

        await act.Should().ThrowAsync<BulkheadRejectedException>();

        gate.SetResult();
        await Task.WhenAll(inFlightTasks);
    }

    [Fact]
    public async Task RetryPolicy_PropagatesCancellation()
    {
        var options = FastOptions();
        var policy = FortiGateResiliencePolicyFactory.CreateRetryPolicy(options, NullLogger.Instance);
        using var cts = new CancellationTokenSource();
        cts.Cancel();

        Func<Task> act = () => policy.ExecuteAsync(ct =>
        {
            ct.ThrowIfCancellationRequested();
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK));
        }, cts.Token);

        await act.Should().ThrowAsync<OperationCanceledException>();
    }

    [Fact]
    public async Task RetryPolicy_CapsExcessiveRetryAfterHeader_ToMaxRetryAfterSeconds()
    {
        var options = FastOptions(); // MaxRetryAfterSeconds = 1
        var policy = FortiGateResiliencePolicyFactory.CreateRetryPolicy(options, NullLogger.Instance);
        var callCount = 0;
        var stopwatch = System.Diagnostics.Stopwatch.StartNew();

        // A malicious/misconfigured upstream asks for a 10 minute wait; must be capped to ~1s.
        await policy.ExecuteAsync(_ =>
        {
            callCount++;
            if (callCount == 1)
            {
                var rejected = new HttpResponseMessage((HttpStatusCode)429);
                rejected.Headers.RetryAfter = new System.Net.Http.Headers.RetryConditionHeaderValue(TimeSpan.FromMinutes(10));
                return Task.FromResult(rejected);
            }

            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK));
        }, CancellationToken.None);

        stopwatch.Stop();
        callCount.Should().Be(2);
        stopwatch.Elapsed.Should().BeLessThan(TimeSpan.FromSeconds(3), "the excessive Retry-After must be capped, not honored verbatim");
    }

    [Fact]
    public async Task RetryPolicy_CancellationInterruptsBackoffWait_DoesNotWaitFullDelay()
    {
        var options = FastOptions();
        options.MaxRetryAfterSeconds = 30; // large potential delay if cancellation didn't work
        var policy = FortiGateResiliencePolicyFactory.CreateRetryPolicy(options, NullLogger.Instance);
        using var cts = new CancellationTokenSource();
        var stopwatch = System.Diagnostics.Stopwatch.StartNew();

        Func<Task> act = () => policy.ExecuteAsync(_ =>
        {
            var rejected = new HttpResponseMessage((HttpStatusCode)429);
            rejected.Headers.RetryAfter = new System.Net.Http.Headers.RetryConditionHeaderValue(TimeSpan.FromSeconds(20));
            return Task.FromResult(rejected);
        }, cts.Token);

        cts.CancelAfter(TimeSpan.FromMilliseconds(200));

        await act.Should().ThrowAsync<OperationCanceledException>();
        stopwatch.Elapsed.Should().BeLessThan(TimeSpan.FromSeconds(2), "cancellation must interrupt the backoff wait, not the whole 20s delay");
    }

    [Fact]
    public async Task BulkheadPolicy_ReleasesSlot_AfterCompletion_AllowingSubsequentCalls()
    {
        var options = FastOptions();
        var policy = FortiGateResiliencePolicyFactory.CreateBulkheadPolicy(options);

        for (var i = 0; i < options.MaxConcurrentRequests + 2; i++)
        {
            var response = await policy.ExecuteAsync(() => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)));
            response.StatusCode.Should().Be(HttpStatusCode.OK);
        }
    }

    [Fact]
    public async Task CircuitBreaker_TransitionsToHalfOpenThenClosed_AfterSuccessfulProbe()
    {
        var options = FastOptions(); // CircuitBreakerDurationSeconds = 1
        var policy = FortiGateResiliencePolicyFactory.CreateCircuitBreakerPolicy(options, NullLogger.Instance);

        for (var i = 0; i < options.CircuitBreakerFailureThreshold; i++)
        {
            await policy.ExecuteAsync(_ => Task.FromResult(new HttpResponseMessage(HttpStatusCode.InternalServerError)), CancellationToken.None);
        }

        Func<Task> whileOpen = () => policy.ExecuteAsync(_ => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)), CancellationToken.None);
        await whileOpen.Should().ThrowAsync<BrokenCircuitException>();

        await Task.Delay(TimeSpan.FromSeconds(options.CircuitBreakerDurationSeconds + 1));

        // Half-open: the next call is a trial probe. A successful probe closes the circuit again.
        var probeResponse = await policy.ExecuteAsync(_ => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)), CancellationToken.None);
        probeResponse.StatusCode.Should().Be(HttpStatusCode.OK);

        var afterRecovery = await policy.ExecuteAsync(_ => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)), CancellationToken.None);
        afterRecovery.StatusCode.Should().Be(HttpStatusCode.OK);
    }

    [Fact]
    public void PolicyRegistry_CreatesIndependentPolicyInstances_PerFactoryCall()
    {
        // Proves policy state does not leak between separate registry/factory constructions
        // (e.g. separate DI containers / test hosts) — each call yields a distinct instance.
        var options = FastOptions();
        var first = FortiGateResiliencePolicyFactory.CreateCircuitBreakerPolicy(options, NullLogger.Instance);
        var second = FortiGateResiliencePolicyFactory.CreateCircuitBreakerPolicy(options, NullLogger.Instance);

        first.Should().NotBeSameAs(second);
    }
}
