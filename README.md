# Database Backup Script for Azure Storage

This PowerShell script automates the backup process for databases and stores them in Azure Storage. It compresses `.bak` files into `.zip` files using WinRAR and transfers them to the specified cloud storage location.

## Usage

1. **Set Configuration:**
    - Modify the following variables in `config.ps1` to match your environment:
        - `$sourcePath`: Local path where your database `.bak` files are stored.
        - `$compressionFolder`: Local path where compressed `.zip` files will be temporarily stored.
        - `$cloudBasePath`: Azure Storage path where backups will be transferred.
    - Update Azure Storage credentials in `config.ps1`:
        - `$username`: Your Azure Storage username.
        - `$password`: Your Azure Storage password.
    - Adjust other parameters in `config.ps1` as needed:
        - `$maxRetryAttemptsVerification`: Maximum number of retry attempts for verifying backups.
        - `$retryIntervalSeconds`: Interval in seconds between retry attempts.
        - `$maxDaysToRetainCloud`: Maximum number of days to retain backups in Azure Storage.
        - `$weeklymonthlyremove`: Flag for enabling/disabling removal of weekly/monthly backups.
        - Email settings for notifications.

2. **Run the Script:**
    - Execute `backupscript.ps1` in PowerShell to initiate the backup process.

3. **Review Logs:**
    - Check log files in the specified `$logDirectory` to monitor backup progress and any errors encountered.

## Important Notes

- Ensure WinRAR is included in the package and update the `$winrarPath` variable in `config.ps1` with the correct path.
- Verify the paths for daily, weekly, and monthly backups in Azure Storage and update accordingly.
- Use a secure method to handle sensitive information such as passwords and email credentials.

## Script Workflow Overview

1. **Compression Phase:**
    - Locate `.bak` files in the source path and compress them into `.zip` files using WinRAR.
    - Check for existing `.zip` files to avoid redundant compression.

2. **Transfer to Cloud Storage:**
    - Map a drive to Azure Storage using the specified credentials.
    - Copy the compressed `.zip` files to the designated folders in Azure Storage based on the backup frequency (daily, weekly, or monthly).

3. **Backup Verification:**
    - Verify the successful transfer of files to Azure Storage and log any discrepancies or failures.

4. **Email Notification:**
    - Send an email notification to specified recipients upon completion of the backup process, including details of the backed-up files.

5. **Cleanup and Maintenance:**
    - Remove older backups from Azure Storage based on the retention policies set in the script.

## Example Email Notification

Upon successful completion of the backup process, an email notification will be sent to the specified recipients. The email includes information about the backup status and the number of files transferred.

## Database Schema for Backup Tracking

To track and manage backups, create the following tables in your database:

```sql
CREATE TABLE Servers (
    ServerID INT PRIMARY KEY AUTO_INCREMENT,
    ServerName VARCHAR(50) UNIQUE,
    IPAddress VARCHAR(50),
    Description TEXT
);

CREATE TABLE BackupDetails (
    BackupID INT PRIMARY KEY AUTO_INCREMENT,
    ServerID INT,
    BackupType VARCHAR(20),
    BackupDate DATETIME,
    TotalFiles INT,
    BackupStartTime DATETIME,
    BackupEndTime DATETIME,
    Status VARCHAR(20),
    BackupDurationSeconds INT,
    LogFilePath VARCHAR(255),
    ErrorMessage TEXT,
    CONSTRAINT FK_BackupDetails_Servers FOREIGN KEY (ServerID) REFERENCES Servers(ServerID)
);

CREATE TABLE BackupFiles (
    FileID INT PRIMARY KEY AUTO_INCREMENT,
    BackupID INT,
    ServerID INT,
    FileName VARCHAR(100),
    FileSizeBytes BIGINT,
    FilePath VARCHAR(255),
    CONSTRAINT FK_BackupFiles_BackupDetails FOREIGN KEY (BackupID) REFERENCES BackupDetails(BackupID),
    CONSTRAINT FK_BackupFiles_Servers FOREIGN KEY (ServerID) REFERENCES Servers(ServerID)
);
```
## Table Descriptions

### Servers
Contains information about servers being backed up.

- **ServerID:** Unique identifier for each server.
- **ServerName:** Unique name for each server.
- **IPAddress:** IP address of the server.
- **Description:** Description of the server.

### BackupDetails
Records details of each backup operation.

- **BackupID:** Unique identifier for each backup operation.
- **ServerID:** ID of the server being backed up.
- **BackupType:** Type of backup (e.g., daily, weekly, monthly).
- **BackupDate:** Date and time when the backup was performed.
- **TotalFiles:** Total number of files backed up.
- **BackupStartTime:** Start time of the backup operation.
- **BackupEndTime:** End time of the backup operation.
- **Status:** Status of the backup (e.g., success, failure).
- **BackupDurationSeconds:** Duration of the backup operation in seconds.
- **LogFilePath:** Path to the log file associated with the backup.
- **ErrorMessage:** Error message, if any.

### BackupFiles
Tracks individual files in each backup operation.

- **FileID:** Unique identifier for each file.
- **BackupID:** ID of the associated backup operation.
- **ServerID:** ID of the server being backed up.
- **FileName:** Name of the file.
- **FileSizeBytes:** Size of the file in bytes.
- **FilePath:** Path to the file in Azure Storage.

## Included Files

- **config.ps1:** Configuration file with paths and credentials.
- **backupscript.ps1:** PowerShell script to perform the backup operations.
- **WinRAR:** Portable version of WinRAR included in the package.
