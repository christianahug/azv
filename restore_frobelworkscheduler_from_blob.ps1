<#
================================================================================
  Script Name : restore_frobelworkscheduler_from_blob.ps1
  Description : 
      Downloads an existing backup (.bak) from Azure Blob Storage,
      restores it to local SQL Server,
      and deletes the .bak file and blob (but keeps the restored database and its files).

  Requirements:
      - PowerShell with Az + SqlServer modules
      - The .bak file must already exist in Azure Blob Storage
      - Local SQL auth access (e.g., user 'sa')
      - Network access: on-prem or via VPN

  Author      : FRÖBEL IT / christiana.hug@froebel-gruppe.de
  Version     : 1.8
  Updated     : July 2025
================================================================================
#>

# --- Configuration ---
$devuser = "ch"  # ← Set your last name or unique ID manually here
$storageAccount = "froebelsqlbackups"
$container = "azvdevbackups"
$backupFolder = "C:\temp\AZVSQLBackup"
$sqlInstanceLocal = "localhost"
$saUser = "sa"
$saPassword = "Mondschein2025!"

# 📅 Generate timestamp and blob name
$timestamp = (Get-Date).ToString("dd_MM_yyyy_") + (Get-Date).ToString("dddd")
$blobName = "frobelworkscheduler_${devuser}_${timestamp}.bak"
$localBackupPath = Join-Path $backupFolder $blobName
$blobUrl = "https://$storageAccount.blob.core.windows.net/$container/$blobName"
$restoredDbName = "frobelworkscheduler_$devuser"

# --- Ensure working folder exists ---
if (-not (Test-Path $backupFolder)) {
    New-Item -ItemType Directory -Path $backupFolder | Out-Null
}

# --- Azure login and blob context ---
Connect-AzAccount -ErrorAction Stop
$context = New-AzStorageContext -StorageAccountName $storageAccount -UseConnectedAccount

# --- Early check: does the blob exist? ---
Write-Host "🔎 Checking for backup blob [$blobName] in [$container]..."
$blobCheck = Get-AzStorageBlob -Container $container -Context $context `
    | Where-Object { $_.Name -eq $blobName }

if (-not $blobCheck) {
    Write-Warning "❌ Backup blob '$blobName' not found in Azure container '$container'."
    Write-Warning "💡 Please create the backup before running this restore script."
    exit 1
}

# --- Step 1: Download .bak file ---
Write-Host "📥 Downloading $blobName from Azure Blob Storage..."
Get-AzStorageBlobContent -Container $container -Blob $blobName `
    -Destination $localBackupPath -Context $context -Force

# --- Step 2: Extract logical file names ---
Write-Host "🔍 Extracting logical file names..."
$restoreInfo = @"
RESTORE FILELISTONLY FROM DISK = N'$localBackupPath';
"@

$logicalFiles = Invoke-Sqlcmd -ServerInstance $sqlInstanceLocal `
    -Username $saUser -Password $saPassword `
    -Query $restoreInfo

# --- Step 3: Build MOVE clauses ---
$moveClauses = foreach ($file in $logicalFiles) {
    $logicalName = $file.LogicalName
    $type = $file.Type

    $targetPath = switch ($type) {
        "D" { Join-Path $backupFolder "$logicalName.mdf" }
        "L" { Join-Path $backupFolder "$logicalName.ldf" }
        "F" { Join-Path $backupFolder "$logicalName.fs" }
        "S" { Join-Path $backupFolder "$logicalName.ft" }
        "X" { Join-Path $backupFolder "$logicalName.xtp" }
        default { Join-Path $backupFolder "$logicalName.dat" }
    }

    "MOVE N'$logicalName' TO N'$targetPath'"
}

$joinedMoves = ($moveClauses -join ",`n    ")

# --- Step 4: Restore to local SQL Server ---
$restoreQuery = @"
RESTORE DATABASE [$restoredDbName]
FROM DISK = N'$localBackupPath'
WITH 
    $joinedMoves,
    REPLACE,
    STATS = 10;
"@

Write-Host "`n💾 Starting restore on local SQL Server..."
Invoke-Sqlcmd -ServerInstance $sqlInstanceLocal `
    -Username $saUser -Password $saPassword `
    -Query $restoreQuery `
    -QueryTimeout 1200

Write-Host "✅ Local restore completed successfully."

# --- Step 5: Clean up blob ---
Write-Host "🧹 Deleting $blobName from Azure Blob Storage..."
Remove-AzStorageBlob -Blob $blobName -Container $container -Context $context

# --- Step 6: Delete only the .bak file ---
Write-Host "🧽 Deleting local .bak file..."
if (Test-Path $localBackupPath) {
    try {
        Remove-Item $localBackupPath -Force
        Write-Host "🗑 Deleted: $localBackupPath"
    } catch {
        Write-Warning "⚠️ Failed to delete .bak file: $($_.Exception.Message)"
    }
} else {
    Write-Host "❓ .bak file not found at $localBackupPath"
}

Write-Host "`n🎉 All done! Database [$restoredDbName] restored, .bak and blob cleaned up."
