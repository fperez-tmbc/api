---
name: pdq-deploy-cli
description: Reference for the PDQ Deploy command-line interface (PDQDeploy.exe). Use this skill whenever an IT admin asks you to push software, patch machines, run remediation, or otherwise script PDQ Deploy. Typical workflows include deploying a package (Adobe Reader, Chrome, Java, custom MSI/EXE installers) to one or many computers; triggering existing schedules and weekly update runs; emergency security patching across the fleet; vulnerability remediation in response to a CVE alert from PDQ Detect, Slack, ServiceNow/Jira, or PagerDuty; package library management (export/import between Deploy servers, wildcard backups, deleting obsolete packages, approving auto-downloads); workstation onboarding and new-branch provisioning (deploying a standard software stack to new machines); help-desk fixes (redeploying a broken Zoom, VPN, Office, or browser install on a specific computer); querying deployment status for one or many deployments; bulk operations driven by spreadsheets/CSV, Notion runbooks, GitHub PRs, or M365 calendar triggers (Patch Tuesday); managing custom variables across staging/production environments; rotating service-account or deploy credentials from a PAM tool (CyberArk, BeyondTrust); and database maintenance (backup, integrity check, repair, optimize, restore, send-to-support). Pairs naturally with the PDQ Inventory CLI for fleet-wide workflows like wake-then-patch, compliance reporting, and decommission.
---

# PDQ Deploy CLI

*Last updated: 2026-06-01*

This file documents every command exposed by `PDQDeploy.exe` (the PDQ Deploy command-line interface). It is shipped alongside `PDQDeploy.exe` inside the PDQ Deploy install directory so AI coding agents can discover it automatically.

## Overview

PDQ Deploy is a Windows software-deployment tool from PDQ.com. The product ships with two main executables:

- `PDQDeployConsole.exe` - the WPF console UI.
- `PDQDeploy.exe` - the command-line interface (this skill).

The CLI exists alongside `PDQInventory.exe` (a sibling product) but is independent. Many PDQ Deploy CLI commands accept the same kinds of inputs as Inventory's CLI (computer names, credential names, custom variables), but credentials, schedules, and packages are managed separately per product.

Default install location: `C:\Program Files (x86)\Admin Arsenal\PDQ Deploy\`. The install directory is on the system `PATH`, so `PDQDeploy <command>` works from any shell.

## Prerequisites

1. **Run as Administrator.** Every CLI command requires an elevated shell. PowerShell / `cmd.exe` started with "Run as administrator" satisfies this.
2. **Background service running.** Most commands talk to the PDQ Deploy background service (a Windows service named `PDQDeploy`). If a command needs the service and it is stopped, you will get an error. Database maintenance commands (`OptimizeDatabase`, `RepairDatabase`, `RestoreDatabase`, `SetServiceCredentials`) are the main exceptions and operate directly on the database.
3. **License.** Many commands marked **License: Enterprise** below require a PDQ Deploy Enterprise license. Commands marked **Free** work on any license tier.
4. **RBAC.** When Role-Based Access Control (RBAC) is enabled, the calling Windows user must have the appropriate permission for the action (e.g., "Modify Packages" to delete or import packages).

## Common Patterns

These patterns apply to most or all CLI commands:

- **Case-insensitive.** Command names and parameter names are case-insensitive. `PDQDeploy deploy`, `PDQDeploy Deploy`, and `PDQDeploy DEPLOY` are equivalent.
- **Parameter abbreviation.** Parameters can be abbreviated to any unambiguous prefix. For example, `-T` is fine for `-Targets` when no other parameter starts with `T`. Spell parameters out in scripts for clarity.
- **String arrays.** Parameters that accept multiple values are space-separated, e.g., `-Targets PC1 PC2 PC3`. Some newer commands accept comma-separated lists instead (notably `-Name` on `DeletePackages`, `ExportPackages`, `ImportPackages`); the command reference below calls out which.
- **Quoting.** Wrap any value containing spaces in double quotes, e.g., `"Adobe Reader"`. Wildcards (`*`, `?`) are supported by commands that explicitly say so.
- **Exit codes.** `0` always means success. Non-zero exit codes are command-specific; see each command's Exit Codes section. Many commands return only `0` (success) or `1` (failure); commands with richer outcomes document additional codes.
- **Audit logging.** When audit logging is enabled, write actions (deploy, package deletes/imports, credential changes, settings exports, deletions, etc.) are recorded with the calling user and the fact that the action came from the CLI.


## Documentation Links

- CLI reference (HTML): bundled with the product as `Deploy_Help.exe` in the install directory.

---

# Commands

Commands are listed alphabetically. For each command: **Description**, **License** (Free or Enterprise), **Syntax**, **Parameters**, optional **Exit Codes**, **Examples**, and optional **Notes**.

## ApproveAutoDownloads

**Description:** Lists or approves pending auto-downloaded package versions.
**License:** Free
**Syntax:** `PDQDeploy ApproveAutoDownloads [-All] [-Package <packageName>] [-Force]`

**Parameters:**

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-All` | No | Approve all packages with pending auto-download versions. |
| `-Package` | No | Package name(s) to approve. Accepts exact names, wildcard patterns (e.g. `Adobe*`), and comma-separated values for multiple packages. |
| `-Force` | No | Skip the confirmation prompt. Use in automated workflows to prevent interactive prompts. |

**Exit Codes:**

| Code | Meaning |
|------|---------|
| 0 | Success. All specified packages were approved, or pending approvals were listed. |
| 1 | One or more packages failed to approve, or one or more specified packages were not found. |
| 2 | User cancelled at the confirmation prompt. |
| 3 | No packages pending approval were found. |

**Examples:**

- `PDQDeploy ApproveAutoDownloads` - List all packages pending approval.
- `PDQDeploy ApproveAutoDownloads -All` - Approve all pending auto-download packages.
- `PDQDeploy ApproveAutoDownloads -All -Force` - Approve all pending packages without confirmation (for automated workflows).
- `PDQDeploy ApproveAutoDownloads -Package "Google Chrome"` - Approve a specific package.
- `PDQDeploy ApproveAutoDownloads -Package "Adobe*"` - Approve all Adobe packages using a wildcard.

**Notes:**

- Approving auto-downloaded packages requires the "Modify Packages" RBAC permission. Package approvals are recorded in the audit log when audit logging is enabled.

## BackgroundService

**Description:** Manages the PDQ Deploy background service.
**License:** Free
**Syntax:** `PDQDeploy BackgroundService [-Start] [-Stop] [-Restart] [-User <username>] [-Password <password>]`

**Parameters:**

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-Start` | No | Starts the background service if it is not already running. |
| `-Stop` | No | Stops the background service if it is running. |
| `-Restart` | No | Stops and then starts the background service. |
| `-User <username>` | No | Sets the Windows account used to run the background service. Use `DOMAIN\username` format. When specified, you will be prompted for the password unless `-Password` is also provided. |
| `-Password <password>` | No | Password for the account specified with `-User`. If omitted when `-User` is specified, you will be prompted interactively. |

**Examples:**

- `PDQDeploy BackgroundService` - Show the account the background service is running under.
- `PDQDeploy BackgroundService -Stop`
- `PDQDeploy BackgroundService -Start`
- `PDQDeploy BackgroundService -Restart`
- `PDQDeploy BackgroundService -User DOMAIN\svcaccount -Password MyP@ssword` - Set new service account credentials.

## BackupDatabase

**Description:** Creates an on-demand backup of the PDQ Deploy database.
**License:** Free
**Syntax:** `PDQDeploy BackupDatabase [-Path <path>] [-Force]`

**Parameters:**

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-Path` | No | Path for the backup. Supports absolute and relative paths. Paths ending with a separator (`\` or `/`) are treated as directories; a timestamped filename is generated. Paths with a file extension are used as the exact backup file path. Paths without a trailing separator and without an extension are treated as a file path with `.db` appended. If not specified, uses the configured backup directory from Options > Database Settings. |
| `-Force` | No | Creates parent directories without prompting when the specified path does not exist. Use this flag for unattended scripts and scheduled tasks. |

**Exit Codes:**

| Code | Meaning |
|------|---------|
| 0 | Backup completed successfully. |
| 1 | Backup failed (general error). |
| 2 | Insufficient disk space to write the backup. |
| 3 | Insufficient permissions to write to the specified location. |
| 4 | Invalid or inaccessible path. Also returned when the directory creation prompt is cancelled. |
| 5 | Database is locked or in use and cannot be backed up. |
| 6 | Default backup path is not configured. Use `-Path` to specify a backup location, or configure a backup directory in Options > Database Settings. |

**Examples:**

- `PDQDeploy BackupDatabase` - Backup to the configured backup directory.
- `PDQDeploy BackupDatabase -Path "C:\Backups\PDQ\"` - Backup to a specific directory (filename is generated automatically).
- `PDQDeploy BackupDatabase -Path "C:\Backups\pre-upgrade-backup.db"` - Backup to a specific file.
- `PDQDeploy BackupDatabase -Path "C:\Backups\PDQ\" -Force` - Backup to a new directory without prompting.

**Notes:**

- The backup uses SQLite's built-in hot backup API, which allows the database to remain in use during the backup. It is not necessary to stop the background service before running this command.
- Every backup is verified with an integrity check before the command returns. If the backup is corrupted the file is deleted and the command returns exit code 1.
- When `-Path` is not specified, this command applies the configured `Keep` retention setting (deleting oldest backups). When `-Path` is specified, retention is not applied. The `Last backup` timestamp shown in Options > Database Settings is not updated by this command - that timestamp belongs to the automatic backup schedule and is only updated when a scheduled or `Backup Now` backup runs through the background service.
- Backup compression (`.db.cab`) is not applied by the CLI even when Compress backups is enabled in Options > Database Settings. CLI backups are always written as uncompressed `.db` files.

## CheckDatabase

**Description:** Runs a SQLite integrity check on the PDQ Deploy database and reports whether the database is healthy or corrupt.
**License:** Free
**Syntax:** `PDQDeploy CheckDatabase [-Verbose]`

**Parameters:**

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-Verbose` | No | When specified, outputs the raw integrity check output from SQLite in addition to the pass/fail result. |

**Examples:**

- `PDQDeploy CheckDatabase` - Check the database for corruption.
- `PDQDeploy CheckDatabase -Verbose` - Check the database and show detailed output.

**Notes:**

- If corruption is found, use `RepairDatabase` to attempt recovery.

## CleanUnusedRepoFiles

**Description:** Identifies files in the PDQ Deploy repository that are no longer referenced by any package, then optionally deletes them to free disk space.
**License:** Free
**Syntax:** `PDQDeploy CleanUnusedRepoFiles [-Force] [-WhatIf]`

**Parameters:**

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-Force` | No | Skips the `[y/N]` confirmation prompt and deletes unused files immediately. Use this flag for automated scheduled tasks where no interactive input is available. |
| `-WhatIf` | No | Lists the unused files and total space that would be freed, but does not delete anything. Use this to preview the cleanup before committing. |

**Exit Codes:**

| Code | Meaning |
|------|---------|
| 0 | Command completed successfully. Files were deleted, or `-WhatIf` was specified (no deletion performed). |
| 1 | Cleanup failed or partially failed. One or more files could not be deleted. |
| 2 | User cancelled at the confirmation prompt. |
| 3 | No unused files were found. Nothing to clean up. |

**Examples:**

- `PDQDeploy CleanUnusedRepoFiles -WhatIf` - Preview which files would be deleted without deleting anything.
- `PDQDeploy CleanUnusedRepoFiles` - Run interactively with a confirmation prompt.
- `PDQDeploy CleanUnusedRepoFiles -Force` - Run silently for use in a scheduled task.

**Notes:**

- Repository cleanup exclusions configured in the console (Options > Repository Cleanup > Exclusions) are respected by this command.

## ConsoleUsers

**Description:** Lists, adds, or removes console users in PDQ Deploy.
**License:** Enterprise
**Syntax:** `PDQDeploy ConsoleUsers [-Add <username>] [-Delete <username>] [-Password <password>]`

**Parameters:**

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-Add <username>` | No | Adds the specified Windows account as a console user. Use `DOMAIN\username` format. |
| `-Delete <username>` | No | Removes the specified Windows account from the console users list. |
| `-Password <password>` | No | Password for the background service account, used to authorize the change. If omitted and required, you will be prompted interactively. |

**Examples:**

- `PDQDeploy ConsoleUsers` - List all console users.
- `PDQDeploy ConsoleUsers -Add DOMAIN\jsmith`
- `PDQDeploy ConsoleUsers -Delete DOMAIN\jsmith`

## CreateCustomVariable

**Description:** Creates a new custom variable in PDQ Deploy with the specified name and value.
**License:** Enterprise
**Syntax:** `PDQDeploy CreateCustomVariable -Name <variableName> [-Value <variableValue>] [-Force]`

**Parameters:**

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-Name` | Yes | The name for the new custom variable. Cannot be empty or contain `@`, `$`, `(`, or `)` characters. |
| `-Value` | No | The value to assign to the variable. Defaults to an empty string if not specified. Wrap in double quotes if the value contains spaces. |
| `-Force` | No | Overwrites the variable if it already exists. Without this flag, the command exits with code 3 if the variable already exists. |

**Exit Codes:**

| Code | Meaning |
|------|---------|
| 0 | Variable created (or updated with `-Force`) successfully. |
| 1 | Unexpected error. |
| 2 | Invalid variable name format. |
| 3 | Variable already exists and `-Force` was not specified. |

**Examples:**

- `PDQDeploy CreateCustomVariable -Name InstallServer -Value "\\fileserver\share"` - Create a variable with a value.
- `PDQDeploy CreateCustomVariable -Name EmptyVar` - Create a variable with an empty value.
- `PDQDeploy CreateCustomVariable -Name AppVersion -Value 2.1.0 -Force` - Create or overwrite a variable.

**Notes:**

- To update an existing variable without creating it, you can also use `UpdateCustomVariable`.

## Database

**Description:** Opens the PDQ Deploy database directly in the bundled `sqlite3.exe` command line tool.
**License:** Free
**Syntax:** `PDQDeploy Database`

**Parameters:** None.

**Examples:**

- `PDQDeploy Database` - Opens the database in sqlite3.

**Notes:**

- Directly modifying the database can cause data corruption or unexpected behavior. Only use this command when instructed to do so by PDQ Support.

## DatabaseCleanup

**Description:** Runs a multi-step cleanup process on the PDQ Deploy database to remove stale data and improve performance.
**License:** Enterprise
**Syntax:** `PDQDeploy DatabaseCleanup`

**Parameters:** None.

**Examples:**

- `PDQDeploy DatabaseCleanup`

**Notes:**

- After running `DatabaseCleanup`, consider also running `OptimizeDatabase` to reclaim the freed disk space.

## DeletePackages

**Description:** Deletes one or more packages from PDQ Deploy.
**License:** Free
**Syntax:** `PDQDeploy DeletePackages -Name <packageName> [-Force] [-Format json]`

**Parameters:**

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-Name` | Yes | One or more package names to delete. Use commas to separate multiple names. Supports wildcard patterns (`*` and `?`). |
| `-Force` | No | Skips the confirmation prompt and allows deletion of packages that are used as nested steps in other packages. Packages with running deployments cannot be deleted even with `-Force`. |
| `-Format` | No | Output format. Specify `json` to receive a structured JSON result containing per-package status, a summary, the exit code, and its description. When using JSON output, confirmation prompts are written to stderr so that stdout contains only the JSON. |

**Exit Codes:**

| Code | Meaning |
|------|---------|
| 0 | All packages were deleted successfully. |
| 1 | One or more packages failed to delete or were not found. |
| 2 | User cancelled at the confirmation prompt. |
| 3 | No packages were found matching the specified name(s). |
| 4 | One or more packages were skipped due to active deployments. |
| 5 | One or more packages were skipped because they are used as nested steps in other packages. Use `-Force` to delete them anyway. |

**Examples:**

- `PDQDeploy DeletePackages -Name "Adobe Reader"` - Delete a single package (prompts for confirmation).
- `PDQDeploy DeletePackages -Name "Adobe Reader" -Force` - Delete a package without prompting.
- `PDQDeploy DeletePackages -Name "Chrome*" -Force` - Delete all packages matching a wildcard pattern.
- `PDQDeploy DeletePackages -Name "7-Zip","Notepad++" -Force` - Delete multiple named packages.
- `PDQDeploy DeletePackages -Name "Chrome*" -Force -Format json` - Delete packages and receive structured JSON output (suitable for automation).

**Notes:**

- Deleting packages requires the `Modify Packages` RBAC permission. All deletions are recorded in the PDQ Deploy audit log.

## DeleteScheduleHistory

**Description:** Deletes the deployment history for a specific computer from one schedule or from all schedules.
**License:** Enterprise
**Syntax:** `PDQDeploy DeleteScheduleHistory <computer> { -AllSchedules | -Schedule <scheduleId> }`

**Parameters:**

| Parameter | Required | Description |
|-----------|----------|-------------|
| `<computer>` | Yes | The name of the computer whose deployment history will be deleted. Both the full FQDN and short name are matched. |
| `-AllSchedules` | One of the two | Deletes the computer's history from every schedule. Cannot be combined with `-Schedule`. |
| `-Schedule <scheduleId>` | One of the two | Deletes the computer's history from the specified schedule only. Use `GetSchedules` to find schedule IDs. Cannot be combined with `-AllSchedules`. |

**Examples:**

- `PDQDeploy DeleteScheduleHistory WORKSTATION01 -AllSchedules` - Delete deployment history for `WORKSTATION01` from all schedules.
- `PDQDeploy DeleteScheduleHistory WORKSTATION01 -Schedule 5` - Delete history for `WORKSTATION01` from schedule ID 5 only.

## Deploy

**Description:** Deploys a PDQ Deploy package to one or more target computers immediately.
**License:** Enterprise
**Syntax:** `PDQDeploy Deploy <package> -Targets <computer> [<computer> ...] [-UserName <credentials>] [-NotificationName <notification>] [-OverrideTargetFilters] [-UseScanUserCredentials] [-PrioritizeDeployment]`

**Parameters:**

| Parameter | Required | Description |
|-----------|----------|-------------|
| `<package>` | Yes | The name or numeric ID of the package to deploy. Wrap names containing spaces in double quotes. |
| `-Targets` | Yes | One or more target computer names, separated by spaces. |
| `-UserName` | No | The name of the credentials to use for the deployment. If omitted, the default credentials are used. |
| `-NotificationName` | No | The name of an email notification to send when the deployment completes. Requires a configured mail server. |
| `-OverrideTargetFilters` | No | When specified, deploys to all listed targets regardless of any target filters configured on the package. |
| `-UseScanUserCredentials` | No | When specified, uses the PDQ Inventory scan user credentials for the deployment. |
| `-PrioritizeDeployment` | No | When specified, moves the deployment to the front of the queue ahead of non-prioritized deployments. Equivalent to using `Prioritize Deployment` in the console UI. |

**Examples:**

- `PDQDeploy Deploy "7-Zip 23.01" -Targets WORKSTATION01` - Deploy a package by name to a single computer.
- `PDQDeploy Deploy "7-Zip 23.01" -Targets WORKSTATION01 WORKSTATION02 WORKSTATION03` - Deploy to multiple computers.
- `PDQDeploy Deploy "7-Zip 23.01" -Targets WORKSTATION01 -UserName "Domain Admin"` - Deploy using specific credentials.
- `PDQDeploy Deploy "7-Zip 23.01" -Targets WORKSTATION01 WORKSTATION02 -PrioritizeDeployment` - Deploy and prioritize ahead of queued deployments.

**Notes:**

- The `Deploy` command targets computers by name only. To deploy to Target Lists, PDQ Inventory collections, or other dynamic groups, use `StartSchedule` with a schedule that already has those targets configured.

## ExportPackages

**Description:** Exports one or more package definitions to XML files.
**License:** Free
**Syntax:** `PDQDeploy ExportPackages -Name <packageName> -Path <outputPath> [-Overwrite]`

**Parameters:**

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-Name` | Yes | One or more package names to export. Use commas to separate multiple names. Supports wildcard patterns (`*` and `?`). |
| `-Path` | Yes | Output file path or directory. For a single package, this can be a full file path or a directory (the package name is used as the file name). For multiple packages, this must be a directory. |
| `-Overwrite` | No | Overwrite existing files without prompting. Without this flag, existing files will cause an error (single package with prompt) or be skipped (multiple packages). |

**Exit Codes:**

| Code | Meaning |
|------|---------|
| 0 | All packages were exported successfully. |
| 1 | One or more packages failed to export. |
| 2 | User cancelled at the overwrite confirmation prompt. |
| 3 | No packages found matching the specified name(s). |
| 4 | One or more packages were skipped because output files already exist. Use `-Overwrite` to replace existing files. |

**Examples:**

- `PDQDeploy ExportPackages -Name "Adobe Reader" -Path C:\Exports\AdobeReader.xml` - Export a single package to a specific file.
- `PDQDeploy ExportPackages -Name "Adobe Reader" -Path C:\Exports` - Export a single package to a directory (auto-generates filename).
- `PDQDeploy ExportPackages -Name "Adobe*" -Path C:\Exports` - Export all packages matching a wildcard pattern.
- `PDQDeploy ExportPackages -Name "7-Zip","Notepad++" -Path C:\Exports` - Export multiple named packages.
- `PDQDeploy ExportPackages -Name "Adobe Reader" -Path C:\Exports -Overwrite` - Export and overwrite existing files.

## ExportSettings

**Description:** Exports all PDQ Deploy preferences and configuration settings to a single XML file.
**License:** Enterprise
**Syntax:** `PDQDeploy ExportSettings -Path <outputPath> [-Overwrite]`

**Parameters:**

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-Path` | Yes | Output file path or directory. If a directory is specified, the file is written as `settings.xml` inside it. Parent directories are created if they do not exist. Both absolute and relative paths are supported. |
| `-Overwrite` | No | Replace the destination file if it already exists. Without this flag, the command exits with an error if the file is already present. |

**Exit Codes:**

| Code | Meaning |
|------|---------|
| 0 | Settings exported successfully. |
| 1 | Export failed (I/O error, insufficient permissions, disk space issue, or database unavailable/locked). |
| 2 | File already exists and `-Overwrite` was not specified. |
| 3 | Path is invalid or inaccessible (invalid characters, path too long, or a parent directory could not be created). |

**Examples:**

- `PDQDeploy ExportSettings -Path C:\Backups\PDQDeploy\settings.xml` - Export all settings to a specific file.
- `PDQDeploy ExportSettings -Path C:\Backups\PDQDeploy` - Export all settings to a directory (writes `settings.xml` inside it).
- `PDQDeploy ExportSettings -Path .\backup\settings.xml -Overwrite` - Export and overwrite an existing file.

**Notes:**

- `ExportSettings` actions are recorded in the audit log when audit logging is enabled.

## ExportVariables

**Description:** Exports custom variable definitions to a single XML file. Use this command to synchronize variables between isolated or air-gapped networks, version-control variable configurations, or support infrastructure-as-code workflows. Operates on custom variables only - system variables are read-only and are not included in the export.
**License:** Enterprise
**Syntax:** `PDQDeploy ExportVariables [-Name <variable>[,<variable>...]] -Path <outputPath> [-Overwrite]`

**Parameters:**

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-Name <variable> ...` | No | One or more custom variable names to export, comma-separated. Supports wildcard patterns (`*` and `?`). Omit to export all custom variables. |
| `-Path <outputPath>` | Yes | Output file path or directory. If a directory is supplied, the file is written as `Variables.xml` inside it. If a file path is supplied, it is used as-is. All matched variables are written to a single file. |
| `-Overwrite` | No | Overwrite the output file if it already exists. Without this flag, the command exits with an error if the file already exists. |

**Exit Codes:**

| Code | Meaning |
|------|---------|
| 0 | Export succeeded. |
| 1 | One or more variables failed to export, or one or more named variables were not found. |
| 3 | No variables found matching the specified name(s). |
| 4 | The output file already exists. Use `-Overwrite` to replace it. |

**Examples:**

- `PDQDeploy ExportVariables -Path C:\Exports` - Export all custom variables to a directory (writes `Variables.xml`).
- `PDQDeploy ExportVariables -Path C:\Exports\Variables.xml` - Export all custom variables to a specific file.
- `PDQDeploy ExportVariables -Name "BuildServer" -Path C:\Exports\Variables.xml` - Export a single named variable.
- `PDQDeploy ExportVariables -Name "Build*" -Path C:\Exports` - Export all variables whose names match a wildcard pattern.
- `PDQDeploy ExportVariables -Name "Var1","Var2" -Path C:\Exports -Overwrite` - Export multiple named variables, overwriting any existing file.

**Notes:**

- The exported file can be re-imported with the `ImportVariables` command.

## GetDeploymentStatus

**Description:** Returns status information for one or more deployments.
**License:** Enterprise
**Syntax:** `PDQDeploy GetDeploymentStatus { -Id <id[,id,...]> | -Name <packageName> | -PackageId <id> | -Running } [-All] [-Status <status>] [-Since <value>] [-Limit <count>] [-IncludeTargets] [-Json | -Csv]`

**Parameters:**

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-Id` | One of these four | Deployment ID or comma-separated list of IDs to query. |
| `-Name` | One of these four | Package name. Returns the most recent deployment for that package. Use `-All` to return the full deployment history. Supports wildcard patterns (e.g., `Adobe*`), which return the most recent deployment for each matching package (or all deployments with `-All`). |
| `-PackageId` | One of these four | Package ID. Returns the most recent deployment for that package. Use `-All` to return the full deployment history. |
| `-Running` | One of these four | Show all currently running or queued deployments. |
| `-All` | No | Return all deployments instead of only the most recent. Only valid with `-Name` or `-PackageId`. |
| `-Status` | No | Filter results by status. Accepted values: `Succeeded`, `Failed`, `Running`. Can be used alone to list all deployments matching that status. |
| `-Since` | No | Filter to deployments created on or after a point in time. Accepts a date string (e.g., `2026-01-01`) or ISO 8601 duration relative to now (e.g., `P1D` for the past day, `PT2H` for the past 2 hours). |
| `-Json` | No | Output results in JSON format for parsing by external tools. |
| `-Csv` | No | Output results in CSV format for spreadsheet import. |
| `-IncludeTargets` | No | Include per-target status details in the output. Supported with default text and `-Json` output. Cannot be combined with `-Csv`. |
| `-Limit` | No | Maximum number of deployments to return when listing results (default: 500). Must be a positive integer. |

**Exit Codes:**

| Code | Meaning |
|------|---------|
| 0 | Deployment succeeded (all targets successful), or list shown successfully. |
| 1 | Deployment failed (one or more targets failed). Only applies when querying a single deployment by `-Id`. |
| 2 | Deployment is still running or queued. Only applies when querying a single deployment by `-Id`. |
| 3 | Deployment not found. |

**Examples:**

- `PDQDeploy GetDeploymentStatus -Id 42` - Check the status of a specific deployment.
- `PDQDeploy GetDeploymentStatus -Id 42,43,44` - Check multiple deployments at once.
- `PDQDeploy GetDeploymentStatus -Name "Adobe Reader"` - Get the most recent deployment for a package by name.
- `PDQDeploy GetDeploymentStatus -Name "Adobe*"` - Get the most recent deployment for all packages matching a wildcard.
- `PDQDeploy GetDeploymentStatus -PackageId 7` - Get the most recent deployment for a package by ID.
- `PDQDeploy GetDeploymentStatus -Running` - List all currently running or queued deployments.
- `PDQDeploy GetDeploymentStatus -Status Failed -Since P7D` - List all failed deployments from the past 7 days.
- `PDQDeploy GetDeploymentStatus -Id 42 -Json` - Get deployment status in JSON format for script processing.
- `PDQDeploy GetDeploymentStatus -Running -Csv` - List running deployments as CSV for a spreadsheet.
- `PDQDeploy GetDeploymentStatus -Id 42 -IncludeTargets` - Show per-target details for a deployment.

**Notes:**

- Exit codes 1 and 2 only apply when querying a single deployment by ID. When listing multiple deployments or using `-Running`, `-Status`, or `-Since`, the command always exits with code 0 on success.

## GetPackageNames

**Description:** Lists the names of all packages in PDQ Deploy, sorted alphabetically.
**License:** Free
**Syntax:** `PDQDeploy GetPackageNames`

**Parameters:** None.

**Examples:**

- `PDQDeploy GetPackageNames` - List all package names.
- `PDQDeploy GetPackageNames | findstr /i "chrome"` - The output lists one package name per line, which can be piped to other commands in a script.

## GetSchedules

**Description:** Lists all PDQ Deploy schedules with their numeric IDs and names.
**License:** Enterprise
**Syntax:** `PDQDeploy GetSchedules`

**Parameters:** None.

**Examples:**

- `PDQDeploy GetSchedules` - List all schedules to find the ID for a specific schedule.

## Help

**Description:** Displays available commands and their license requirements.
**License:** Free
**Syntax:** `PDQDeploy Help [<CommandName>]`

**Parameters:**

| Parameter | Required | Description |
|-----------|----------|-------------|
| `<CommandName>` | No | The name of a specific command to show usage for. When omitted, all available commands are listed. |

**Examples:**

- `PDQDeploy Help` - List all available commands.
- `PDQDeploy Help Deploy` - Show usage for a specific command.

## ImportPackages

**Description:** Imports one or more package definitions from XML files.
**License:** Free
**Syntax:** `PDQDeploy ImportPackages -Path <inputPath> [-Overwrite] [-SkipExisting]`

**Parameters:**

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-Path` | Yes | Path to an XML file or a directory containing import files. When a directory is specified, all supported import files (`.xml`, `.pdqi`, `.pdqinstaller`, `.pdqdld`, `.pdqpkg`) in that directory are imported. |
| `-Overwrite` | No | Replace existing packages (matched by name) with the imported definitions. Without this flag, duplicate names receive a numeric suffix. |
| `-SkipExisting` | No | Skip packages that already exist (by name) instead of creating duplicates. Skipped packages are listed in the output. |

**Exit Codes:**

| Code | Meaning |
|------|---------|
| 0 | All packages were imported successfully. |
| 1 | One or more packages failed to import. |
| 3 | No importable files found at the specified path. |

**Examples:**

- `PDQDeploy ImportPackages -Path C:\Exports\AdobeReader.xml` - Import a single package file.
- `PDQDeploy ImportPackages -Path C:\Exports` - Import all package files from a directory.
- `PDQDeploy ImportPackages -Path C:\Exports -Overwrite` - Import and overwrite existing packages.
- `PDQDeploy ImportPackages -Path C:\Exports -SkipExisting` - Import and skip packages that already exist.

**Notes:**

- Importing packages requires the `Modify Packages` RBAC permission. Package imports are recorded in the audit log when audit logging is enabled.

## ImportVariables

**Description:** Imports custom variable definitions from an XML file produced by `ExportVariables`. By default, variables whose names already exist are skipped. Use `-Overwrite` to replace existing variables instead.
**License:** Enterprise
**Syntax:** `PDQDeploy ImportVariables -Path <inputFile> [-Overwrite | -SkipExisting]`

**Parameters:**

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-Path <inputFile>` | Yes | Path to an XML file produced by `ExportVariables`. |
| `-Overwrite` | No | Replace existing variables (matched by name) with the imported definitions. Cannot be combined with `-SkipExisting`. |
| `-SkipExisting` | No | Explicit form of the default behavior: skip variables that already exist. Cannot be combined with `-Overwrite`. |

**Exit Codes:**

| Code | Meaning |
|------|---------|
| 0 | Import succeeded. |
| 1 | One or more variables failed to import, or the input file was malformed. |
| 3 | The input file contained no importable variable definitions. |

**Examples:**

- `PDQDeploy ImportVariables -Path C:\Exports\Variables.xml` - Import variables, skipping any that already exist (default).
- `PDQDeploy ImportVariables -Path C:\Exports\Variables.xml -Overwrite` - Import variables, overwriting any with matching names.
- `PDQDeploy ImportVariables -Path C:\Exports\Variables.xml -SkipExisting` - Import variables and be explicit about skipping existing names.

**Notes:**

- Custom variables can be created with `CreateCustomVariable` and exported with `ExportVariables`.

## OptimizeDatabase

**Description:** Runs a SQLite `VACUUM` operation on the PDQ Deploy database to reclaim unused disk space and improve query performance.
**License:** Free
**Syntax:** `PDQDeploy OptimizeDatabase [-Wait]`

**Parameters:**

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-Wait` | No | When specified, pauses and waits for the user to press Enter after optimization completes. Useful when running from a shortcut or batch file where you want the window to stay open. |

**Examples:**

- `PDQDeploy OptimizeDatabase`
- `PDQDeploy OptimizeDatabase -Wait`

**Notes:**

- If the PDQ Deploy console is open, you will be prompted to close it before the optimization begins. If the background service is running, you will be prompted to stop it.

## ProfileBackgroundService

**Description:** Captures a performance profile of the PDQ Deploy background service for diagnostic purposes.
**License:** Free
**Syntax:** `PDQDeploy ProfileBackgroundService [-ProfileType <type>]`

**Parameters:**

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-ProfileType <type>` | No | The type of profile to capture. Currently only `CPU` is supported, and it is the default when this parameter is omitted. |

**Examples:**

- `PDQDeploy ProfileBackgroundService`
- `PDQDeploy ProfileBackgroundService -ProfileType CPU`

**Notes:**

- This command should only be used as directed by PDQ Support.

## RepairDatabase

**Description:** Attempts to recover the PDQ Deploy database from corruption by exporting it to SQL, then re-importing it into a new database file.
**License:** Free
**Syntax:** `PDQDeploy RepairDatabase`

**Parameters:** None.

**Examples:**

- `PDQDeploy RepairDatabase`

**Notes:**

- Use `RepairDatabase` only when PDQ Deploy is reporting database errors or failing to start. For routine maintenance, use `OptimizeDatabase` instead.

## RestoreDatabase

**Description:** Restores the PDQ Deploy database from a backup.
**License:** Free
**Syntax:** `PDQDeploy RestoreDatabase [-RestoreMostRecent]`

**Parameters:**

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-RestoreMostRecent` | No | Skips the interactive backup selection prompt and automatically restores the most recently modified backup file. |

**Examples:**

- `PDQDeploy RestoreDatabase` - Interactively select a backup to restore.
- `PDQDeploy RestoreDatabase -RestoreMostRecent` - Restore the most recent backup without prompting.

## SendDatabase

**Description:** Packages the PDQ Deploy database and related support files into a zip archive.
**License:** Free
**Syntax:** `PDQDeploy SendDatabase`

**Parameters:** None.

**Examples:**

- `PDQDeploy SendDatabase`

**Notes:**

- This command is typically used at the request of PDQ Support to help diagnose issues with your installation.

## SetServiceCredentials

**Description:** Updates the Windows account credentials used to run the PDQ Deploy background service.
**License:** Free
**Syntax:** `PDQDeploy SetServiceCredentials -Username <domain\username> [-Password <password>] [-SecurePassword] [-NoRestart]`

**Parameters:**

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-Username <username>` | Yes | The Windows account the service will run as. Use `DOMAIN\username` format for domain accounts, or `.\username` for local accounts. |
| `-Password <password>` | No | The new password for the account. If omitted and `-SecurePassword` is not set, you will be prompted interactively. WARNING: passwords passed on the command line may be visible in process listings and shell history. |
| `-SecurePassword` | No | Prompts for the password interactively. The password is not echoed to the screen. Use this flag instead of `-Password` to avoid exposing the password in command history. |
| `-NoRestart` | No | Applies the credential changes without restarting the background service. The new credentials will take effect the next time the service is restarted. |

**Exit Codes:**

| Code | Meaning |
|------|---------|
| 0 | Credentials updated successfully. |
| 1 | Failure. The account could not be validated, the service failed to restart, or another error occurred. Check the error message for details. |
| 2 | User cancelled at the interactive password prompt. |

**Examples:**

- `PDQDeploy SetServiceCredentials -Username DOMAIN\svcaccount -SecurePassword` - Update service credentials and prompt for the password securely.
- `PDQDeploy SetServiceCredentials -Username .\localuser -SecurePassword` - Update credentials for a local account.
- `PDQDeploy SetServiceCredentials -Username DOMAIN\svcaccount -Password MyP@ss -NoRestart` - Update credentials and skip the service restart.
- `Get-Secret -Name PDQServiceAccount | ConvertFrom-SecureString -AsPlainText | PDQDeploy SetServiceCredentials -Username DOMAIN\svcaccount` - Pipe the password from a PAM tool via stdin (most secure for scripting).

**Notes:**

- This command requires Administrator privileges and accesses the database directly (offline mode), so it does not require the background service to be running. If the service is running, it will be restarted automatically after the credential change to apply the new credentials, unless `-NoRestart` is specified.

## SetServiceMode

**Description:** Configures PDQ Deploy to run in Local, Client, or Server mode.
**License:** Enterprise
**Syntax:** `PDQDeploy SetServiceMode <ServiceMode>`

**Parameters:**

| Parameter | Required | Description |
|-----------|----------|-------------|
| `<ServiceMode>` | Yes | The service mode to configure. Accepted values: `Local`, `Client`, `Server`. |

**Examples:**

- `PDQDeploy SetServiceMode Local` - Switch to Local mode.
- `PDQDeploy SetServiceMode Client` - Configure as a client connecting to a remote server.
- `PDQDeploy SetServiceMode Server` - Configure as a server.

## Settings

**Description:** Reads or writes internal PDQ Deploy settings.
**License:** Free
**Syntax:** `PDQDeploy Settings [-Name <settingName>] [-Set <value>] [-Reset]`

**Parameters:**

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-Name <settingName>` | No | The name of the setting to read or modify. Required when using `-Set` or `-Reset`. |
| `-Set <value>` | No | The new value to assign to the setting specified by `-Name`. Cannot be combined with `-Reset`. |
| `-Reset` | No | Resets the setting specified by `-Name` to its default value. Cannot be combined with `-Set`. |

**Examples:**

- `PDQDeploy Settings` - List all settings.
- `PDQDeploy Settings -Name DeploymentSettings.CleanupDays` - Read a specific setting.
- `PDQDeploy Settings -Name DeploymentSettings.CleanupDays -Set 60` - Change a setting value.
- `PDQDeploy Settings -Name DeploymentSettings.CleanupDays -Reset` - Reset a setting to its default.
- `PDQDeploy Settings -Name FeatureFlag.EnableAuditLog -Set true` - Enable a feature flag (see Feature Flags above).

## StartSchedule

**Description:** Triggers an existing PDQ Deploy schedule to run immediately, deploying to all targets defined in that schedule.
**License:** Enterprise
**Syntax:** `PDQDeploy StartSchedule <scheduleId>`

**Parameters:**

| Parameter | Required | Description |
|-----------|----------|-------------|
| `<scheduleId>` | Yes | The numeric ID of the schedule to run. Use `GetSchedules` to find schedule IDs. |

**Examples:**

- `PDQDeploy GetSchedules` - First, find the ID of the schedule you want to run.
- `PDQDeploy StartSchedule 5` - Then trigger the schedule using its ID.

**Notes:**

- Unlike `Deploy`, `StartSchedule` respects all targets configured in the schedule, including Target Lists and PDQ Inventory collections.

## SystemInfo

**Description:** Outputs information about the PDQ Deploy installation, such as version, database path, service mode, and license details.
**License:** Free
**Syntax:** `PDQDeploy SystemInfo [<Item>]`

**Parameters:**

| Parameter | Required | Description |
|-----------|----------|-------------|
| `<Item>` | No | The name of a specific system info item to output. When omitted, all items and their values are listed. |

**Examples:**

- `PDQDeploy SystemInfo` - List all system info.
- `PDQDeploy SystemInfo Version` - Output a specific item.

## TestCredential

**Description:** Tests an existing deployment credential by attempting to connect to a target computer.
**License:** Free
**Syntax:** `PDQDeploy TestCredential -Name <credentialName> -Computer <computerName>`

**Parameters:**

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-Name <credentialName>` | Yes | The username of the credential to test (e.g., `DOMAIN\svcaccount`). This must match a credential already saved in PDQ Deploy. |
| `-Computer <computerName>` | Yes | The target computer to test connectivity against. Can be a hostname or IP address. |

**Exit Codes:**

| Code | Meaning |
|------|---------|
| 0 | The credential successfully connected to the target computer. |
| 1 | Failure. The credential was not found, the connection failed, access was denied, or another error occurred. |

**Examples:**

- `PDQDeploy TestCredential -Name DOMAIN\svcaccount -Computer WORKSTATION01` - Test a credential against a target computer.
- `PDQDeploy TestCredential -Name DOMAIN\svcaccount -Computer 192.168.1.50` - Test using an IP address.

**Notes:**

- The PDQ Deploy background service must be running for this command to work. The credential name must exactly match the username stored in PDQ Deploy Preferences > Credentials.

## UpdateCustomVariable

**Description:** Updates the value of an existing custom variable in PDQ Deploy.
**License:** Free
**Syntax:** `PDQDeploy UpdateCustomVariable <Name> <Value>`

**Parameters:**

| Parameter | Required | Description |
|-----------|----------|-------------|
| `<Name>` | Yes | The name of the custom variable to update. The variable must already exist. |
| `<Value>` | Yes | The new value to assign to the variable. Wrap in double quotes if the value contains spaces. |

**Examples:**

- `PDQDeploy UpdateCustomVariable InstallServer "\\fileserver\share"` - Set a custom variable to a new value.
- `PDQDeploy UpdateCustomVariable AppVersion 2.1.0`

**Notes:**

- This command updates an existing variable only. To create a new variable, use the PDQ Deploy console or the `CreateCustomVariable` command. The `CreateCustomVariable` command with the `-Force` flag can also update existing variables. This command is retained for backwards compatibility.

## UpdateDeployCredential

**Description:** Updates an existing deployment credential stored in PDQ Deploy.
**License:** Free
**Syntax:** `PDQDeploy UpdateDeployCredential -Name <credentialName> [-Username <domain\username>] [-Password <password>] [-SecurePassword] [-CreateIfNotExists]`

**Parameters:**

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-Name <credentialName>` | Yes | The username of the credential to update or create (e.g., `DOMAIN\svcaccount`). Must match an existing credential in PDQ Deploy unless `-CreateIfNotExists` is set. |
| `-Username <username>` | No | The new username to set on the credential. If omitted, the existing username is retained. Required when `-CreateIfNotExists` is used. |
| `-Password <password>` | No | The new password. If omitted and `-SecurePassword` is not set, you will be prompted interactively. WARNING: passwords passed on the command line may be visible in process listings and shell history. |
| `-SecurePassword` | No | Prompts for the password interactively. The password is not echoed to the screen. Recommended over `-Password` when running interactively. |
| `-CreateIfNotExists` | No | Creates the credential if no credential with the specified name exists. Requires `-Username` when creating. |

**Exit Codes:**

| Code | Meaning |
|------|---------|
| 0 | Credential updated successfully. |
| 1 | Failure. The credential was not found, the save failed, or another error occurred. |
| 2 | User cancelled at the interactive password prompt. |

**Examples:**

- `PDQDeploy UpdateDeployCredential -Name DOMAIN\svcaccount -SecurePassword` - Update the password for an existing credential interactively.
- `Get-Secret -Name DeployAccount | ConvertFrom-SecureString -AsPlainText | PDQDeploy UpdateDeployCredential -Name DOMAIN\svcaccount` - Update a credential password from a PAM tool via stdin.
- `PDQDeploy UpdateDeployCredential -Name DOMAIN\oldsvc -Username DOMAIN\newsvc -SecurePassword` - Update both the username and password.
- `PDQDeploy UpdateDeployCredential -Name DOMAIN\svcaccount -Username DOMAIN\svcaccount -SecurePassword -CreateIfNotExists` - Create a credential if it does not already exist.

**Notes:**

- The PDQ Deploy background service must be running for this command to work. The credential name (`-Name`) must exactly match the username stored in PDQ Deploy Preferences > Credentials.
