[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProxmoxHost,

    [int]$Port = 8006,

    [Parameter(Mandatory = $true)]
    [string]$TokenId,

    [Parameter(Mandatory = $true)]
    [string]$Token = 'TOKEN',

    [switch]$SkipCertificateCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:BaseUrl = "https://${ProxmoxHost}:${Port}/api2/json"
$script:AuthHeader = @{ Authorization = "PVEAPIToken=${TokenId}=${Token}" }

function Invoke-ProxmoxApi {
    <#
        .SYNOPSIS
        Calls the Proxmox VE API using API token authentication.

        .PARAMETER Method
        HTTP method: GET, POST, PUT, or DELETE.

        .PARAMETER Path
        API path relative to /api2/json, e.g. '/version' or '/nodes'.

        .PARAMETER Body
        Optional hashtable of parameters to send with the request.
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('GET', 'POST', 'PUT', 'DELETE')]
        [string]$Method = 'GET',

        [Parameter(Mandatory = $true)]
        [string]$Path,

        [hashtable]$Body
    )

    $uri = "$($script:BaseUrl)$Path"

    $invokeParams = @{
        Method  = $Method
        Uri     = $uri
        Headers = $script:AuthHeader
    }

    if ($Body) {
        $invokeParams.Body = $Body
    }

    if ($SkipCertificateCheck) {
        $invokeParams.SkipCertificateCheck = $true
    }

    Invoke-RestMethod @invokeParams
}

function Test-ProxmoxConnection {
    <#
        .SYNOPSIS
        Verifies the API token is valid by requesting the Proxmox version.
    #>
    [CmdletBinding()]
    param()

    $response = Invoke-ProxmoxApi -Method GET -Path '/version'
    Write-Host "Connected to Proxmox VE $($response.data.version) on $ProxmoxHost" -ForegroundColor Green
    $response.data
}

if ($MyInvocation.InvocationName -ne '.') {
    Test-ProxmoxConnection | Out-Null
}
