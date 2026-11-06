using FortiGateDashboard.Core.Entities;
using FluentAssertions;

namespace FortiGateDashboard.UnitTests.Entities;

public class SubscriptionStatusTests
{
    [Theory]
    [InlineData(-5, SubscriptionStatus.Expired)]
    [InlineData(0, SubscriptionStatus.Critical)]
    [InlineData(29, SubscriptionStatus.Critical)]
    [InlineData(30, SubscriptionStatus.Warning)]
    [InlineData(89, SubscriptionStatus.Warning)]
    [InlineData(90, SubscriptionStatus.Healthy)]
    [InlineData(365, SubscriptionStatus.Healthy)]
    public void CalculateStatus_ReturnsExpectedStatus(int daysRemaining, SubscriptionStatus expected)
    {
        var result = Subscription.CalculateStatus(daysRemaining);

        result.Should().Be(expected);
    }
}
