using FortiGateDashboard.Api.Dtos;
using FortiGateDashboard.Infrastructure.Data;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.RateLimiting;
using Microsoft.EntityFrameworkCore;

namespace FortiGateDashboard.Api.Controllers;

[ApiController]
[Authorize]
[EnableRateLimiting("general")]
[Route("api/subscriptions")]
public class SubscriptionsController : ControllerBase
{
    private readonly FortiGateDashboardDbContext _db;

    public SubscriptionsController(FortiGateDashboardDbContext db)
    {
        _db = db;
    }

    /// <summary>Subscriptions expiring within the given number of days (default 90), soonest first.</summary>
    [HttpGet("expiring")]
    public async Task<ActionResult<IReadOnlyList<ExpiringSubscriptionDto>>> GetExpiring(
        [FromQuery] int withinDays = 90,
        CancellationToken cancellationToken = default)
    {
        var results = await _db.Subscriptions
            .Include(s => s.Device)
            .Where(s => s.DaysRemaining < withinDays)
            .OrderBy(s => s.DaysRemaining)
            .Select(s => new ExpiringSubscriptionDto(
                s.Device.Name,
                s.Device.SerialNumber,
                s.SubscriptionName,
                s.SubscriptionType,
                s.ExpiryDate,
                s.DaysRemaining,
                s.Status.ToString()))
            .ToListAsync(cancellationToken);

        return Ok(results);
    }
}
