using System.Diagnostics.Metrics;

namespace FortiGateDashboard.Infrastructure.Observability;

/// <summary>
/// PSIRT parsing/correlation counters exposed via <see cref="System.Diagnostics.Metrics"/>.
/// Deliberately framework-agnostic (no OpenTelemetry SDK dependency yet) so an exporter can be
/// wired up later by listening to the "FortiGateDashboard.Psirt" meter name.
/// </summary>
public static class PsirtMetrics
{
    public const string MeterName = "FortiGateDashboard.Psirt";

    private static readonly Meter Meter = new(MeterName);

    public static readonly Counter<long> AdvisoriesParsed = Meter.CreateCounter<long>("psirt.advisories.parsed");
    public static readonly Counter<long> AdvisoriesPartiallyParsed = Meter.CreateCounter<long>("psirt.advisories.partially_parsed");
    public static readonly Counter<long> AdvisoriesUnparseable = Meter.CreateCounter<long>("psirt.advisories.unparseable");
    public static readonly Counter<long> CorrelationsAffected = Meter.CreateCounter<long>("psirt.correlations.affected");
    public static readonly Counter<long> CorrelationsUnableToEvaluate = Meter.CreateCounter<long>("psirt.correlations.unable_to_evaluate");
    public static readonly Counter<long> InvalidAdvisoryUrls = Meter.CreateCounter<long>("psirt.advisories.invalid_url");
}
