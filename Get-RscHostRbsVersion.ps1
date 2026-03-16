<#
.SYNOPSIS
    Retrieves Physical Hosts from Rubrik Security Cloud (RSC) and reports on RBS Agent versions.

.DESCRIPTION
    This script performs the following actions:
    1. Connects to RSC using a Service Account file.
    2. Identifies the active RSC Instance URL via the SDK configuration.
    3. Queries the GraphQL API for Windows and Linux hosts.
    4. Decodes metadata and OS Name strings to identify the active RBS Agent version.
    5. Flags outliers (8.x versions, Unknown versions, or Unknown Upgrade Status) for Manual Validation.
    6. Exports the report to CSV and HTML with an interactive sortable table.

.PARAMETER ServiceAccountFile
    The full path to your RSC Service Account JSON file.

.PARAMETER ExportPath
    The directory where you want to save the CSV/HTML reports.
#>

param (
    [Parameter(Mandatory=$true, HelpMessage="Path to the encrypted RSC Service Account JSON file")]
    [ValidateNotNullOrEmpty()]
    [string]$ServiceAccountFile,

    [Parameter(Mandatory=$false, HelpMessage="Directory path to export CSV/HTML reports (e.g., C:\reports)")]
    [string]$ExportPath
)

# --- 1. PRE-FLIGHT CHECKS ---
if (-not (Get-Module -ListAvailable -Name RubrikSecurityCloud)) {
    Write-Error "The RubrikSecurityCloud module is missing. Please run: Install-Module RubrikSecurityCloud"
    exit
}
Import-Module RubrikSecurityCloud

# --- 2. CONNECT AND IDENTIFY INSTANCE URL ---
Write-Host "Connecting to Rubrik Security Cloud..." -ForegroundColor Cyan
Connect-Rsc -ServiceAccountFile $ServiceAccountFile

# Capture the exact URL being used from the active SDK configuration
Write-Host "Fetching RSC Instance URL..." -ForegroundColor Gray
$rscConfig = Get-RscConfig
$rscInstanceUrl = $rscConfig.Endpoint

if ([string]::IsNullOrWhiteSpace($rscInstanceUrl)) {
    $rscInstanceUrl = "https://rubrik-gaia-next.my.rubrik.com/" 
}

# --- 3. DATA COLLECTION ---
Write-Host "Querying RSC instance [$rscInstanceUrl] for Physical Hosts..." -ForegroundColor Cyan

$targetRoots = @("WINDOWS_HOST_ROOT", "LINUX_HOST_ROOT")
$allNodes = @()

foreach ($root in $targetRoots) {
    $query = New-RscQuery -GqlQuery physicalHosts
    $query.Var.hostRoot = $root

    # InitialProperties bypasses strict .NET type casting issues in the SDK
    $nodeType = Get-RscType -Name PhysicalHost -InitialProperties @(
        "id", "name", "osType", "osName", "rbaPackageUpgradeInfo", "rbsUpgradeStatus", "clusterRelation"
    )
    
    # Hydrate sub-objects for Cluster and Connection metadata
    $nodeType.Cluster = Get-RscType -Name Cluster -InitialProperties "name"
    $nodeType.ConnectionStatus = Get-RscType -Name HostConnectionStatus -InitialProperties "timestampMillis"

    $query.Field.Nodes = @($nodeType)
    $response = $query.Invoke()
    if ($null -ne $response.Nodes) { $allNodes += $response.Nodes }
}

# --- 4. DATA PROCESSING ---
$hostList = foreach ($node in $allNodes) {
    $foundVer = "Unknown"
    
    # Path A: Extract version from OS Name (Most accurate for active service)
    if ($node.OsName -match '\(([\d\.p\-]+)') {
        $foundVer = $Matches[1]
    }
    # Path B: Fallback to RBA Package Info JSON blob
    elseif (-not [string]::IsNullOrWhiteSpace($node.RbaPackageUpgradeInfo)) {
        try {
            $rbaInfo = $node.RbaPackageUpgradeInfo | ConvertFrom-Json
            if ($null -ne $rbaInfo.rbaPackageVersionOpt) {
                # Truncate build hashes and bazel metadata
                $foundVer = ($rbaInfo.rbaPackageVersionOpt -split '[\+\-]bazel')[0]
            }
        } catch { }
    }

    # Final Clean-up: Truncate long version strings (AIX/Linux dots) to version core
    if ($foundVer -match '^(\d+\.\d+\.\d+(\.p\d+)?)\.') {
        $foundVer = $Matches[1]
    }

    $connectivity = if ($node.ClusterRelation -eq "PRIMARY") { "Connected" } else { "Secondary Cluster" }

    [PSCustomObject]@{
        HostName         = $node.Name
        OSType           = $node.OsType
        AgentVersion     = $foundVer
        RBSUpgradeStatus = $node.RbsUpgradeStatus
        Connectivity     = $connectivity
        Cluster          = if ($node.Cluster.Name) { $node.Cluster.Name } else { "Unknown" }
    }
}

# --- 5. OUTLIER DETECTION & FILTERING ---
$targetOsRegex = "(?i)(Windows|Linux|Unix|AIX|SunOS|Solaris|HPUX)"
$connectedHosts = $hostList | Where-Object { 
    $_.OSType -match $targetOsRegex -and $_.Connectivity -eq "Connected" 
}

# Identify outliers for manual validation marking
$finalReport = foreach ($entry in $connectedHosts) {
    $validationText = ""
    
    $isOldVersion = $entry.AgentVersion -like "8.*"
    $isUnknownStatus = $entry.RBSUpgradeStatus -eq "UPGRADE_STATUS_UNKNOWN"
    $isUnknownVersion = $entry.AgentVersion -eq "Unknown"

    if ($isOldVersion -or $isUnknownStatus -or $isUnknownVersion) {
        if ($entry.OSType -eq "WINDOWS") { 
            $validationText = "Reg: HKLM:\SOFTWARE\Rubrik Inc.\Backup Service\Backup Agent ID"
        } else { 
            $validationText = "Shell: cat /etc/rubrik/conf/agent_version"
        }
    }

    $entry | Add-Member -MemberType NoteProperty -Name "Manual Validation Recommended" -Value $validationText -PassThru
}

# --- 6. OUTPUT & EXPORT ---
Write-Host "`nFound $($finalReport.Count) 'Connected' hosts (Primary registrations)." -ForegroundColor Green
$finalReport | Sort-Object OSType, HostName | Format-Table -Property HostName, OSType, AgentVersion, RBSUpgradeStatus, Connectivity, Cluster, "Manual Validation Recommended" -AutoSize

if (-not [string]::IsNullOrWhiteSpace($ExportPath)) {
    if (-not (Test-Path $ExportPath)) { New-Item -ItemType Directory -Path $ExportPath | Out-Null }
    
    $timestamp = Get-Date -Format "yyyyMMdd_HHmm"
    $runtime   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $saAccount = Split-Path $ServiceAccountFile -Leaf
    
    $csvFile = Join-Path $ExportPath "Rubrik_RBS_Report_$timestamp.csv"
    $htmlFile = Join-Path $ExportPath "Rubrik_RBS_Report_$timestamp.html"

    # Export CSV
    $headerData = "Report Date: $runtime`nRSC Instance URL: $rscInstanceUrl`nService Account: $saAccount`n"
    $headerData | Set-Content $csvFile
    $finalReport | ConvertTo-Csv -NoTypeInformation | Select-Object -Skip 1 | Add-Content $csvFile
    
    # Build Interactive Sortable HTML Report
    $htmlHead = @"
<html>
<head>
<title>Rubrik RBS Report</title>
<style>
    body { font-family: 'Segoe UI', Tahoma, Arial, sans-serif; margin: 30px; background-color: #f4f7f9; }
    h2 { color: #005a9c; margin-bottom: 25px; border-bottom: 2px solid #005a9c; padding-bottom: 10px; }
    .meta-box { background: white; padding: 15px; border-radius: 8px; margin-bottom: 25px; border: 1px solid #d1d9e0; box-shadow: 0 2px 4px rgba(0,0,0,0.05); }
    .meta-item { margin-bottom: 5px; font-size: 0.95em; color: #444; }
    table { border-collapse: collapse; width: 100%; background: white; border-radius: 8px; overflow: hidden; box-shadow: 0 4px 6px rgba(0,0,0,0.1); }
    th { background-color: #005a9c; color: white; font-size: 0.85em; text-transform: uppercase; letter-spacing: 0.05em; cursor: pointer; position: relative; padding: 12px 15px; text-align: left; }
    th:hover { background-color: #004a82; }
    th::after { content: ' \2195'; font-size: 0.8em; opacity: 0.5; }
    th.no-sort { cursor: default; }
    th.no-sort:hover { background-color: #005a9c; }
    th.no-sort::after { content: ''; }
    td { border-bottom: 1px solid #e1e4e8; padding: 12px 15px; text-align: left; }
    tr:nth-child(even) { background-color: #f8f9fa; }
    tr:hover { background-color: #f1f8ff; }
</style>
<script>
    function sortTable(n) {
        if (n === 4) return;
        var table, rows, switching, i, x, y, shouldSwitch, dir, switchcount = 0;
        table = document.querySelector("table");
        switching = true;
        dir = "asc";
        while (switching) {
            switching = false;
            rows = table.rows;
            for (i = 1; i < (rows.length - 1); i++) {
                shouldSwitch = false;
                x = rows[i].getElementsByTagName("TD")[n];
                y = rows[i + 1].getElementsByTagName("TD")[n];
                if (dir == "asc") {
                    if (x.innerHTML.toLowerCase() > y.innerHTML.toLowerCase()) {
                        shouldSwitch = true;
                        break;
                    }
                } else if (dir == "desc") {
                    if (x.innerHTML.toLowerCase() < y.innerHTML.toLowerCase()) {
                        shouldSwitch = true;
                        break;
                    }
                }
            }
            if (shouldSwitch) {
                rows[i].parentNode.insertBefore(rows[i + 1], rows[i]);
                switching = true;
                switchcount ++;
            } else {
                if (switchcount == 0 && dir == "asc") {
                    dir = "desc";
                    switching = true;
                }
            }
        }
    }
    document.addEventListener("DOMContentLoaded", function() {
        let headers = document.querySelectorAll("th");
        headers.forEach((header, index) => {
            if (index === 4) {
                header.classList.add("no-sort");
            } else {
                header.addEventListener("click", () => sortTable(index));
            }
        });
    });
</script>
</head>
<body>
    <h2>Rubrik RBS Agent Version Report</h2>
    <div class='meta-box'>
        <div class='meta-item'><strong>RSC Instance URL:</strong> <a href='$rscInstanceUrl'>$rscInstanceUrl</a></div>
        <div class='meta-item'><strong>Execution Date/Time:</strong> $runtime</div>
        <div class='meta-item'><strong>Service Account Used:</strong> $saAccount</div>
        <div class='meta-item' style='margin-top:10px; font-style:italic; color:#005a9c;'>Note: Click column headers to sort (Connectivity sorting disabled).</div>
    </div>
"@
    
    $finalReport | Sort-Object OSType, HostName | 
        Select-Object HostName, OSType, AgentVersion, RBSUpgradeStatus, Connectivity, Cluster, "Manual Validation Recommended" | 
        ConvertTo-Html -Head $htmlHead | Out-File $htmlFile
    
    Write-Host " - CSV Exported: $(Split-Path $csvFile -Leaf)" -ForegroundColor Gray
    Write-Host " - HTML Exported: $(Split-Path $htmlFile -Leaf)" -ForegroundColor Gray
}
