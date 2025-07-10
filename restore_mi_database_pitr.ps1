<#
================================================================================
  Script Name : restore_mi_database_pitr.ps1

  Description :
      This PowerShell script performs a Point-in-Time Restore (PITR) of the 
      'frobelworkscheduler' database from the production Azure SQL Managed 
      Instance ('az-azv-mi-prod') to the test instance ('azv-test').

      Key features:
        - Automatically deletes the target database if it exists, with user prompt.
        - Waits for full Azure resource cleanup to avoid hidden locks or errors.
        - Queries Azure Monitor metrics to verify storage availability.
        - Calculates estimated source DB size via T-SQL and access token auth.
        - Performs restore via `Restore-AzSqlInstanceDatabase -AsJob`.
        - Polls restore status periodically and exits cleanly on timeout.

      Use case:
        - Ensures repeatable, safe test restores of production data for validation,
          dev, or QA use without impacting production.
        - Designed to handle typical Azure MI delays and quirks automatically.

  Requirements:
      - Membership in Entra ID group:
            • az-azv-mi-prod_restore_operator
      - Az PowerShell module (Az.Sql)
      - Restore time must be within backup retention period (typically 7 days)

  Author      : FRÖBEL IT / christiana.hug@froebel-gruppe.de
  Version     : 1.6
  Updated     : July 2025
================================================================================
#>

# === Sign in to Azure ===
Connect-AzAccount

# === Configuration ===
$subscriptionId             = "1e43af1f-2e56-4fcb-9d09-0df266e67480"
$sourceResourceGroupName    = "rg-azv-prod"
$targetResourceGroupName    = "rg-azv"
$sourceMiName               = "az-azv-mi-prod"
$targetMiName               = "azv-test"
$targetDbName               = "frobelworkscheduler_ch"
$sourceDbName               = "frobelworkscheduler"
[DateTime]$restoreTime      = (Get-Date).AddMinutes(-15)

# === Select subscription ===
Select-AzSubscription -SubscriptionId $subscriptionId

# === Check if target DB already exists ===
$existingDb = Get-AzSqlInstanceDatabase -ResourceGroupName $targetResourceGroupName -InstanceName $targetMiName -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -eq $targetDbName }

if ($existingDb) {
    Write-Host "⚠️  Database '$targetDbName' already exists on instance '$targetMiName'." -ForegroundColor Yellow
    $userInput = Read-Host "Do you want to delete the existing database before restore? (Y/N)"
    
    if ($userInput -eq 'Y' -or $userInput -eq 'y') {
        Write-Host "⏳ Deleting existing database '$targetDbName' on instance '$targetMiName'..." -ForegroundColor Cyan
        $deletionRequested = $false

        try {
            Remove-AzSqlInstanceDatabase -Name $targetDbName `
                -InstanceName $targetMiName `
                -ResourceGroupName $targetResourceGroupName `
                -Force -ErrorAction Stop

            $deletionRequested = $true
            Write-Host "🧨 Delete command returned successfully." -ForegroundColor Yellow
        }
        catch {
            if ($_.Exception.Message -like "*Forbidden*") {
                Write-Host "⚠️  Azure returned 'Forbidden' — likely due to long-running deletion. Monitoring anyway..." -ForegroundColor Yellow
                $deletionRequested = $true
            } else {
                Write-Host "❌ Unexpected error during deletion: $($_.Exception.Message)" -ForegroundColor Red
                exit 1
            }
        }

        if ($deletionRequested) {
            $startTime = Get-Date
            $timeout   = $startTime.AddMinutes(10)

            do {
                $now     = Get-Date
                $elapsed = [int](New-TimeSpan -Start $startTime -End $now).TotalSeconds
                Write-Host "⌛ [$($now.ToString('HH:mm:ss'))] Waiting for '$targetDbName' to be removed... Elapsed: ${elapsed}s" -ForegroundColor DarkGray

                Start-Sleep -Seconds 15

                $stillExists = Get-AzSqlInstanceDatabase `
                    -ResourceGroupName $targetResourceGroupName `
                    -InstanceName $targetMiName `
                    -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -eq $targetDbName }

                if ($now -gt $timeout) {
                    Write-Warning "⏳ Timeout: database '$targetDbName' still exists after 10 minutes."
                    exit 1
                }
            } while ($stillExists)

            Write-Host "✅ Database '$targetDbName' has been successfully deleted." -ForegroundColor Green

            # === Wait for metrics to reflect freed space ===
            Write-Host "⏸️  Waiting 3 minutes for Azure to clean up resources..." -ForegroundColor Yellow
            $waitStart = Get-Date
            $waitUntil = $waitStart.AddMinutes(3)

            do {
                $now       = Get-Date
                $remaining = [int](New-TimeSpan -Start $now -End $waitUntil).TotalSeconds
                Write-Host "⌛ [$($now.ToString('HH:mm:ss'))] Waiting... $remaining seconds remaining" -ForegroundColor Gray
                Start-Sleep -Seconds 15
            } while ($now -lt $waitUntil)

            Write-Host "✅ Azure clean-up period completed." -ForegroundColor Green
        }
    } else {
        Write-Host "❌ Restore aborted by user. No changes were made." -ForegroundColor Red
        exit 1
    }

    # === Final wait and exit ===
    Write-Host "`n🕓 Waiting period completed." -ForegroundColor Green
    Write-Warning "⚠️  Restore step is intentionally skipped after deletion."
    Write-Warning "ℹ️  This is required to avoid silent restore failures due to lingering Azure resource locks."
    Write-Host ""
    Write-Host "📌 Please re-run this script now to initiate the database restore." -ForegroundColor Cyan
    Write-Host "🔁 This second run will begin with a clean state and trigger a successful PITR restore." -ForegroundColor Gray
    exit 0
}

# === Check used storage on target MI using Azure Monitor ===
Write-Host "📊 Checking current storage usage on target MI '$targetMiName'..." -ForegroundColor Cyan

$targetMiResource = Get-AzResource `
    -ResourceGroupName $targetResourceGroupName `
    -ResourceType "Microsoft.Sql/managedInstances" `
    -Name $targetMiName

$targetMiId = $targetMiResource.ResourceId

$metric = Get-AzMetric `
    -ResourceId $targetMiId `
    -TimeGrain 00:05:00 `
    -MetricName "storage_space_used_mb" `
    -StartTime (Get-Date).AddMinutes(-2) `
    -EndTime (Get-Date) `
    -WarningAction Ignore

$usedMB = ($metric.Data | Sort-Object -Property Average -Descending | Select-Object -First 1).Average
$targetMi = Get-AzSqlInstance -ResourceGroupName $targetResourceGroupName -Name $targetMiName
$totalMB  = $targetMi.StorageSizeInGB * 1024

# === Get estimated source DB size ===
Write-Host "📐 Querying estimated size of source DB '$sourceDbName' on '$sourceMiName'..." -ForegroundColor Cyan

$sqlQuery = @"
USE [$sourceDbName];
SELECT 
    CAST(SUM(size) * 8 / 1024 AS INT) AS DataSizeMB
FROM sys.database_files
WHERE type_desc = 'ROWS';
"@

$accessToken  = (Get-AzAccessToken -ResourceUrl https://database.windows.net).Token
$sourceDBsize = (Invoke-Sqlcmd -ServerInstance "az-azv-mi-prod.4dc434aa1434.database.windows.net" -Database "master" -AccessToken $accessToken -Query $sqlQuery).DataSizeMB

$availableGB = $totalMB - $usedMB

Write-Host "📦 Total MI storage: $totalMB MB"
Write-Host "📊 Currently used: $usedMB MB"
Write-Host "📁 Restore: $sourceDBsize MB"
Write-Host "🟢 Available storage: $availableGB MB"

if ($availableGB -lt $sourceDBsize) {
    Write-Warning "❌ Not enough storage available to restore the database."
    Write-Warning "💡 Please increase the MI's storage or remove unused databases before retrying. If you just deleted a database, wait a few more minutes for resources to clean up."
    Start-Sleep -Seconds 5
    exit 1
}

# === Start restore ===
Write-Host "🚀 Starting restore of '$sourceDbName' to '$targetDbName' on '$targetMiName'..." -ForegroundColor Cyan
Start-Sleep -Seconds 10

Restore-AzSqlInstanceDatabase `
    -FromPointInTimeBackup `
    -ResourceGroupName $sourceResourceGroupName `
    -InstanceName $sourceMiName `
    -Name $sourceDbName `
    -PointInTime $restoreTime `
    -TargetInstanceDatabaseName $targetDbName `
    -TargetInstanceName $targetMiName `
    -TargetResourceGroupName $targetResourceGroupName `
    -AsJob

Write-Host "✅ Restore initiated. Waiting for database to come online..." -ForegroundColor Green
Start-Sleep -Seconds 30

# === Monitor restore progress (with timeout) ===
$timeoutSeconds = 300
$startTime      = Get-Date

do {
    $elapsed = [int](New-TimeSpan -Start $startTime -End (Get-Date)).TotalSeconds
    $now     = Get-Date -Format "HH:mm:ss"
    Write-Host "🔄 [$now] Waiting for '$targetDbName' to come ONLINE... Elapsed: ${elapsed}s" -ForegroundColor DarkCyan

    Start-Sleep -Seconds 15

    try {
        $db = Get-AzSqlInstanceDatabase `
            -ResourceGroupName $targetResourceGroupName `
            -InstanceName $targetMiName `
            -Name $targetDbName `
            -ErrorAction Stop

        $status = $db.Status
        Write-Host "📘 Found via Get-AzSqlInstanceDatabase — status: $status" -ForegroundColor Gray
    } catch {
        $status = "Unknown"
    }

    if ($elapsed -ge $timeoutSeconds) {
        Write-Warning "`n⏳ Restore is taking longer than expected (>$timeoutSeconds seconds)."
        Write-Warning "❗ Please rerun this script after a few more minutes if the database is still not ONLINE."
        exit 0
    }
} while ($status -ne "Online")

Write-Host "`n🎉 Restore of '$targetDbName' completed successfully. Status: $status" -ForegroundColor Green
