using FortiGateDashboard.Api.Dtos;
using FortiGateDashboard.Core.Entities;
using FortiGateDashboard.Infrastructure.Data;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.RateLimiting;
using Microsoft.EntityFrameworkCore;

namespace FortiGateDashboard.Api.Controllers;

[ApiController]
[Authorize]
[EnableRateLimiting("general")]
[Route("api/psirt")]
public class PsirtController : ControllerBase
{
    private readonly FortiGateDashboardDbContext _db;

    public PsirtController(FortiGateDashboardDbContext db)
    {
        _db = db;
    }

    /// <summary>All known PSIRT advisories with the count of CONFIRMED (Affected) device correlations.</summary>
    [HttpGet]
    public async Task<ActionResult<IReadOnlyList<PsirtAdvisoryDto>>> GetAdvisories(CancellationToken cancellationToken)
    {
        var advisories = await _db.PsirtAdvisories
            .Include(a => a.DevicePsirts)
            .OrderByDescending(a => a.PublishedDate)
            .Select(a => new PsirtAdvisoryDto(
                a.PsirtId,
                a.Title,
                a.AdvisoryUrl,
                a.Severity.ToString(),
                a.CvssScore,
                a.PublishedDate,
                a.AffectedVersionRange,
                a.DevicePsirts.Count(dp => dp.CorrelationStatus == PsirtCorrelationStatus.Affected),
                a.ParseStatus.ToString()))
            .ToListAsync(cancellationToken);

        return Ok(advisories);
    }
}
