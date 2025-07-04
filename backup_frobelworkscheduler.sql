/*
====================================================================================
  Script Name : backup_frobelworkscheduler.sql
  Description : 
      This script creates a timestamped backup of the database [frobelworkscheduler]
      and stores it as a .bak file in an Azure Blob Storage container (azvdevbackups).
      It is used to support development and testing workflows by enabling 
      developers to restore current production-like data to their local environments.

  Context     : 
      - Used in combination with a local restore automation (PowerShell script)
      - The backup is triggered from an Azure SQL Managed Instance (MI)
      - Output .bak file is stored in Azure Storage (froebelsqlbackups)
      - The filename includes a dev user suffix and the current date (e.g., 'ch_04_07_2025_Friday')

  Prerequisites:
      - Executed by a user in Entra Group: az-azv-mi-prod_MI_frobelworkscheduler_backupoperator
      - The MI must have permission to write to the blob container via managed identity or SAS
      - Container: azvdevbackups (in storage account: froebelsqlbackups)

  Author      : FRÖBEL IT / christiana.hug@froebel-gruppe.de
  Version     : 1.0
  Created     : July 2025
====================================================================================
*/

-- === 🔧 Declare variables ===
DECLARE @devuser NVARCHAR(100) = 'ch';  -- Replace with user initials or last name (e.g., 'ch')
DECLARE @timestamp NVARCHAR(40) = 
    FORMAT(GETDATE(), 'dd_MM_yyyy_') + DATENAME(WEEKDAY, GETDATE());

DECLARE @filename NVARCHAR(200);
DECLARE @backupUrl NVARCHAR(500);
DECLARE @sql NVARCHAR(MAX);

-- === 📝 Construct backup filename ===
-- Format: frobelworkscheduler_<devuser>_<timestamp>.bak
SET @filename = 'frobelworkscheduler_' + @devuser + '_' + @timestamp + '.bak';

-- === ☁️ Define destination URL in Azure Blob Storage ===
SET @backupUrl = 'https://froebelsqlbackups.blob.core.windows.net/azvdevbackups/' + @filename;

-- === 🧱 Build and execute the dynamic BACKUP command ===
SET @sql = '
BACKUP DATABASE [frobelworkscheduler]
TO URL = N''' + @backupUrl + '''
WITH FORMAT, INIT, COMPRESSION, COPY_ONLY, STATS = 10;
';

-- 🏁 Execute backup
EXEC sp_executesql @sql;

