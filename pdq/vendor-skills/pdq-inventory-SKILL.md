---
name: pdq-inventory-cli
description: Reference for the PDQ Inventory command-line interface (PDQInventory.exe). Use this skill whenever an IT admin asks you to scan, audit, discover, or otherwise script PDQ Inventory. Typical workflows include scanning specific computers or whole collections (with `-Wait` for blocking pipelines that need fresh data before the next step); network discovery on subnets or IP ranges to find rogue/new devices; adding new computers and decommissioning retired ones; listing collections and the computers in a collection; pulling detailed computer info (OS, hardware, current user, AD info, IP/MAC) for compliance reports, license true-ups, auditor requests, or pre-deploy verification; Active Directory synchronization to pick up new accounts; running auto reports for scheduled exports and email notifications; importing custom field data from CSV (asset tags, departments, lease end dates, FDA classifications) and creating custom fields/variables to support those imports; Wake-on-LAN to bring offline machines online ahead of patching; cross-referencing inventory with PDQ Detect, Snipe-IT, ServiceNow, or Splunk to find unprotected/non-compliant systems; generating fleet dashboards for Power BI/Grafana or Slack standup posts; rotating scan credentials from a PAM tool (CyberArk, BeyondTrust); and database maintenance (backup, integrity check, repair, optimize, restore, send-to-support). Pairs naturally with the PDQ Deploy CLI for fleet-wide workflows like discover-then-deploy, vulnerability remediation, and onboarding.
---

# PDQ Inventory CLI

*Last updated: 2026-06-01*

This file documents every command exposed by `PDQInventory.exe` (the PDQ Inventory command-line interface). It is shipped alongside `PDQInventory.exe` inside the PDQ Inventory install directory so AI coding agents can discover it automatically.

## Overview

PDQ Inventory is a Windows system-inventory and asset-management tool from PDQ.com. The product ships with several executables; the two you interact with directly are:

- `PDQInventoryConsole.exe` - the WPF console UI.
- `PDQInventory.exe` - the command-line interface (this skill).

The CLI exists alongside `PDQDeploy.exe` (a sibling product) but is independent. Many PDQ Inventory CLI commands accept the same kinds of inputs as Deploy's CLI (computer names, credential names, custom variables), but collections, scan profiles, custom fields, and scan credentials live inside PDQ Inventory.

Default install location: `C:\Program Files (x86)\Admin Arsenal\PDQ Inventory\`. The install directory is on the system `PATH`, so `PDQInventory <command>` works from any shell.

## Prerequisites

1. **Run as Administrator.** Every CLI command requires an elevated shell. PowerShell / `cmd.exe` started with "Run as administrator" satisfies this.
2. **Background service running.** Most commands talk to the PDQ Inventory background service (a Windows service named `PDQInventory`). If a command needs the service and it is stopped, you will get an error. Database maintenance commands (`OptimizeDatabase`, `RepairDatabase`, `RestoreDatabase`, `SetServiceCredentials`) are the main exceptions and operate directly on the database.
3. **License.** Many commands marked **License: Enterprise** below require a PDQ Inventory Enterprise license. Commands marked **Free** work on any license tier.
4. **RBAC.** When Role-Based Access Control (RBAC) is enabled, the calling Windows user must have the appropriate permission for the action (e.g., "Modify Collections" to import collections).

## Common Patterns

These patterns apply to most or all CLI commands:

- **Case-insensitive.** Command names and parameter names are case-insensitive. `PDQInventory scancomputers`, `PDQInventory ScanComputers`, and `PDQInventory SCANCOMPUTERS` are equivalent.
- **Parameter abbreviation.** Parameters can be abbreviated to any unambiguous prefix. For example, `-C` is fine for `-Computers` when no other parameter starts with `C`. Spell parameters out in scripts for clarity.
- **String arrays.** Parameters that accept multiple values are space-separated, e.g., `-Computers PC1 PC2 PC3`. A few newer commands accept comma-separated lists instead (e.g., `-Name` on `ExportCollections`); the command reference below calls out which.
- **Quoting.** Wrap any value containing spaces in double quotes, e.g., `"Windows 10"`. Wildcards (`*`, `?`) are supported by commands that explicitly say so.
- **Output formats.** Several long-running commands (`ScanComputers`, `ScanCollections`, `GetNetworkDiscoveryStatus`) support `-Json`, `-Csv`, and `-Brief` flags for machine-readable output. Prefer these in scripts.
- **Exit codes.** `0` always means success. `1` typically means a failure. `2` and `3` are reused by several commands for timeout/cancel and not-found respectively, but exact meanings are command-specific - see each command's Exit Codes section.
- **Audit logging.** When audit logging is enabled, write actions (computer deletions, credential updates, settings exports, collection imports, auto-report runs, etc.) are recorded with the calling user and the fact that the action came from the CLI.


## Documentation Links

- CLI reference (HTML): bundled with the product as `Inventory_Help.exe` in the install directory.

---

# Commands

Commands are listed alphabetically. For each command: **Description**, **License** (Free or Enterprise), **Syntax**, **Parameters**, optional **Exit Codes**, **Examples**, and optional **Notes**.

## ADSync

**Description:** Triggers an Active Directory synchronization in PDQ Inventory. This is the command-line equivalent of manually starting an AD sync from the console.
**License:** Enterprise
**Syntax:** `PDQInventory ADSync [-StartSync]`

**Parameters:**

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-StartSync` | No | Starts the Active Directory synchronization immediately. If omitted, the command returns without performing a sync. |

**Examples:**

- `PDQInventory ADSync -StartSync` - Start an Active Directory sync.

## AddComputers

**Description:** Adds one or more computers to PDQ Inventory and triggers a scan using the default scan profile. DNS resolution is performed for each computer before it is added.
**License:** Free
**Syntax:** `PDQInventory AddComputers -Computers <computer1> [<computer2> ...] [-Credential <name>] [-IgnoreDnsErr] [-IgnoreDuplicates]`

**Parameters:**

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-Computers <computer> ...` | Yes | One or more computer names or hostnames to add, separated by spaces. |
| `-Credential <name>` | No | Name of the scan credential to assign to the added computers (e.g., `DOMAIN\ScanUser`). Must match an existing credential name in PDQ Inventory. If omitted, the computers use the default scan credential. |
| `-IgnoreDnsErr` | No | Adds computers even if DNS resolution fails. Without this flag, any computer that cannot be resolved in DNS will cause the command to fail. |
| `-IgnoreDuplicates` | No | Skips computers that already exist in PDQ Inventory rather than returning an error. |

**Examples:**

- `PDQInventory AddComputers -Computers WORKSTATION01` - Add a single computer.
- `PDQInventory AddComputers -Computers WORKSTATION01 WORKSTATION02 SERVER01` - Add multiple computers at once.
- `PDQInventory AddComputers -Computers WORKSTATION01 -Credential DOMAIN\ScanUser` - Add a computer and assign a specific scan credential.
- `PDQInventory AddComputers -Computers WORKSTATION01 WORKSTATION02 -IgnoreDuplicates -IgnoreDnsErr` - Add computers, skipping any that already exist or cannot be resolved in DNS.

**Notes:**

- Each successfully added computer is immediately queued for a scan using the default scan profile.

## BackgroundService

**Description:** Manages the PDQ Inventory background service. Without any parameters, outputs the Windows account the background service is running under.
**License:** Free
**Syntax:** `PDQInventory BackgroundService [-Start] [-Stop] [-Restart] [-User <username>] [-Password <password>]`

**Parameters:**

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-Start` | No | Starts the background service if it is not already running. |
| `-Stop` | No | Stops the background service if it is running. |
| `-Restart` | No | Stops and then starts the background service. |
| `-User <username>` | No | Sets the Windows account used to run the background service. Use `DOMAIN\username` format. When specified, you will be prompted for the password unless `-Password` is also provided. |
| `-Password <password>` | No | Password for the account specified with `-User`. If omitted when `-User` is specified, you will be prompted interactively. |

**Examples:**

- `PDQInventory BackgroundService` - Show the account the background service is running under.
- `PDQInventory BackgroundService -Stop`
- `PDQInventory BackgroundService -Start`
- `PDQInventory BackgroundService -Restart`
- `PDQInventory BackgroundService -User DOMAIN\svcaccount -Password MyP@ssword` - Set new service account credentials.

## BackupDatabase

**Description:** Creates an on-demand backup of the PDQ Inventory database. This is the command-line equivalent of the `Backup Now` button in Options > Database Settings.
**License:** Enterprise
**Syntax:** `PDQInventory BackupDatabase [-Path <path>] [-Force]`

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

- `PDQInventory BackupDatabase` - Backup to the configured backup directory.
- `PDQInventory BackupDatabase -Path "C:\Backups\PDQ\"` - Backup to a specific directory (filename is generated automatically).
- `PDQInventory BackupDatabase -Path "C:\Backups\pre-upgrade-backup.db"` - Backup to a specific file.
- `PDQInventory BackupDatabase -Path "C:\Backups\PDQ\" -Force` - Backup to a new directory without prompting.

**Notes:**

- The backup uses SQLite's built-in hot backup API, which allows the database to remain in use during the backup. It is not necessary to stop the background service before running this command.
- Every backup is verified with an integrity check before the command returns. If the backup is corrupted the file is deleted and the command returns exit code 1.
- When `-Path` is not specified, this command applies the configured `Keep` retention setting (deleting oldest backups). When `-Path` is specified, retention is not applied. The `Last backup` timestamp shown in Options > Database Settings is not updated by this command - that timestamp belongs to the automatic backup schedule and is only updated when a scheduled or `Backup Now` backup runs through the background service.
- Backup compression (`.db.cab`) is not applied by the CLI even when Compress backups is enabled in Options > Database Settings. CLI backups are always written as uncompressed `.db` files.

## CheckDatabase

**Description:** Runs a SQLite integrity check on the PDQ Inventory database and reports whether the database is healthy or corrupt. If corruption is detected, you are prompted to submit the database to PDQ support for analysis.
**License:** Free
**Syntax:** `PDQInventory CheckDatabase [-Verbose]`

**Parameters:**

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-Verbose` | No | When specified, outputs the raw integrity check output from SQLite in addition to the pass/fail result. |

**Examples:**

- `PDQInventory CheckDatabase` - Check the database for corruption.
- `PDQInventory CheckDatabase -Verbose` - Check the database and show detailed output.

**Notes:**

- If corruption is found, use `RepairDatabase` to attempt recovery.

## ConsoleUsers

**Description:** Lists, adds, or removes console users in PDQ Inventory. Console users are Windows accounts authorized to connect to the PDQ Inventory background service from the console.
**License:** Enterprise
**Syntax:** `PDQInventory ConsoleUsers [-Add <username>] [-Delete <username>] [-Password <password>]`

**Parameters:**

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-Add <username>` | No | Adds the specified Windows account as a console user. Use `DOMAIN\username` format. |
| `-Delete <username>` | No | Removes the specified Windows account from the console users list. |
| `-Password <password>` | No | Password for the background service account, used to authorize the change. If omitted and required, you will be prompted interactively. |

**Examples:**

- `PDQInventory ConsoleUsers` - List all console users.
- `PDQInventory ConsoleUsers -Add DOMAIN\jsmith`
- `PDQInventory ConsoleUsers -Delete DOMAIN\jsmith`

## CreateCustomField

**Description:** Creates a new custom field of the specified type. Custom fields allow you to store and display additional per-computer data in PDQ Inventory.
**License:** Enterprise
**Syntax:** `PDQInventory CreateCustomField <name> <type>`

**Parameters:**

| Parameter | Required | Description |
|-----------|----------|-------------|
| `<name>` | Yes | The name for the new custom field. Must be unique. |
| `<type>` | Yes | The data type of the custom field. Accepted values: `Boolean`, `Date`, `DateTime`, `Integer`, `String`. |

**Examples:**

- `PDQInventory CreateCustomField Department String` - Create a text custom field named `Department`.
- `PDQInventory CreateCustomField "Lease End" Date` - Create a date custom field named `Lease End`.

**Notes:**

- After creating a custom field, use `ImportCustomFields` to populate it with data from a CSV file.

## CreateCustomVariable

**Description:** Creates a new custom variable in PDQ Inventory with the specified name and value. If the variable already exists, the command fails unless `-Force` is specified.
**License:** Enterprise
**Syntax:** `PDQInventory CreateCustomVariable -Name <variableName> [-Value <variableValue>] [-Force]`

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

- `PDQInventory CreateCustomVariable -Name ScanServer -Value "\\scanserver\share"` - Create a variable with a value.
- `PDQInventory CreateCustomVariable -Name EmptyVar` - Create a variable with an empty value.
- `PDQInventory CreateCustomVariable -Name AgentVersion -Value 2.1.0 -Force` - Create or overwrite a variable.

**Notes:**

- To update an existing variable without creating it, you can also use `UpdateCustomVariable`.

## Database

**Description:** Opens the PDQ Inventory database directly in the bundled `sqlite3.exe` command-line tool. Intended for advanced troubleshooting; only use as directed by PDQ Support.
**License:** Free
**Syntax:** `PDQInventory Database`

**Parameters:** None.

**Examples:**

- `PDQInventory Database`

**Notes:**

- Directly modifying the database can cause data corruption or unexpected behavior. Only use this command when instructed to do so by PDQ Support.

## DatabaseCleanup

**Description:** Runs a multi-step cleanup process on the PDQ Inventory database to remove stale data and improve performance. Progress is reported to the console as each step completes.
**License:** Enterprise
**Syntax:** `PDQInventory DatabaseCleanup`

**Parameters:** None.

**Examples:**

- `PDQInventory DatabaseCleanup`

**Notes:**

- After running `DatabaseCleanup`, consider also running `OptimizeDatabase` to reclaim the freed disk space.

## DeleteComputers

**Description:** Deletes one or more computers from PDQ Inventory. Use this command to automate cleanup of decommissioned systems or integrate with external asset management workflows.
**License:** Free
**Syntax:** `PDQInventory DeleteComputers -Computers <computer1> [<computer2> ...] [-Force] [-StopOnError]`

**Parameters:**

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-Computers <computer> ...` | Yes | One or more computers to delete, separated by spaces. Each value can be a computer name (e.g., `WORKSTATION-01`) or a computer ID prefixed with `#` (e.g., `#12345`). Both forms can be combined in the same call. |
| `-Force` | No | Skips the `[y/N]` confirmation prompt and deletes computers immediately. Use this flag for automated scripts where no interactive input is available. |
| `-StopOnError` | No | Stops processing and returns an error if any specified computer is not found. Without this flag, not-found computers are reported but remaining computers are still deleted. |

**Exit Codes:**

| Code | Meaning |
|------|---------|
| 0 | Command completed successfully. All found computers were deleted. |
| 1 | Command failed. A computer was not found and `-StopOnError` was specified, or an unexpected error occurred. |
| 2 | User cancelled at the confirmation prompt. |
| 3 | No computers were found to delete. |

**Examples:**

- `PDQInventory DeleteComputers -Computers WORKSTATION01` - Delete a single computer by name.
- `PDQInventory DeleteComputers -Computers WORKSTATION01 WORKSTATION02 SERVER01` - Delete multiple computers at once.
- `PDQInventory DeleteComputers -Computers #12345` - Delete a computer by ID.
- `PDQInventory DeleteComputers -Computers WORKSTATION01 WORKSTATION02 -Force` - Delete computers silently for use in an automated script.
- `PDQInventory DeleteComputers -Computers WORKSTATION01 WORKSTATION02 -StopOnError` - Delete computers and stop immediately if any are not found.

**Notes:**

- All deletions are recorded in the audit log, including the computer name and that the action was performed via the command line.

## ExportCollections

**Description:** Exports one or more PDQ Inventory collections to XML files. Use this command to back up collection definitions or synchronize collections between isolated or air-gapped environments.
**License:** Enterprise
**Syntax:** `PDQInventory ExportCollections { -Name <collection>[,<collection>...] | -All } -Path <path> [-Overwrite]`

**Parameters:**

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-Name <collection> ...` | One of these two | One or more collection names to export, comma-separated. Supports wildcard patterns (e.g., `Windows*`). Required unless `-All` is specified. |
| `-All` | One of these two | Exports all collections. Cannot be combined with `-Name`. |
| `-Path <path>` | Yes | Output file path or directory. When exporting a single collection, this can be a full file path (e.g., `C:\Exports\Windows10.xml`) or a directory. When exporting multiple collections, this must be a directory. |
| `-Overwrite` | No | Overwrites existing output files without prompting. |

**Exit Codes:**

| Code | Meaning |
|------|---------|
| 0 | Command completed successfully. |
| 1 | One or more collections failed to export. |
| 2 | User cancelled at the overwrite confirmation prompt. |
| 3 | No collections found matching the specified name(s). |
| 4 | One or more collections were skipped because output files already exist. Use `-Overwrite` to replace existing files. |

**Examples:**

- `PDQInventory ExportCollections -Name "Windows 10" -Path C:\Exports` - Export a single collection to a directory.
- `PDQInventory ExportCollections -Name "Windows 10" -Path C:\Exports\Windows10.xml` - Export a single collection to a specific file.
- `PDQInventory ExportCollections -Name "Windows*" -Path C:\Exports` - Export all collections whose names start with `Windows`.
- `PDQInventory ExportCollections -Name "Windows 10","Servers" -Path C:\Exports` - Export multiple named collections.
- `PDQInventory ExportCollections -All -Path C:\Exports -Overwrite` - Export all collections and overwrite any existing files.

**Notes:**

- Each export includes the full collection hierarchy - child collections are embedded in their parent's export file. Exported files can be imported using the `ImportCollections` command.

## ExportSettings

**Description:** Exports all PDQ Inventory preferences and configuration settings to a single XML file. The output is equivalent to clicking Options > Preferences > Export All in the console, and can be re-imported via Options > Preferences > Import All.
**License:** Enterprise
**Syntax:** `PDQInventory ExportSettings -Path <outputPath> [-Overwrite]`

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

- `PDQInventory ExportSettings -Path C:\Backups\PDQInventory\settings.xml` - Export all settings to a specific file.
- `PDQInventory ExportSettings -Path C:\Backups\PDQInventory` - Export all settings to a directory (writes `settings.xml` inside it).
- `PDQInventory ExportSettings -Path .\backup\settings.xml -Overwrite` - Export and overwrite an existing file.

**Notes:**

- `ExportSettings` actions are recorded in the audit log when audit logging is enabled.

## ExportVariables

**Description:** Exports custom variable definitions to a single XML file. Use this command to synchronize variables between isolated or air-gapped networks, version-control variable configurations, or support infrastructure-as-code workflows. Operates on custom variables only - system variables are read-only and are not included in the export.
**License:** Enterprise
**Syntax:** `PDQInventory ExportVariables [-Name <variable>[,<variable>...]] -Path <outputPath> [-Overwrite]`

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

- `PDQInventory ExportVariables -Path C:\Exports` - Export all custom variables to a directory (writes `Variables.xml`).
- `PDQInventory ExportVariables -Path C:\Exports\Variables.xml` - Export all custom variables to a specific file.
- `PDQInventory ExportVariables -Name "BuildServer" -Path C:\Exports\Variables.xml` - Export a single named variable.
- `PDQInventory ExportVariables -Name "Build*" -Path C:\Exports` - Export all variables whose names match a wildcard pattern.
- `PDQInventory ExportVariables -Name "Var1","Var2" -Path C:\Exports -Overwrite` - Export multiple named variables, overwriting any existing file.

**Notes:**

- The exported file can be re-imported with the `ImportVariables` command.

## GetAllCollections

**Description:** Lists all collections in PDQ Inventory, including the built-in `All Computers` collection, sorted alphabetically by path.
**License:** Enterprise
**Syntax:** `PDQInventory GetAllCollections`

**Parameters:** None.

**Examples:**

- `PDQInventory GetAllCollections` - List all collections.
- `PDQInventory GetAllCollections | findstr /i "server"` - Pipe the output to find collections containing `Server`.

## GetAllComputers

**Description:** Lists the names of all computers in PDQ Inventory, sorted alphabetically.
**License:** Enterprise
**Syntax:** `PDQInventory GetAllComputers`

**Parameters:** None.

**Examples:**

- `PDQInventory GetAllComputers` - List all computers.
- `PDQInventory GetAllComputers | Measure-Object` - Count the total number of computers.

## GetAllScanProfiles

**Description:** Lists the names of all scan profiles defined in PDQ Inventory, sorted alphabetically. Use the output to find profile names for use with `ScanComputers` and `ScanCollections`.
**License:** Enterprise
**Syntax:** `PDQInventory GetAllScanProfiles`

**Parameters:** None.

**Examples:**

- `PDQInventory GetAllScanProfiles` - List all scan profiles.

## GetCollection

**Description:** Outputs details for a specific collection, including its name, path, ID, description, and computer count.
**License:** Enterprise
**Syntax:** `PDQInventory GetCollection <collection>`

**Parameters:**

| Parameter | Required | Description |
|-----------|----------|-------------|
| `<collection>` | Yes | The name, full path, or numeric ID of the collection. Use `GetAllCollections` to find collection names and paths. |

**Examples:**

- `PDQInventory GetCollection "Windows 10"` - Get details for a collection by name.
- `PDQInventory GetCollection "All Computers"` - Get details for the built-in All Computers collection.

## GetCollectionComputers

**Description:** Lists the names of all computers that are members of a specified collection, sorted alphabetically. Collection membership is refreshed before the list is returned.
**License:** Enterprise
**Syntax:** `PDQInventory GetCollectionComputers <collection>`

**Parameters:**

| Parameter | Required | Description |
|-----------|----------|-------------|
| `<collection>` | Yes | The name, full path, or numeric ID of the collection. Use `GetAllCollections` to find collection names. |

**Examples:**

- `PDQInventory GetCollectionComputers "Windows 10"` - List computers in the `Windows 10` collection.
- `PDQInventory GetCollectionComputers "All Computers"` - List all computers (using the built-in All Computers collection).

## GetComputer

**Description:** Outputs detailed information about a specific computer from PDQ Inventory, including operating system, Active Directory, and hardware details.
**License:** Enterprise
**Syntax:** `PDQInventory GetComputer <computer>`

**Parameters:**

| Parameter | Required | Description |
|-----------|----------|-------------|
| `<computer>` | Yes | The name or numeric ID of the computer to look up. |

**Examples:**

- `PDQInventory GetComputer WORKSTATION01` - Get details for a computer by name.

## GetNetworkDiscoveryStatus

**Description:** Returns status information for network discoveries. You can query by ID, list all currently running scans, or review recent discoveries. Supports multiple output formats for scripting.
**License:** Enterprise
**Syntax:** `PDQInventory GetNetworkDiscoveryStatus { -Id <id> | -Running | -Recent <count> } [-Json | -Csv | -Brief]`

**Parameters:**

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-Id <id>` | One of these three | The numeric discovery ID returned by `StartNetworkDiscovery`. |
| `-Running` | One of these three | Lists all discoveries that are currently queued, running, or paused. |
| `-Recent <count>` | One of these three | Lists the most recent discoveries. Specify the number to return (e.g., `-Recent 10` for the last 10). |
| `-Json` | No | Outputs results in JSON format for use with tools like `ConvertFrom-Json` in PowerShell. |
| `-Csv` | No | Outputs results in CSV format with a header row. |
| `-Brief` | No | Outputs one line per discovery showing only the ID and status, separated by a tab. |

**Exit Codes:**

| Code | Meaning |
|------|---------|
| 0 | Status retrieved successfully. When using `-Id`, indicates the discovery has finished or was aborted. |
| 2 | The discovery queried by `-Id` is still running or queued. Useful for polling in scripts. |
| 3 | The specified discovery ID was not found. |

**Examples:**

- `PDQInventory GetNetworkDiscoveryStatus -Id 42` - Check the status of a specific discovery.
- `PDQInventory GetNetworkDiscoveryStatus -Running` - List all currently running or queued discoveries.
- `PDQInventory GetNetworkDiscoveryStatus -Recent 5 -Json` - Show the 5 most recent discoveries in JSON format.
- `do { Start-Sleep 5 } while ((PDQInventory GetNetworkDiscoveryStatus -Id $id; $LASTEXITCODE) -eq 2)` - Poll until a discovery completes (PowerShell).

## GetOnlineComputers

**Description:** Lists the names of computers that PDQ Inventory currently considers online, sorted alphabetically. Optionally filter to only computers that have come online since a specific date and time.
**License:** Enterprise
**Syntax:** `PDQInventory GetOnlineComputers [-Since <datetime>]`

**Parameters:**

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-Since <datetime>` | No | Filters results to only computers that have come online since the specified date and time. |

**Examples:**

- `PDQInventory GetOnlineComputers` - List all currently online computers.
- `PDQInventory GetOnlineComputers -Since "2024-01-15 08:00"` - List computers that came online after a specific date.

## GetScanProfile

**Description:** Outputs the name, ID, and description for a scan profile.
**License:** Enterprise
**Syntax:** `PDQInventory GetScanProfile <scanprofile>`

**Parameters:**

| Parameter | Required | Description |
|-----------|----------|-------------|
| `<scanprofile>` | Yes | The name or numeric ID of the scan profile. Use `GetAllScanProfiles` to find profile names. |

**Examples:**

- `PDQInventory GetScanProfile "Standard"` - Get details for a specific scan profile by name.

## Help

**Description:** Displays available commands and their license requirements. When a command name is provided, outputs the usage text for that specific command including its syntax, parameters, and examples.
**License:** Free
**Syntax:** `PDQInventory Help [<CommandName>]`

**Parameters:**

| Parameter | Required | Description |
|-----------|----------|-------------|
| `<CommandName>` | No | The name of a specific command to show usage for. When omitted, all available commands are listed. |

**Examples:**

- `PDQInventory Help` - List all available commands.
- `PDQInventory Help ScanComputers` - Show usage for a specific command.

## ImportCollections

**Description:** Imports one or more PDQ Inventory collections from an exported XML file or a directory of export files. Use this command to restore collections from a backup or deploy standardized collection definitions across multiple PDQ Inventory instances.
**License:** Enterprise
**Syntax:** `PDQInventory ImportCollections -Path <path> [-Overwrite]`

**Parameters:**

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-Path <path>` | Yes | Path to a collection export file (`.xml`) or a directory containing export files. When a directory is specified, all `.xml` files in that directory are imported. |
| `-Overwrite` | No | Replaces existing collections (matched by name) with the imported definitions. Without this flag, collections that already exist are skipped and logged. |

**Exit Codes:**

| Code | Meaning |
|------|---------|
| 0 | Command completed successfully. |
| 1 | One or more collections failed to import. |
| 3 | No importable files found at the specified path. |

**Examples:**

- `PDQInventory ImportCollections -Path C:\Exports\Windows10.xml` - Import collections from a single file.
- `PDQInventory ImportCollections -Path C:\Exports` - Import all collection files from a directory.
- `PDQInventory ImportCollections -Path C:\Exports -Overwrite` - Import and replace any existing collections with the same name.

**Notes:**

- Importing collections requires the `Modify Collections` RBAC permission. All import operations are recorded in the audit log, including whether each collection was newly created or overwritten.

## ImportCustomFields

**Description:** Imports custom field values for computers from a CSV file. The CSV must contain a column that identifies each computer and one or more columns for the custom field values to import.
**License:** Enterprise
**Syntax:** `PDQInventory ImportCustomFields <filename> [-AllowOverwrite] [-ComputerColumn <header>] [-CustomFields <mappings>] [-NoHeader] [-Preview] [-WhatIf]`

**Parameters:**

| Parameter | Required | Description |
|-----------|----------|-------------|
| `<filename>` | Yes | Path to the CSV file to import. |
| `-AllowOverwrite` | No | Overwrites existing custom field values. Without this flag, existing values are preserved. |
| `-ComputerColumn <header>` | No | The CSV column header that contains computer names. Required when the CSV has multiple columns and PDQ Inventory cannot auto-detect which column holds computer names. |
| `-CustomFields <mappings>` | No | A comma-delimited list of `CSV Header=Custom Field` mappings. Used when CSV column names do not match custom field names exactly. For headerless CSVs, use column numbers: `2=Department,3=Location`. |
| `-NoHeader` | No | Indicates the CSV file has no header row. Columns are referenced by number when using `-CustomFields`. |
| `-Preview` | No | Shows which computers in the CSV were not found in PDQ Inventory and lists any column parsing errors, without saving any data. |
| `-WhatIf` | No | Equivalent to `-Preview`. Shows unmatched computers and column parsing errors without saving any data. |

**Examples:**

- `PDQInventory ImportCustomFields C:\data\departments.csv -Preview` - Preview an import to check for unmatched computers.
- `PDQInventory ImportCustomFields C:\data\departments.csv -ComputerColumn "PC Name" -AllowOverwrite` - Import using a specific computer column header and overwrite existing values.
- `PDQInventory ImportCustomFields C:\data\data.csv -ComputerColumn "Computer" -CustomFields "Dept=Department,Loc=Location"` - Import with explicit column-to-field mappings.

**Notes:**

- Custom fields must already exist before importing. Use `CreateCustomField` to create them first.

## ImportVariables

**Description:** Imports custom variable definitions from an XML file produced by `ExportVariables`. By default, variables whose names already exist are skipped. Use `-Overwrite` to replace existing variables instead.
**License:** Enterprise
**Syntax:** `PDQInventory ImportVariables -Path <inputFile> [-Overwrite | -SkipExisting]`

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

- `PDQInventory ImportVariables -Path C:\Exports\Variables.xml` - Import variables, skipping any that already exist (default).
- `PDQInventory ImportVariables -Path C:\Exports\Variables.xml -Overwrite` - Import variables, overwriting any with matching names.
- `PDQInventory ImportVariables -Path C:\Exports\Variables.xml -SkipExisting` - Import variables and be explicit about skipping existing names.

**Notes:**

- Custom variables can be created with `CreateCustomVariable` and exported with `ExportVariables`.

## OptimizeDatabase

**Description:** Runs a SQLite `VACUUM` operation on the PDQ Inventory database to reclaim unused disk space and improve query performance. This stops the PDQ Inventory background service, optimizes the database, then restarts the service.
**License:** Free
**Syntax:** `PDQInventory OptimizeDatabase [-Wait]`

**Parameters:**

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-Wait` | No | When specified, pauses and waits for the user to press Enter after optimization completes. Useful when running from a shortcut or batch file where you want the window to stay open. |

**Examples:**

- `PDQInventory OptimizeDatabase`
- `PDQInventory OptimizeDatabase -Wait`

**Notes:**

- If the PDQ Inventory console is open, you will be prompted to close it before the optimization begins. If the background service is running, you will be prompted to stop it.

## ProfileBackgroundService

**Description:** Captures a performance profile of the PDQ Inventory background service for diagnostic purposes. After the profile is started, you perform the actions that reproduce the performance issue, then press Enter to stop profiling. The resulting profile file path is printed to the console.
**License:** Free
**Syntax:** `PDQInventory ProfileBackgroundService [-ProfileType <type>]`

**Parameters:**

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-ProfileType <type>` | No | The type of profile to capture. Currently only `CPU` is supported, and it is the default when this parameter is omitted. |

**Examples:**

- `PDQInventory ProfileBackgroundService`
- `PDQInventory ProfileBackgroundService -ProfileType CPU`

**Notes:**

- This command should only be used as directed by PDQ Support.

## RepairDatabase

**Description:** Attempts to recover the PDQ Inventory database from corruption by exporting it to SQL, then re-importing it into a new database file. The original database is backed up before any changes are made.
**License:** Free
**Syntax:** `PDQInventory RepairDatabase`

**Parameters:** None.

**Examples:**

- `PDQInventory RepairDatabase`

**Notes:**

- Use `RepairDatabase` only when PDQ Inventory is reporting database errors or failing to start. For routine maintenance, use `OptimizeDatabase` instead.

## RestoreDatabase

**Description:** Restores the PDQ Inventory database from a backup. By default, presents an interactive list of available backups and prompts you to select one. The selected backup is integrity-checked before the restore is performed, and the current database is renamed before being replaced.
**License:** Free
**Syntax:** `PDQInventory RestoreDatabase [-RestoreMostRecent]`

**Parameters:**

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-RestoreMostRecent` | No | Skips the interactive backup selection prompt and automatically restores the most recently modified backup file. |

**Examples:**

- `PDQInventory RestoreDatabase` - Interactively select a backup to restore.
- `PDQInventory RestoreDatabase -RestoreMostRecent` - Restore the most recent backup without prompting.

## RunAutoReport

**Description:** Manually triggers an auto report to run immediately, executing all configured reports, file saves, and email notifications. By default the command returns once the auto report is queued. Use `-Wait` to block until all reports complete and display per-report results.
**License:** Enterprise
**Syntax:** `PDQInventory RunAutoReport { -Name <autoReport> | -Id <id> } [-Wait] [-Timeout <seconds>]`

**Parameters:**

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-Name <autoReport>` | One of these two | The name of the auto report to run. Required if `-Id` is not specified. If neither is specified, available auto reports are listed. |
| `-Id <id>` | One of these two | The numeric ID of the auto report to run. Required if `-Name` is not specified. |
| `-Wait` | No | Blocks until all reports in the auto report complete, then displays per-report results including status and any errors. Without this flag the command returns immediately after queuing. |
| `-Timeout <seconds>` | No | Maximum number of seconds to wait before returning. If the auto report has not completed within this period the command exits with code 2; the auto report continues running in the background. Requires `-Wait`. |

**Exit Codes:**

| Code | Meaning |
|------|---------|
| 0 | Auto report queued successfully, or all reports completed successfully when using `-Wait`. |
| 1 | Auto report not found, or one or more reports failed. Only returned when using `-Wait`. |
| 2 | Timeout reached before the auto report completed. Only returned when using `-Wait` with `-Timeout`. |
| 3 | User cancelled the wait with Ctrl+C. Only returned when using `-Wait`. |

**Examples:**

- `PDQInventory RunAutoReport -Name "Weekly Report"` - Queue an auto report by name.
- `PDQInventory RunAutoReport -Name "Weekly Report" -Wait` - Queue an auto report and wait for all reports to complete.
- `PDQInventory RunAutoReport -Name "Weekly Report" -Wait -Timeout 600` - Wait up to 10 minutes for the auto report to complete before returning.
- `PDQInventory RunAutoReport -Id 5` - Queue an auto report by ID.
- `PDQInventory RunAutoReport` - List all available auto reports.

**Notes:**

- Running this command generates an audit log entry recording that the auto report was triggered via the CLI.

## ScanCollections

**Description:** Queues a scan for all computers in one or more collections. By default the command returns once scans are queued. Use `-Wait` to block until all scans complete and display per-computer results. If no scan profile is specified, the default scan profile is used.
**License:** Enterprise
**Syntax:** `PDQInventory ScanCollections -Collections <collection1> [<collection2> ...] [-ScanProfile <profile>] [-Wait] [-Quiet] [-Timeout <seconds>] [-Json | -Csv | -Brief]`

**Parameters:**

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-Collections <collection> ...` | Yes | One or more collection names or paths to scan, separated by spaces. Use `GetAllCollections` to find collection names. |
| `-ScanProfile <profile>` | No | The name or ID of the scan profile to use. Defaults to the default scan profile if not specified. Use `GetAllScanProfiles` to find profile names. |
| `-Wait` | No | Blocks until all scans complete, then displays per-computer results including status, duration, and any errors. Without this flag the command returns immediately after queuing scans. |
| `-Quiet` | No | Suppresses the real-time progress display while waiting. Requires `-Wait`. |
| `-Timeout <seconds>` | No | Maximum number of seconds to wait before returning current status. Incomplete scans are reported as `Timeout`. Requires `-Wait`. |
| `-Json` | No | Outputs scan results in JSON format. Mutually exclusive with `-Csv` and `-Brief`. Requires `-Wait`. |
| `-Csv` | No | Outputs scan results in CSV format. Mutually exclusive with `-Json` and `-Brief`. Requires `-Wait`. |
| `-Brief` | No | Outputs one status line per computer. Mutually exclusive with `-Json` and `-Csv`. Requires `-Wait`. |

**Exit Codes:**

| Code | Meaning |
|------|---------|
| 0 | All scans queued successfully, or all scans completed successfully when using `-Wait`. |
| 1 | One or more scans failed. Only returned when using `-Wait`. |
| 2 | Timeout reached before all scans completed. Only returned when using `-Wait` with `-Timeout`. |
| 3 | User cancelled the wait with Ctrl+C. Running scans are aborted. Only returned when using `-Wait`. |

**Examples:**

- `PDQInventory ScanCollections -Collections "Windows 10"` - Scan all computers in the `Windows 10` collection using the default scan profile.
- `PDQInventory ScanCollections -Collections "Windows 10" Servers -ScanProfile "Standard"` - Scan multiple collections using a specific scan profile.
- `PDQInventory ScanCollections -Collections "Windows 10" -Wait` - Scan and wait for completion before continuing.
- `PDQInventory ScanCollections -Collections Servers -ScanProfile "Standard" -Wait -Timeout 300 -Json` - Scan, wait up to 5 minutes, and output results as JSON for automated processing.

## ScanComputers

**Description:** Queues a scan for one or more specific computers. By default the command returns once scans are queued. Use `-Wait` to block until all scans complete and display per-computer results. If no scan profile is specified, the default scan profile is used.
**License:** Enterprise
**Syntax:** `PDQInventory ScanComputers -Computers <computer1> [<computer2> ...] [-ScanProfile <profile>] [-IgnoreNotFound] [-Wait] [-Quiet] [-Timeout <seconds>] [-Json | -Csv | -Brief]`

**Parameters:**

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-Computers <computer> ...` | Yes | One or more computer names or IDs to scan, separated by spaces. |
| `-ScanProfile <profile>` | No | The name or ID of the scan profile to use. Defaults to the default scan profile if not specified. Use `GetAllScanProfiles` to find profile names. |
| `-IgnoreNotFound` | No | Skips computers that do not exist in PDQ Inventory rather than returning an error. |
| `-Wait` | No | Blocks until all scans complete, then displays per-computer results including status, duration, and any errors. Without this flag the command returns immediately after queuing scans. |
| `-Quiet` | No | Suppresses the real-time progress display while waiting. Requires `-Wait`. |
| `-Timeout <seconds>` | No | Maximum number of seconds to wait before returning current status. Incomplete scans are reported as `Timeout`. Requires `-Wait`. |
| `-Json` | No | Outputs scan results in JSON format. Mutually exclusive with `-Csv` and `-Brief`. Requires `-Wait`. |
| `-Csv` | No | Outputs scan results in CSV format. Mutually exclusive with `-Json` and `-Brief`. Requires `-Wait`. |
| `-Brief` | No | Outputs one status line per computer. Mutually exclusive with `-Json` and `-Csv`. Requires `-Wait`. |

**Exit Codes:**

| Code | Meaning |
|------|---------|
| 0 | All scans queued successfully, or all scans completed successfully when using `-Wait`. |
| 1 | One or more scans failed. Only returned when using `-Wait`. |
| 2 | Timeout reached before all scans completed. Only returned when using `-Wait` with `-Timeout`. |
| 3 | User cancelled the wait with Ctrl+C. Running scans are aborted. Only returned when using `-Wait`. |

**Examples:**

- `PDQInventory ScanComputers -Computers WORKSTATION01` - Scan a single computer using the default scan profile.
- `PDQInventory ScanComputers -Computers WORKSTATION01 SERVER01 -ScanProfile "Standard"` - Scan multiple computers with a specific scan profile.
- `PDQInventory ScanComputers -Computers (Get-Content computers.txt) -IgnoreNotFound` - Scan a list of computers from a text file, ignoring any not found in Inventory.
- `PDQInventory ScanComputers -Computers WORKSTATION01 SERVER01 -Wait` - Scan and wait for completion before continuing.
- `PDQInventory ScanComputers -Computers WORKSTATION01 SERVER01 -ScanProfile "Standard" -Wait -Timeout 300 -Json` - Scan, wait up to 5 minutes, and output results as JSON for automated processing.

## SendDatabase

**Description:** Packages the PDQ Inventory database and related support files into a zip archive. The path to the local zip file is displayed so you can send it manually. The folder containing the zip file is opened automatically on completion.
**License:** Free
**Syntax:** `PDQInventory SendDatabase`

**Parameters:** None.

**Examples:**

- `PDQInventory SendDatabase`

**Notes:**

- This command is typically used at the request of PDQ Support to help diagnose issues with your installation.

## SetServiceCredentials

**Description:** Updates the Windows account credentials used to run the PDQ Inventory background service. This command is designed for automated password rotation workflows and integration with Password Access Management (PAM) solutions.
**License:** Free
**Syntax:** `PDQInventory SetServiceCredentials -Username <domain\username> [-Password <password>] [-SecurePassword] [-NoRestart]`

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

- `PDQInventory SetServiceCredentials -Username DOMAIN\svcaccount -SecurePassword` - Update service credentials and prompt for the password securely.
- `PDQInventory SetServiceCredentials -Username .\localuser -SecurePassword` - Update credentials for a local account.
- `PDQInventory SetServiceCredentials -Username DOMAIN\svcaccount -Password MyP@ss -NoRestart` - Update credentials and skip the service restart.
- `Get-Secret -Name PDQServiceAccount | ConvertFrom-SecureString -AsPlainText | PDQInventory SetServiceCredentials -Username DOMAIN\svcaccount` - Pipe the password from a PAM tool via stdin (most secure for scripting).

**Notes:**

- This command requires Administrator privileges and accesses the database directly (offline mode), so it does not require the background service to be running. If the service is running, it will be restarted automatically after the credential change to apply the new credentials, unless `-NoRestart` is specified.

## SetServiceMode

**Description:** Configures PDQ Inventory to run in Local, Client, or Server mode. The console and background service are closed before the change is applied. Depending on the selected mode, you will be prompted for credentials, a server hostname, a port number, and firewall exception preferences.
**License:** Enterprise
**Syntax:** `PDQInventory SetServiceMode <ServiceMode>`

**Parameters:**

| Parameter | Required | Description |
|-----------|----------|-------------|
| `<ServiceMode>` | Yes | The service mode to configure. Accepted values: `Local`, `Client`, `Server`. `Local` runs the console and background service on the same machine. `Client` connects to a remote server (you will be prompted for hostname and port). `Server` accepts connections from remote consoles (you will be prompted for service account, port, and firewall settings). |

**Examples:**

- `PDQInventory SetServiceMode Local` - Switch to Local mode.
- `PDQInventory SetServiceMode Client` - Configure as a client connecting to a remote server.
- `PDQInventory SetServiceMode Server` - Configure as a server.

## Settings

**Description:** Reads or writes internal PDQ Inventory settings. Without a setting name, lists all available settings and their current values. Specify `-Name` to read a specific setting, `-Set` to change its value, or `-Reset` to restore it to its default.
**License:** Free
**Syntax:** `PDQInventory Settings [-Name <settingName>] [-Set <value>] [-Reset]`

**Parameters:**

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-Name <settingName>` | No | The name of the setting to read or modify. Required when using `-Set` or `-Reset`. |
| `-Set <value>` | No | The new value to assign to the setting specified by `-Name`. Cannot be combined with `-Reset`. |
| `-Reset` | No | Resets the setting specified by `-Name` to its default value. Cannot be combined with `-Set`. |

**Examples:**

- `PDQInventory Settings` - List all settings.
- `PDQInventory Settings -Name ScanSettings.CleanupLogDays` - Read a specific setting.
- `PDQInventory Settings -Name ScanSettings.CleanupLogDays -Set 30` - Change a setting value.
- `PDQInventory Settings -Name ScanSettings.CleanupLogDays -Reset` - Reset a setting to its default.
- `PDQInventory Settings -Name FeatureFlag.EnableAuditLog -Set true` - Enable a feature flag (see Feature Flags above).

## StartNetworkDiscovery

**Description:** Starts a network discovery scan asynchronously and returns the discovery ID. Use `GetNetworkDiscoveryStatus` to monitor progress and `StopNetworkDiscovery` to abort a running scan. Only one discovery can run at a time.
**License:** Enterprise
**Syntax:** `PDQInventory StartNetworkDiscovery { -Subnet <subnet> | -IPRangeFrom <startIP> -IPRangeTo <endIP> } [-Credential <name>] [-Wait]`

**Parameters:**

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-Subnet <subnet>` | One of these forms | Subnet in CIDR notation (e.g., `192.168.1.0/24`) or a single IP address. Mutually exclusive with `-IPRangeFrom`/`-IPRangeTo`. |
| `-IPRangeFrom <ip>` | One of these forms | Starting IP address for a range scan (e.g., `192.168.1.1`). Must be used with `-IPRangeTo`. |
| `-IPRangeTo <ip>` | One of these forms | Ending IP address for a range scan (e.g., `192.168.1.254`). Must be used with `-IPRangeFrom`. |
| `-Credential <name>` | No | Name of a stored credential to use when authenticating to discovered systems. If not specified, default credentials are used. See the security note below. |
| `-Wait` | No | Blocks until the discovery completes and displays the final status. Without this flag, the command returns immediately after starting the scan. |

**Exit Codes:**

| Code | Meaning |
|------|---------|
| 0 | Discovery started successfully (or completed successfully with `-Wait`). |
| 1 | Discovery failed to start or encountered an error (e.g., one is already running, invalid subnet, credential not found). |

**Examples:**

- `PDQInventory StartNetworkDiscovery -Subnet "192.168.1.0/24"` - Scan a subnet asynchronously.
- `PDQInventory StartNetworkDiscovery -IPRangeFrom 192.168.1.1 -IPRangeTo 192.168.1.254 -Wait` - Scan an IP range and wait for completion.
- `PDQInventory StartNetworkDiscovery -Subnet "10.0.0.0/16" -Credential "ScanAccount"` - Scan using a named credential.

**Notes:**

- PDQ Inventory will authenticate to discovered systems using the default or provided credentials. Malicious or rogue machines on the network could potentially capture these credentials. Ensure you trust the network being scanned.

## StopNetworkDiscovery

**Description:** Gracefully stops a running, queued, or paused network discovery scan. Use `GetNetworkDiscoveryStatus` to find the ID of the discovery to stop.
**License:** Enterprise
**Syntax:** `PDQInventory StopNetworkDiscovery -Id <id>`

**Parameters:**

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-Id <id>` | Yes | The numeric ID of the discovery to stop. Use `GetNetworkDiscoveryStatus -Running` to find the ID of the current discovery. |

**Exit Codes:**

| Code | Meaning |
|------|---------|
| 0 | Discovery stopped successfully. |
| 1 | Discovery is not running (e.g., already finished or aborted). |
| 3 | The specified discovery ID was not found. |

**Examples:**

- `PDQInventory StopNetworkDiscovery -Id 42` - Stop the discovery with ID 42.

## SystemInfo

**Description:** Outputs information about the PDQ Inventory installation, such as version, database path, service mode, and license details. Without an argument, all available items are listed. Specify an item name to output only that value.
**License:** Free
**Syntax:** `PDQInventory SystemInfo [<Item>]`

**Parameters:**

| Parameter | Required | Description |
|-----------|----------|-------------|
| `<Item>` | No | The name of a specific system info item to output. When omitted, all items and their values are listed. |

**Examples:**

- `PDQInventory SystemInfo` - List all system info.
- `PDQInventory SystemInfo Version` - Output a specific item.

## TestCredential

**Description:** Tests an existing scan credential by attempting to connect to a target computer. This verifies that the credential has network access to the target before using it in a scan.
**License:** Free
**Syntax:** `PDQInventory TestCredential -Name <credentialName> -Computer <computerName>`

**Parameters:**

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-Name <credentialName>` | Yes | The username of the credential to test (e.g., `DOMAIN\svcaccount`). This must match a credential already saved in PDQ Inventory. |
| `-Computer <computerName>` | Yes | The target computer to test connectivity against. Can be a hostname or IP address. |

**Exit Codes:**

| Code | Meaning |
|------|---------|
| 0 | The credential successfully connected to the target computer. |
| 1 | Failure. The credential was not found, the connection failed, access was denied, or another error occurred. |

**Examples:**

- `PDQInventory TestCredential -Name DOMAIN\svcaccount -Computer WORKSTATION01` - Test a credential against a target computer.
- `PDQInventory TestCredential -Name DOMAIN\svcaccount -Computer 192.168.1.50` - Test using an IP address.

**Notes:**

- The PDQ Inventory background service must be running for this command to work. The credential name must exactly match the username stored in PDQ Inventory Preferences > Credentials.

## UpdateCustomVariable

**Description:** Updates the value of an existing custom variable in PDQ Inventory. Both the variable name and new value are required.
**License:** Enterprise
**Syntax:** `PDQInventory UpdateCustomVariable <Name> <Value>`

**Parameters:**

| Parameter | Required | Description |
|-----------|----------|-------------|
| `<Name>` | Yes | The name of the custom variable to update. The variable must already exist. |
| `<Value>` | Yes | The new value to assign to the variable. Wrap in double quotes if the value contains spaces. |

**Examples:**

- `PDQInventory UpdateCustomVariable ScanServer "\\scanserver\share"` - Set a custom variable to a new value.
- `PDQInventory UpdateCustomVariable AgentVersion 2.1.0`

**Notes:**

- This command updates an existing variable only. To create a new variable, use the PDQ Inventory console or the `CreateCustomVariable` command. The `CreateCustomVariable` command with the `-Force` flag can also update existing variables. This command is retained for backwards compatibility.

## UpdateScanCredential

**Description:** Updates an existing scan credential stored in PDQ Inventory. Used to rotate the password (and optionally the username) for a credential that PDQ Inventory uses when scanning target computers. Designed for automated password rotation workflows and PAM integrations.
**License:** Free
**Syntax:** `PDQInventory UpdateScanCredential -Name <credentialName> [-Username <domain\username>] [-Password <password>] [-SecurePassword] [-CreateIfNotExists]`

**Parameters:**

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-Name <credentialName>` | Yes | The username of the credential to update or create (e.g., `DOMAIN\svcaccount`). Must match an existing credential in PDQ Inventory unless `-CreateIfNotExists` is set. |
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

- `PDQInventory UpdateScanCredential -Name DOMAIN\svcaccount -SecurePassword` - Update the password for an existing credential interactively.
- `Get-Secret -Name ScanAccount | ConvertFrom-SecureString -AsPlainText | PDQInventory UpdateScanCredential -Name DOMAIN\svcaccount` - Update a credential password from a PAM tool via stdin.
- `PDQInventory UpdateScanCredential -Name DOMAIN\oldsvc -Username DOMAIN\newsvc -SecurePassword` - Update both the username and password.
- `PDQInventory UpdateScanCredential -Name DOMAIN\svcaccount -Username DOMAIN\svcaccount -SecurePassword -CreateIfNotExists` - Create a credential if it does not already exist.

**Notes:**

- The PDQ Inventory background service must be running for this command to work. The credential name (`-Name`) must exactly match the username stored in PDQ Inventory Preferences > Credentials.

## WakeComputer

**Description:** Sends a Wake-on-LAN (WoL) packet to a computer known to PDQ Inventory. The command reports which computers were used to relay the wake packet.
**License:** Enterprise
**Syntax:** `PDQInventory WakeComputer <computer>`

**Parameters:**

| Parameter | Required | Description |
|-----------|----------|-------------|
| `<computer>` | Yes | The name or numeric ID of the computer to wake. |

**Examples:**

- `PDQInventory WakeComputer WORKSTATION01` - Send a Wake-on-LAN packet to WORKSTATION01.

**Notes:**

- The target computer must have a known MAC address in PDQ Inventory for Wake-on-LAN to work.
