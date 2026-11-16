using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace FortiGateDashboard.Infrastructure.Data.Migrations
{
    /// <inheritdoc />
    public partial class AddPsirtRiskAssessment : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<int>(
                name: "RiskAssessmentAuto",
                table: "PsirtAdvisories",
                type: "integer",
                nullable: false,
                defaultValue: 2);

            migrationBuilder.AddColumn<int>(
                name: "RiskAssessmentOverride",
                table: "PsirtAdvisories",
                type: "integer",
                nullable: true);

            migrationBuilder.AddColumn<string>(
                name: "RiskAssessmentReason",
                table: "PsirtAdvisories",
                type: "text",
                nullable: true);
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropColumn(
                name: "RiskAssessmentAuto",
                table: "PsirtAdvisories");

            migrationBuilder.DropColumn(
                name: "RiskAssessmentOverride",
                table: "PsirtAdvisories");

            migrationBuilder.DropColumn(
                name: "RiskAssessmentReason",
                table: "PsirtAdvisories");
        }
    }
}
