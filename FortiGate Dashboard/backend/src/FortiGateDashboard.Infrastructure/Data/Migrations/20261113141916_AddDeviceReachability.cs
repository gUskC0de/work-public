using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace FortiGateDashboard.Infrastructure.Data.Migrations
{
    /// <inheritdoc />
    public partial class AddDeviceReachability : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<bool>(
                name: "HttpsPortOpen",
                table: "Devices",
                type: "boolean",
                nullable: true);

            migrationBuilder.AddColumn<bool>(
                name: "IcmpReachable",
                table: "Devices",
                type: "boolean",
                nullable: true);

            migrationBuilder.AddColumn<bool>(
                name: "Port9443Open",
                table: "Devices",
                type: "boolean",
                nullable: true);

            migrationBuilder.AddColumn<DateTimeOffset>(
                name: "ReachabilityCheckedAt",
                table: "Devices",
                type: "timestamp with time zone",
                nullable: true);

            migrationBuilder.AddColumn<bool>(
                name: "SshPortOpen",
                table: "Devices",
                type: "boolean",
                nullable: true);
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropColumn(
                name: "HttpsPortOpen",
                table: "Devices");

            migrationBuilder.DropColumn(
                name: "IcmpReachable",
                table: "Devices");

            migrationBuilder.DropColumn(
                name: "Port9443Open",
                table: "Devices");

            migrationBuilder.DropColumn(
                name: "ReachabilityCheckedAt",
                table: "Devices");

            migrationBuilder.DropColumn(
                name: "SshPortOpen",
                table: "Devices");
        }
    }
}
