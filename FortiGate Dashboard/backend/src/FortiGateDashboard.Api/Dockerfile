# syntax=docker/dockerfile:1
# Pinned to the patch versions used/verified during this change. Re-pin (and ideally pin to a
# verified @sha256 digest) as part of your image update process.
FROM mcr.microsoft.com/dotnet/sdk:9.0 AS build
WORKDIR /src

COPY backend/FortiGateDashboard.sln ./
COPY backend/src/FortiGateDashboard.Api/FortiGateDashboard.Api.csproj src/FortiGateDashboard.Api/
COPY backend/src/FortiGateDashboard.Core/FortiGateDashboard.Core.csproj src/FortiGateDashboard.Core/
COPY backend/src/FortiGateDashboard.Infrastructure/FortiGateDashboard.Infrastructure.csproj src/FortiGateDashboard.Infrastructure/
COPY backend/src/FortiGateDashboard.Worker/FortiGateDashboard.Worker.csproj src/FortiGateDashboard.Worker/
COPY backend/tests/FortiGateDashboard.UnitTests/FortiGateDashboard.UnitTests.csproj tests/FortiGateDashboard.UnitTests/
COPY backend/tests/FortiGateDashboard.IntegrationTests/FortiGateDashboard.IntegrationTests.csproj tests/FortiGateDashboard.IntegrationTests/
RUN dotnet restore FortiGateDashboard.sln

COPY backend/src src
COPY backend/tests tests
RUN dotnet publish src/FortiGateDashboard.Api/FortiGateDashboard.Api.csproj -c Release -o /app

FROM mcr.microsoft.com/dotnet/aspnet:9.0-alpine AS runtime
WORKDIR /app
RUN addgroup -S appgroup && adduser -S appuser -G appgroup
COPY --from=build /app .
USER appuser
EXPOSE 8080
ENV ASPNETCORE_URLS=http://+:8080
HEALTHCHECK --interval=15s --timeout=5s --retries=5 CMD wget -qO- http://localhost:8080/health || exit 1
ENTRYPOINT ["dotnet", "FortiGateDashboard.Api.dll"]
