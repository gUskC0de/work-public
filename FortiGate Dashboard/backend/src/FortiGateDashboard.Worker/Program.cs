using FortiGateDashboard.Infrastructure;
using FortiGateDashboard.Worker.Jobs;
using Quartz;
using Serilog;

var builder = Host.CreateApplicationBuilder(args);

builder.Services.AddSerilog((services, loggerConfig) => loggerConfig
    .ReadFrom.Configuration(builder.Configuration)
    .Enrich.FromLogContext()
    .Enrich.WithMachineName()
    .WriteTo.Console()
    .WriteTo.File("logs/fortigate-worker-.log", rollingInterval: RollingInterval.Day));

builder.Services.AddFortiGateDashboardInfrastructure(builder.Configuration);

builder.Services.AddQuartz(q =>
{
    var deviceSyncJobKey = new JobKey("DeviceInventorySyncJob");
    q.AddJob<DeviceInventorySyncJob>(opts => opts.WithIdentity(deviceSyncJobKey));
    q.AddTrigger(opts => opts
        .ForJob(deviceSyncJobKey)
        .WithIdentity("DeviceInventorySyncJob-trigger")
        .WithSimpleSchedule(s => s.WithIntervalInHours(6).RepeatForever())
        .StartNow());

    var subscriptionPsirtJobKey = new JobKey("SubscriptionAndPsirtSyncJob");
    q.AddJob<SubscriptionAndPsirtSyncJob>(opts => opts.WithIdentity(subscriptionPsirtJobKey));
    q.AddTrigger(opts => opts
        .ForJob(subscriptionPsirtJobKey)
        .WithIdentity("SubscriptionAndPsirtSyncJob-startup-trigger")
        .StartNow()
        .WithSimpleSchedule(s => s.WithRepeatCount(0)));
    q.AddTrigger(opts => opts
        .ForJob(subscriptionPsirtJobKey)
        .WithIdentity("SubscriptionAndPsirtSyncJob-daily-trigger")
        .WithCronSchedule("0 0 2 * * ?"));
});

builder.Services.AddQuartzHostedService(opts => opts.WaitForJobsToComplete = true);

var host = builder.Build();
host.Run();
