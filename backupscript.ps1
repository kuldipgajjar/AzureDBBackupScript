net use \\datastore010.file.core.windows.net\datastore /delete

# Load configuration
. .\config.ps1

# Define the source path for .bak files

# Define the local compression folder

# Define the destination path for .zip files on cloud storage
$currentDateFolder = Get-Date -Format "yyyyMMdd"
$hostnameFolder = $env:COMPUTERNAME

# Define the username and password

# Maximum number of retry attempts for verification
$maxRetryAttemptsVerification = 3
$retryCountVerification = 0
$retryIntervalSeconds = 15  # Adjust this as needed

# Get the current date in yyyy-MM-dd format for the log file name
$logDate = Get-Date -Format "yyyy-MM-dd"

# Define the log directory

# Ensure the log directory exists if it doesn't
if (-not (Test-Path -Path $logDirectory)) {
    New-Item -Path $logDirectory -ItemType Directory
}

# Define the log file path
$logFilePath = Join-Path -Path $logDirectory -ChildPath "$logDate.txt"

# Function to write log entries in the desired format
function Write-LogEntry {
    param (
        [string] $message,
        [string] $logFile
    )

    $logEntry = "[{0:yyyy-MM-dd HH:mm:ss}] {1}" -f (Get-Date), $message
    Write-Host $logEntry
    if ($logFile) {
        $logEntry | Out-File -Append -FilePath $logFile
    }
}

# Database connection and operations

# Create the connection string
$connectionString = "Server=$serverName;Database=$databaseName;User Id=$dbUsername;Password=$dbPassword;Encrypt=True;TrustServerCertificate=True;Connection Timeout=30;"

# Fetch the server's IP address
$ipAddress = (Get-NetIPAddress | Where-Object { $_.AddressFamily -eq 'IPv4' -and $_.PrefixOrigin -eq 'Dhcp' }).IPAddress

# Query to check if the server exists
$queryCheck = "SELECT COUNT(*) FROM Servers WHERE ServerName = '$hostnameFolder'"

try {
    $serverExists = Invoke-Sqlcmd -Query $queryCheck -ConnectionString $connectionString | Select-Object -ExpandProperty Column1
    if ($serverExists -eq 0) {
        # If server does not exist, insert the new server info
        $queryInsert = "INSERT INTO Servers (ServerName, IPAddress, Description) VALUES ('$hostnameFolder', '$ipAddress', 'db server')"
        Invoke-Sqlcmd -Query $queryInsert -ConnectionString $connectionString
        Write-LogEntry "Inserted new server info: $hostnameFolder with IP $ipAddress" $logFilePath
    } else {
        Write-LogEntry "Server info already exists: $hostnameFolder" $logFilePath
    }
} catch {
    Write-LogEntry "SQL error: $_" $logFilePath
}

$retryCountVerification = 0
$maxRetryAttemptsVerification = 3

do {
    # Reset variables for each attempt
    $retryCountVerification++
    $verificationFailed = $false

    # Create the local compression folder if it doesn't exist
    if (-not (Test-Path -Path $compressionFolder)) {
        New-Item -ItemType Directory -Path $compressionFolder | Out-Null
    }

    Write-LogEntry "------------File Compression started------------" $logFilePath

    # Define the path to the WinRAR executable
    $winrarPath = "C:\Script\WinRAR\WinRAR.exe"  # Replace with the actual path

    # Compress .bak files into self-extracting .exe using WinRAR
    foreach ($backupFile in Get-ChildItem -Path $sourcePath -Filter *.bak) {
        $zipFilePath = Join-Path $compressionFolder "$($backupFile.BaseName).zip"

        # Check if the .zip file already exists, skip compression if it does
        if (-not (Test-Path -Path $zipFilePath)) {
            # Use WinRAR to create a ZIP archive without displaying the dialog box
            $process = Start-Process -FilePath $winrarPath -ArgumentList "a -ibck `"$zipFilePath`" `"$($backupFile.FullName)`"" -PassThru
            $process.WaitForExit()
            Write-LogEntry "Compressed .bak file: $zipFilePath" $logFilePath
        }
    }

    Write-LogEntry "------------File Compression finished------------" $logFilePath

    # Create a PSDrive using the mapped drive letter, username, and password
    $psDrive = Get-PSDrive -Name "V" -ErrorAction SilentlyContinue

    if (-not $psDrive) {
        New-PSDrive -Name "V" -PSProvider FileSystem -Root $cloudBasePath -Credential (New-Object System.Management.Automation.PSCredential -ArgumentList $username, (ConvertTo-SecureString -String $password -AsPlainText -Force)) -Persist
    }

    # Combine the base path with the date and hostname to get the full path
    $currentDateFolderPath = Join-Path "V:\" $currentDateFolder
    $hostnameFolderPath = Join-Path $currentDateFolderPath $hostnameFolder

    # Create the current date folder if it doesn't exist
    if (-not (Test-Path -Path $currentDateFolderPath)) {
        New-Item -ItemType Directory -Path $currentDateFolderPath | Out-Null
    }

    # Create the hostname folder if it doesn't exist
    if (-not (Test-Path -Path $hostnameFolderPath)) {
        New-Item -ItemType Directory -Path $hostnameFolderPath | Out-Null
    }

    function Write-LogEntry {
        param (
            [string]$message,
            [string]$logFilePath
        )
        $timestamp = Get-Date -Format "[yyyy-MM-dd HH:mm:ss]"
        $logEntry = "$timestamp $message"
        Write-Output $logEntry
        Add-Content -Path $logFilePath -Value $logEntry
    }

    Write-LogEntry "------------Daily backup started------------" $logFilePath

    # Get the current date and time for backup details
    $backupDateTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $backupStartTime = Get-Date

    # Insert data into BackupDetails table to get BackupID and ServerID
    $insertBackupQuery = @"
    INSERT INTO BackupDetails (ServerID, BackupType, BackupDate, BackupStartTime)
    VALUES ((SELECT ServerID FROM Servers WHERE ServerName = '$hostnameFolder'), 'Daily', '$backupDateTime', '$backupDateTime');
    SELECT SCOPE_IDENTITY() AS BackupID;
"@
    $backupResult = Invoke-Sqlcmd -Query $insertBackupQuery -ConnectionString $connectionString

    # Get BackupID and ServerID from the inserted record
    $backupID = $backupResult.BackupID
    $serverIDQuery = "SELECT ServerID FROM Servers WHERE ServerName = '$hostnameFolder'"
    $serverID = (Invoke-Sqlcmd -Query $serverIDQuery -ConnectionString $connectionString).ServerID

    Write-LogEntry "Inserted backup details into BackupDetails table" $logFilePath

    # Adding a short delay to ensure the transaction is committed
    Start-Sleep -Seconds 2

function Transfer-ZipFile {
    param (
        [string]$zipFilePath,
        [string]$cloudBasePath,
        [string]$backupID,
        [string]$serverID
    )

    # Extract the date and hostname folder from the zip file path
    $dateFolder = (Get-Date).ToString("yyyyMMdd")
    $hostnameFolder = (Get-WmiObject Win32_ComputerSystem).Name
    
    # Construct the full destination path in cloud storage
    $cloudZipPath = Join-Path -Path $cloudBasePath -ChildPath (Join-Path -Path $dateFolder -ChildPath (Join-Path -Path $hostnameFolder -ChildPath ([System.IO.Path]::GetFileName($zipFilePath))))

    # Check if the .zip file already exists in the cloud storage, skip transfer if it does
    if (-not (Test-Path -Path $cloudZipPath)) {
        # Copy the .zip file to the cloud storage path
        $destinationFileName = [System.IO.Path]::GetFileName($zipFilePath)
        try {
            Copy-Item -Path $zipFilePath -Destination $cloudZipPath -Credential $Credential -Force
            Write-LogEntry "Transferred .zip file: $destinationFileName" $logFilePath

            # Prepare the SQL query with parameters
            $insertFileQuery = @"
            INSERT INTO BackupFiles (BackupID, ServerID, FileName, FileSizeBytes, FilePath)
            VALUES ('$backupID', '$serverID', '$destinationFileName', '$((Get-Item $zipFilePath).Length)', '$cloudZipPath')
"@

            # Execute the SQL command
            Invoke-Sqlcmd -Query $insertFileQuery -ConnectionString $connectionString
            Write-LogEntry "Inserted file details into BackupFiles table" $logFilePath
        } catch {
            Write-LogEntry "Error: Failed to transfer .zip file: $destinationFileName. Exception: $_" $logFilePath
            throw $_
        }
    }
}

# Transfer .zip files to cloud storage
$zipFiles = Get-ChildItem -Path $compressionFolder -Filter *.zip

foreach ($zipFile in $zipFiles) {
    Transfer-ZipFile -zipFilePath $zipFile.FullName -cloudBasePath $cloudBasePath -backupID $backupID -serverID $serverID
}

Write-LogEntry "------------Daily backup finished------------" $logFilePath

    # Maximum number of days to retain cloud backups
    $maxDaysToRetainCloud = 6  # Adjust as needed
	$weeklymonthlyremove = 90

	# Define the paths for storing backups on Sunday
	
    # Post-backup process
    $backupEndTime = Get-Date
    $backupDuration = [math]::Round(($backupEndTime - $backupStartTime).TotalSeconds)
    $totalFilesTransferred = $zipFiles.Count
    $logDirectory = "C:\Logs"
    $logFilePathValue = Join-Path -Path $logDirectory -ChildPath "$(Get-Date -Format 'yyyyMMdd').txt"
    $status = "Successful"
    $errorMessage = ""

    # Verification: Check if all local .bak files have corresponding .zip files in the cloud
    $localBakFiles = Get-ChildItem -Path $sourcePath -Filter *.bak
    $cloudZipFiles = Get-ChildItem -Path $hostnameFolderPath -Filter *.zip

    # Count the number of .bak files and .zip files
    $numberOfBakFiles = $localBakFiles.Count
    $numberOfZipFiles = $cloudZipFiles.Count

    # Check if there are local .bak files
    if ($numberOfBakFiles -eq 0) {
        Write-LogEntry "Verification failed: No local .bak files found." $logFilePath
        $verificationFailed = $true
        $status = "Failed"
        $errorMessage = "Verification failed: No local .bak files found."
    } else {
        # Check if there are no local .zip files
        if ($numberOfZipFiles -eq 0) {
            Write-LogEntry "Verification failed: No local .zip files found." $logFilePath
            $verificationFailed = $true
            $status = "Failed"
            $errorMessage = "Verification failed: No local .zip files found."
        } else {
            # Compare .bak files to .zip files
            if ($numberOfBakFiles -eq $numberOfZipFiles) {
                Write-LogEntry "Verification successful: The total number of files matches between the local folder and cloud storage." $logFilePath
                Write-LogEntry "------------Total no. of compressed file------------" $logFilePath
                Write-LogEntry "Total .bak files: $numberOfBakFiles" $logFilePath
                Write-LogEntry "Total .zip files: $numberOfZipFiles" $logFilePath

                # Remove older cloud backups
                $cutOffDateCloud = (Get-Date).AddDays(-$maxDaysToRetainCloud)
                $oldCloudBackupFolders = Get-ChildItem -Path $cloudBasePath | Where-Object { $_.PSIsContainer -and $_.Name -lt $cutOffDateCloud.ToString("yyyyMMdd") }
                $oldCloudBackupFolders | ForEach-Object {
                    $folderPath = Join-Path -Path $cloudBasePath -ChildPath $_.Name
                    Remove-Item -Path $folderPath -Recurse -Force
                    Write-LogEntry "Removed older backup folder: $folderPath" $logFilePath
                }
            } else {
                Write-LogEntry "Verification failed: The total number of files does not match between the local folder and cloud storage." $logFilePath
                $verificationFailed = $true
                $status = "Failed"
                $errorMessage = "Verification failed: The total number of files does not match between the local folder and cloud storage."
            }
        }
    }

    # Update BackupDetails table with final information
    try {
        $updateBackupQuery = @"
        UPDATE BackupDetails
        SET TotalFiles = '$totalFilesTransferred',
            BackupEndTime = '$backupEndTime',
            Status = '$status',
            BackupDurationSeconds = '$backupDuration',
            LogFilePath = '$logFilePathValue',
            ErrorMessage = '$errorMessage'
        WHERE BackupID = '$backupID'
"@
        Invoke-Sqlcmd -Query $updateBackupQuery -ConnectionString $connectionString
        Write-LogEntry "Backup details updated in BackupDetails table" $logFilePath
    } catch {
        Write-LogEntry "Error: Failed to update BackupDetails table. Exception: $_" $logFilePath
    }

    # Wait for 1 minute (60 seconds)
    Start-Sleep -Seconds 60
} while ($verificationFailed -and $retryCountVerification -lt $maxRetryAttemptsVerification)


	# Check if today is Sunday
	if ((Get-Date).DayOfWeek -eq 'Sunday') {

Write-LogEntry "------------Weekly backup started------------" $logFilePath

	# Get the current date and time for backup details
	$backupDateTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
	$backupStartTime = Get-Date

	# Insert a single entry into the BackupDetails table
	$insertBackupQuery = @"
	INSERT INTO BackupDetails (ServerID, BackupType, BackupDate, BackupStartTime)
	VALUES ('$serverID', 'Weekly', '$backupDateTime', '$backupDateTime');
	SELECT SCOPE_IDENTITY() AS BackupID;
"@
	$backupResult = Invoke-Sqlcmd -Query $insertBackupQuery -ConnectionString $connectionString
	$backupID = $backupResult.BackupID

	Write-LogEntry "Inserted weekly backup details into BackupDetails table" $logFilePath

	# Adding a short delay to ensure the transaction is committed
	Start-Sleep -Seconds 2

	# Function to log file transfer details and insert into BackupFiles table
	function Log-And-Insert-FileDetails {
		param (
			[string]$zipFilePath,
			[string]$cloudZipPath,
			[string]$backupID,
			[string]$serverID
		)

		$destinationFileName = [System.IO.Path]::GetFileName($zipFilePath)
		
		try {
			# Prepare the SQL query with parameters
			$insertFileQuery = @"
			INSERT INTO BackupFiles (BackupID, ServerID, FileName, FileSizeBytes, FilePath)
			VALUES ('$backupID', '$serverID', '$destinationFileName', '$((Get-Item $zipFilePath).Length)', '$cloudZipPath')
"@

        # Execute the SQL command
        $insertResult = Invoke-Sqlcmd -Query $insertFileQuery -ConnectionString $connectionString
        Write-LogEntry "Inserted file details into BackupFiles table: $destinationFileName" $logFilePath
    } catch {
        Write-LogEntry "Error: Failed to insert file details into BackupFiles table: $destinationFileName. Exception: $_" $logFilePath
        throw $_
    }
}

	# Copy files to the weekly backup path
	$copiedFiles7 = Copy-Item -Path $currentDateFolderPath -Destination $weeklyBackupPath -Recurse -Force -Credential $Credential -PassThru
	# Filter only files (exclude directories)
	$copiedFiles7 = $copiedFiles7 | Where-Object { -not $_.PSIsContainer }

	$totalFilesTransferred = 0

# Transfer .zip files to cloud storage and log each transferred file
foreach ($copiedFile77 in $copiedFiles7) {
    # Extract the date and hostname folder from the zip file path
    $dateFolder = (Get-Date).ToString("yyyyMMdd")
    $hostnameFolder = (Get-WmiObject Win32_ComputerSystem).Name
    
    # Construct the full destination path in cloud storage
    $cloudZipPath = Join-Path -Path $weeklyBackupPath -ChildPath (Join-Path -Path $dateFolder -ChildPath (Join-Path -Path $hostnameFolder -ChildPath ([System.IO.Path]::GetFileName($copiedFile77.FullName))))
    
    Write-LogEntry "Transferred .zip file: $($copiedFile77.Name)" $logFilePath
    Log-And-Insert-FileDetails -zipFilePath $copiedFile77.FullName -cloudZipPath $cloudZipPath -backupID $backupID -serverID $serverID

    $totalFilesTransferred++
}

	# Post-backup process
	$backupEndTime = Get-Date
	$backupDuration = [math]::Round(($backupEndTime - $backupStartTime).TotalSeconds)
	$logDirectory = "C:\Logs"
	$logFilePathValue = Join-Path -Path $logDirectory -ChildPath "$(Get-Date -Format 'yyyyMMdd').txt"
	$status = "Successful"
	$errorMessage = ""

	# Verification: Check if all local .bak files have corresponding .zip files in the cloud
	$localBakFiles = Get-ChildItem -Path $sourcePath -Filter *.bak
	$cloudZipFiles = Get-ChildItem -Path $weeklyBackupPath -Recurse -Filter *.zip

	# Count the number of .bak files and .zip files
	$numberOfBakFiles = $localBakFiles.Count
	$numberOfZipFiles = $cloudZipFiles.Count

# Check if there are local .bak files
if ($numberOfBakFiles -eq 0) {
    Write-LogEntry "Verification failed: No local .bak files found." $logFilePath
    $status = "Failed"
    $errorMessage = "Verification failed: No local .bak files found."
} else {
    # Check if there are no local .zip files
    if ($numberOfZipFiles -eq 0) {
        Write-LogEntry "Verification failed: No local .zip files found." $logFilePath
        $status = "Failed"
        $errorMessage = "Verification failed: No local .zip files found."
    } else {
        # Compare .bak files to .zip files
        if ($numberOfBakFiles -eq $numberOfZipFiles) {
            Write-LogEntry "Verification successful: The total number of files matches between the local folder and cloud storage." $logFilePath
            Write-LogEntry "------------Total no. of compressed file------------" $logFilePath
            Write-LogEntry "Total .bak files: $numberOfBakFiles" $logFilePath
            Write-LogEntry "Total .zip files: $numberOfZipFiles" $logFilePath
        } else {
            Write-LogEntry "Verification failed: The total number of files does not match between the local folder and cloud storage." $logFilePath
            $status = "Failed"
            $errorMessage = "Verification failed: The total number of files does not match between the local folder and cloud storage."
        }
    }
}

	# Update BackupDetails table with final information
	try {
		$updateBackupQuery = @"
		UPDATE BackupDetails
		SET TotalFiles = '$totalFilesTransferred',
			BackupEndTime = '$backupEndTime',
			Status = '$status',
			BackupDurationSeconds = '$backupDuration',
			LogFilePath = '$logFilePathValue',
			ErrorMessage = '$errorMessage'
		WHERE BackupID = '$backupID'
"@
    Invoke-Sqlcmd -Query $updateBackupQuery -ConnectionString $connectionString
    Write-LogEntry "Backup details updated in BackupDetails table" $logFilePath
} catch {
    Write-LogEntry "Error: Failed to update BackupDetails table. Exception: $_" $logFilePath
}

	Write-LogEntry "------------Weekly backup finished------------" $logFilePath

    # Remove older cloud backups
    $cutOffDateCloud1 = (Get-Date).AddDays(-$weeklymonthlyremove)
    $oldCloudBackupFolders1 = Get-ChildItem -Path $weeklyBackupPath | Where-Object { $_.PSIsContainer -and $_.Name -lt $cutOffDateCloud1.ToString("yyyyMMdd") }
    $oldCloudBackupFolders1 | ForEach-Object {
    $folderPath1 = Join-Path -Path $weeklyBackupPath -ChildPath $_.Name
    Remove-Item -Path $folderPath1 -Recurse -Force
    Write-LogEntry "Removed Weekly older backup folder: $folderPath1" $logFilePath
    }
}
		
		Start-Sleep -Seconds 60

	# Check if today is the last day of the month
	if ((Get-Date).AddDays(1).Month -ne (Get-Date).Month) {
		
	# Determine the source path of the last daily backup
	$lastDailyBackupPath = Get-ChildItem -Path $dailyBackupPath -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 1
	if ($lastDailyBackupPath -eq $null) {
			Write-LogEntry "Monthly backup will not be performed." $logFilePath
	} 
	else {
		
	# Log the start of monthly backup
	Write-LogEntry "------------Monthly backup started------------" $logFilePath

	# Get the current date and time for backup details
	$backupDateTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
	$backupStartTime = Get-Date

	# Insert a single entry into the BackupDetails table for monthly backup
	$insertBackupQuery = @"
	INSERT INTO BackupDetails (ServerID, BackupType, BackupDate, BackupStartTime)
	VALUES ('$serverID', 'Monthly', '$backupDateTime', '$backupDateTime');
	SELECT SCOPE_IDENTITY() AS BackupID;
"@
	$backupResult = Invoke-Sqlcmd -Query $insertBackupQuery -ConnectionString $connectionString
	$backupID = $backupResult.BackupID

	Write-LogEntry "Inserted monthly backup details into BackupDetails table" $logFilePath

	# Adding a short delay to ensure the transaction is committed
	Start-Sleep -Seconds 2

# Function to log file transfer details and insert into BackupFiles table
function Log-And-Insert-FileDetails {
    param (
        [string]$zipFilePath,
        [string]$cloudZipPath,
        [string]$backupID,
        [string]$serverID
    )

    $destinationFileName = [System.IO.Path]::GetFileName($zipFilePath)
    
    try {
        # Prepare the SQL query with parameters
        $insertFileQuery = @"
        INSERT INTO BackupFiles (BackupID, ServerID, FileName, FileSizeBytes, FilePath)
        VALUES ('$backupID', '$serverID', '$destinationFileName', '$((Get-Item $zipFilePath).Length)', '$cloudZipPath')
"@

        # Execute the SQL command
        $insertResult = Invoke-Sqlcmd -Query $insertFileQuery -ConnectionString $connectionString
        Write-LogEntry "Inserted file details into BackupFiles table: $destinationFileName" $logFilePath
    } catch {
        Write-LogEntry "Error: Failed to insert file details into BackupFiles table: $destinationFileName. Exception: $_" $logFilePath
        throw $_
    }
}

	# Ensure $dateFolder and $hostnameFolder are initialized correctly
	$dateFolder = (Get-Date).ToString("yyyyMMdd")
	$hostnameFolder = (Get-WmiObject Win32_ComputerSystem).Name

	# Copy files to the monthly backup path
	$copiedFiles30 = Copy-Item -Path $currentDateFolderPath -Destination $monthlyBackupPath -Recurse -Force -Credential $Credential -PassThru
	# Filter only files (exclude directories)
	$copiedFiles30 = $copiedFiles30 | Where-Object { -not $_.PSIsContainer }

	$totalFilesTransferred = 0

# Transfer .zip files to cloud storage and log each transferred file
foreach ($copiedFile300 in $copiedFiles30) {
    # Construct the full destination path in cloud storage
    $cloudZipPath = Join-Path -Path $monthlyBackupPath -ChildPath (Join-Path -Path $dateFolder -ChildPath (Join-Path -Path $hostnameFolder -ChildPath ([System.IO.Path]::GetFileName($copiedFile300.FullName))))
    
    Write-LogEntry "Transferred .zip file: $($copiedFile300.Name)" $logFilePath
    Log-And-Insert-FileDetails -zipFilePath $copiedFile300.FullName -cloudZipPath $cloudZipPath -backupID $backupID -serverID $serverID

    $totalFilesTransferred++
}

	# Post-backup process
	$backupEndTime = Get-Date
	$backupDuration = [math]::Round(($backupEndTime - $backupStartTime).TotalSeconds)
	$logDirectory = "C:\Logs"
	$logFilePathValue = Join-Path -Path $logDirectory -ChildPath "$(Get-Date -Format 'yyyyMMdd').txt"
	$status = "Successful"
	$errorMessage = ""

	# Verification: Check if all local .bak files have corresponding .zip files in the cloud
	$localBakFiles = Get-ChildItem -Path $sourcePath -Filter *.bak
	$cloudZipFiles = Get-ChildItem -Path $monthlyBackupPath -Recurse -Filter *.zip

	# Count the number of .bak files and .zip files
	$numberOfBakFiles = $localBakFiles.Count
	$numberOfZipFiles = $cloudZipFiles.Count

# Check if there are local .bak files
if ($numberOfBakFiles -eq 0) {
    Write-LogEntry "Verification failed: No local .bak files found." $logFilePath
    $status = "Failed"
    $errorMessage = "Verification failed: No local .bak files found."
} else {
    # Check if there are no local .zip files
    if ($numberOfZipFiles -eq 0) {
        Write-LogEntry "Verification failed: No local .zip files found." $logFilePath
        $status = "Failed"
        $errorMessage = "Verification failed: No local .zip files found."
    } else {
        # Compare .bak files to .zip files
        if ($numberOfBakFiles -eq $numberOfZipFiles) {
            Write-LogEntry "Verification successful: The total number of files matches between the local folder and cloud storage." $logFilePath
            Write-LogEntry "------------Total no. of compressed file------------" $logFilePath
            Write-LogEntry "Total .bak files: $numberOfBakFiles" $logFilePath
            Write-LogEntry "Total .zip files: $numberOfZipFiles" $logFilePath
        } else {
            Write-LogEntry "Verification failed: The total number of files does not match between the local folder and cloud storage." $logFilePath
            $status = "Failed"
            $errorMessage = "Verification failed: The total number of files does not match between the local folder and cloud storage."
        }
    }
}

	# Update BackupDetails table with final information
	try {
		$updateBackupQuery = @"
		UPDATE BackupDetails
		SET TotalFiles = '$totalFilesTransferred',
			BackupEndTime = '$backupEndTime',
			Status = '$status',
			BackupDurationSeconds = '$backupDuration',
			LogFilePath = '$logFilePathValue',
			ErrorMessage = '$errorMessage'
		WHERE BackupID = '$backupID'
"@
    Invoke-Sqlcmd -Query $updateBackupQuery -ConnectionString $connectionString
    Write-LogEntry "Backup details updated in BackupDetails table" $logFilePath
} catch {
    Write-LogEntry "Error: Failed to update BackupDetails table. Exception: $_" $logFilePath
}

	# Log the end of monthly backup
	Write-LogEntry "------------Monthly backup finished------------" $logFilePath

		
		# Remove older cloud backups
         $cutOffDateCloud2 = (Get-Date).AddDays(-$weeklymonthlyremove)
         $oldCloudBackupFolders2 = Get-ChildItem -Path $monthlyBackupPath | Where-Object { $_.PSIsContainer -and $_.Name -lt $cutOffDateCloud2.ToString("yyyyMMdd") }
         $oldCloudBackupFolders2 | ForEach-Object {
         $folderPath2 = Join-Path -Path $monthlyBackupPath -ChildPath $_.Name
         Remove-Item -Path $folderPath2 -Recurse -Force
         Write-LogEntry "Removed Monthly older backup folder: $folderPath2" $logFilePath
					
				}
			}
		}

# Send an email using SMTP
$recipients = @("abc@gmail.com")
$smtpSenderMailAdd = "dba@gmail.com"  # Replace with your Gmail email address
$smtpPassword = ""  # Replace with your Gmail password
$smtpIp = "smtp.gmail.com"
$smtpPortNo = 587

# Initialize the mail body with the start message
$mailBody = "Server: $hostnameFolder`r`n`r`n"

# Check if Daily Backup performed
if ($zipFiles.Count -gt 0) {
    $mailBody += "Following Database Backup compressed files copied as Daily Backup.`r`n"
    # Add the backup details to the mail body
    $totalFiles = 0
    foreach ($zipFile in $zipFiles) {
        $mailBody += "File: $($zipFile.Name) copied`r`n"
        $totalFiles++
    }
    $mailBody += "`r`nTotal files: $totalFiles`r`n"
} else {
    $mailBody += "Daily backup will not be performed.`r`n"
}

# Check if Weekly Backup performed
if ((Get-Date).DayOfWeek -eq 'Sunday') {
    if ($copiedFiles7 -ne $null) {
        $mailBody += "`r`nFollowing Database Backup compressed files copied as Weekly Backup.`r`n"
        $totalFiles = 0
        foreach ($copiedFile77 in $copiedFiles7) {
            $mailBody += "File: $($copiedFile77.Name) copied`r`n"
            $totalFiles++
        }
        $mailBody += "`r`nTotal files: $totalFiles`r`n"
    } else {
        $mailBody += "`r`nWeekly backup will not be performed.`r`n"
    }
}

# Check if Monthly Backup performed
if ((Get-Date).AddDays(1).Month -ne (Get-Date).Month) {
    if ($copiedFiles30 -ne $null) {
        $mailBody += "`r`nFollowing Database Backup compressed files copied as Monthly Backup.`r`n"
        $totalFiles = 0
        foreach ($copiedFile300 in $copiedFiles30) {
            $mailBody += "File: $($copiedFile300.Name) copied`r`n"
            $totalFiles++
        }
        $mailBody += "`r`nTotal files: $totalFiles`r`n"
    } else {
        $mailBody += "`r`nMonthly backup will not be performed.`r`n"
    }
}

# Create the email message
$mailParams = @{
    From         = $smtpSenderMailAdd
    To           = $recipients  # Use the array of recipient email addresses
    Subject      = "Backup Completed for $hostnameFolder"
    Body         = $mailBody
    SmtpServer   = $smtpIp
    Port         = $smtpPortNo
    Credential   = New-Object System.Management.Automation.PSCredential($smtpSenderMailAdd, (ConvertTo-SecureString $smtpPassword -AsPlainText -Force))
    UseSsl       = $true
}

# Send the email
Send-MailMessage @mailParams

Write-LogEntry "Mail sent to $($recipients -join ', ')" $logFilePath

# Remove the mapped drive after use
Remove-PSDrive -Name "V"

# Clean up local compressed files
Remove-Item -Path $compressionFolder -Recurse -Force