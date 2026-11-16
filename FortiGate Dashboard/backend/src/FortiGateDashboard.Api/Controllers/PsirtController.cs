using FortiGateDashboard.Api.Dtos;
using FortiGateDashboard.Core.Entities;
using FortiGateDashboard.Core.Models;
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
    private readonly ILogger<PsirtController> _logger;

    public PsirtController(FortiGateDashboardDbContext db, ILogger<PsirtController> logger)
    {
        _db = db;
        _logger = logger;
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

    /// <summary>
    /// Sets (or clears, with a null risk) the manual risk override for an advisory. The override
    /// applies to every device affected by the advisory and survives PSIRT re-syncs.
    /// </summary>
    [HttpPut("{psirtId}/risk")]
    [Authorize(Roles = "Admin,Operator")]
    public async Task<ActionResult<AdvisoryRiskDto>> UpdateRiskAssessment(
        string psirtId,
        [FromBody] UpdateRiskAssessmentRequest request,
        CancellationToken cancellationToken)
    {
        PsirtRiskLevel? overrideRisk = null;
        if (!string.IsNullOrWhiteSpace(request.Risk))
        {
            if (!Enum.TryParse<PsirtRiskLevel>(request.Risk, true, out var parsed) || !Enum.IsDefined(parsed))
            {
                return ValidationProblem($"Risk must be one of: {string.Join(", ", Enum.GetNames<PsirtRiskLevel>())}, or null to clear the override.");
            }

            overrideRisk = parsed;
        }

        var advisory = await _db.PsirtAdvisories.FirstOrDefaultAsync(a => a.PsirtId == psirtId, cancellationToken);
        if (advisory is null)
        {
            return NotFound();
        }

        advisory.RiskAssessmentOverride = overrideRisk;
        await _db.SaveChangesAsync(cancellationToken);

        _logger.LogInformation("Risk assessment override for {PsirtId} set to {Risk} by {User}",
            advisory.PsirtId, overrideRisk?.ToString() ?? "(cleared)", User.Identity?.Name ?? "unknown");

        return Ok(new AdvisoryRiskDto(
            advisory.PsirtId,
            advisory.Title,
            advisory.AdvisoryUrl,
            advisory.Severity.ToString(),
            advisory.CvssScore,
            advisory.EffectiveRisk.ToString(),
            advisory.RiskAssessmentAuto.ToString(),
            advisory.RiskAssessmentOverride?.ToString(),
            advisory.RiskAssessmentReason));
    }
}
