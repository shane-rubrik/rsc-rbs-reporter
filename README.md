📊 Rubrik RSC: RBS Agent Version Reporter

This PowerShell tool provides a centralized report of Rubrik Backup Service (RBS) versions across your entire environment. It queries Rubrik Security Cloud (RSC) via GraphQL to identify which Windows and Linux hosts are up to date and which ones need attention.

🚀 Features

* *Unified View*: Consolidation of Windows and Linux/Unix physical hosts in one report.

* *Outlier Detection*: Automatically flags hosts with version 8.x, Unknown versions, or Unknown upgrade statuses.

* *Interactive HTML*: Generates a professional, sortable HTML report for easy sharing.

* *CSV Support*: Exports data with full execution metadata for audit trails.

* *Secure*: Built to work with encrypted Service Account keys—no plain-text passwords required.

📋 Prerequisites

Before running the script, ensure you have the following ready:

1. PowerShell 7.x (Required)
This script uses modern PowerShell features. Standard Windows PowerShell 5.1 is not supported.

* [Download PowerShell 7](https://www.google.com/search?q=https://github.com/PowerShell/PowerShell%23get-powershell)

2. Rubrik Security Cloud SDKOpen PowerShell 7 and run:

`Install-Module -Name RubrikSecurityCloud -Scope CurrentUser -AllowClobber`

3. RSC Service Account

You need a "Service Account" to talk to Rubrik via the API:

1. Log into your Rubrik Security Cloud tenant.
2. Navigate to SLA Management > Service Accounts.
3. Create a new account and assign the Global Read-Only role.
4. Download the JSON Key File to your computer.

🔐 Setup & Security

Step 1: Encrypt your JSON Key ⚠️

To keep your environment secure, you must encrypt the key so it only works on your specific machine.

Run this command in PowerShell to create a "Protected" version of your key:

`Protect-RscServiceAccountFile -Path "C:\Downloads\original-key.json" -OutPath "C:\scripts\rsc-creds-encrypted.json"`

Step 2: Prepare the Script

Download Get-RscHostRbsVersion.ps1 from this repository and save it to your scripts folder.

💻 Usage

Run the script by pointing it to your *encrypted* JSON file and a folder where you want the reports saved:

`.\Get-RscHostRbsVersion.ps1 -ServiceAccountFile "C:\scripts\rsc-creds-encrypted.json" -ExportPath "C:\Reports"`

Understanding the "Manual Validation" Column

The script is smart. It will automatically populate the "Manual Validation Recommended" column if it detects any of the following:

Outdated Version: The host is reporting an older 8.x version.
Status Unknown: The host is connected but the upgrade state is unclear.
Missing Metadata: The version cannot be determined via the API.

📄 LicenseThis project is licensed under the MIT License. See the LICENSE file for the full text.

Disclaimer: This is a community-driven tool and is not an official Rubrik product. Always test scripts in a non-production environment first.
