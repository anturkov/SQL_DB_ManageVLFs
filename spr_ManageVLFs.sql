USE AdminDB -- set a database, in which you want to create this procedure (do not use system databases)
GO

/*
Author: Antonio Turkovic (Microsoft Data&AI CE)
Version: 202009-01
Supported SQL Server Versions: >= SQL Server 2016 SP2 (Standard and Enterprise Edition)	

Description:
This script can be used to distribute optimize the amount of VLFs (virtual log files).
It will create a stored procedure called "dbo.spr_ManageVLFs".

Requirements:
- User must have SYSADMIN privileges
- BEFORE running the process, perform a FULL backup of your database (database will be set to SIMPLE recovery model)
- AFTER running the process, perform another FULL backup to start a new backup chain (database will be set to the initial recovery model)
- Log file must be larger than 512 MB
- Only one Transaction log file is allowed


Parameter:
	- @dbName: Specify the database you want to work with
		- Database must not be a member of an Availability Group
		- Ensure that no users are working on the database during the entire process

Best Practices:
	- It is best practice to reduce the amount of VLFs, if there are more than 1000
		- run "DBCC LOGINFO" or "SELECT * FROM master.sys.dm_db_log_info(DB_ID('database_name'))" to get total VLF count
	- This script applies all best practices according to docs.microsoft.com
		- https://docs.microsoft.com/en-us/sql/relational-databases/sql-server-transaction-log-architecture-and-management-guide?view=sql-server-ver15#physical_arch

Example:
	- on a database with a current log size of 17937 MB having 897 VLFs
	- EXEC dbo.spr_ManageVLFs @dbName = 'myDB'
		- New log file size will be 16384 MB (pre-sized in 8192 MB steps), autogrowth set to 512 MB and a total of 34 VLFs 
Output:
	- Review the "Messages" for details about the process

*/

CREATE PROCEDURE spr_ManageVLFs
	-- Specify the database you want to work with
	@dbName NVARCHAR(256) = ''
AS
BEGIN
	
	-- Var for Dynamic SQL
	DECLARE @cmd NVARCHAR(MAX)

	-- Var for RAISERROR messages
	DECLARE @msg NVARCHAR(4000)
	
	-- Recovery Model
	DECLARE @currRecoveryModel NVARCHAR(32)

	-- Org VLF Count
	DECLARE @orgVLFCount BIGINT = 0

	-- New VLF Count
	DECLARE @newVLFCount INT = 0

	-- Store current Log File size
	DECLARE @currLogSizeMB BIGINT = 0

	-- Recommended Grow steps
	DECLARE @growStepsMB INT = 0

	--Recommended AUTOGrow Size
	DECLARE @autoGrowMB INT = 512
	DECLARE @tmpGrowMB INT = 0

	--How many times to grow the log
	DECLARE @growLogCounter INT = 0

	-- How man times to shrink the file
	DECLARE @shrinkLoops INT = 20
	DECLARE @i INT = 0

	-- Log file logical Name
	DECLARE @logName NVARCHAR(256)


	--#############################################################
	-- VERIFICATION

	-- Check if database is in an AG
	IF EXISTS (
		SELECT 1
		FROM sys.dm_hadr_database_replica_states
		WHERE database_id = DB_ID(@dbName)
	)
	BEGIN
		SET @msg = FORMAT(GETDATE(), 'yyyy-MM-dd HH:mm:ss') + ' | ERROR | Database "' + @dbName + '" is member of an Availability Group.'
		RAISERROR(@msg, 10, 1) WITH NOWAIT;
		RETURN;
	END

	-- Get VLFs Count
	SET @orgVLFCount = (SELECT COUNT(1) FROM master.sys.dm_db_log_info(DB_ID(@dbName)))
	SET @msg = FORMAT(GETDATE(), 'yyyy-MM-dd HH:mm:ss') + ' | INFO | Current VLF count = ' + CONVERT(NVARCHAR(32), @orgVLFCount)
	RAISERROR(@msg, 10, 1) WITH NOWAIT;

	-- Check if database is in Simple mode
	SET @currRecoveryModel = (
		SELECT recovery_model_desc 
		FROM sys.databases
		WHERE name = @dbName
	)

	IF (@currRecoveryModel != 'SIMPLE')
	BEGIN
		SET @cmd = '
			USE [master];
			ALTER DATABASE [' + @dbName + '] SET RECOVERY SIMPLE WITH NO_WAIT;
		';
		BEGIN TRY
			EXEC sp_executesql @cmd
		END TRY
		BEGIN CATCH
			SET @msg = FORMAT(GETDATE(), 'yyyy-MM-dd HH:mm:ss') + ' | ERROR | Could not change recovery model to simple - terminating script'
			RAISERROR(@msg, 10, 1) WITH NOWAIT;
			RETURN;
		END CATCH
	END

	-- Check if there are more than 1 log file --> terminate
	IF(
		(
			SELECT COUNT(1)
			FROM master.sys.master_files
			WHERE type = 1
			AND database_id = DB_ID(@dbName)
		)
		> 1
	)
	BEGIN
		SET @msg = FORMAT(GETDATE(), 'yyyy-MM-dd HH:mm:ss') + ' | ERROR | Database has more than one log file - terminating script'
		RAISERROR(@msg, 10, 1) WITH NOWAIT;
		RETURN;
	END

	-- Get Logfilename
	SET @logName = (
		SELECT name 
		FROM master.sys.master_files 
		WHERE database_id = DB_ID(@dbName)
		AND type = 1
	)

	-- Get Log Size
	SET @currLogSizeMB = (
		SELECT size * 8 / 1024
		FROM master.sys.master_files
		WHERE database_id = DB_ID(@dbName)
		AND type = 1
	)

	-- Calculate new size, grow size

	-- Check how many times can 8192 MB fit in current logsize
	IF(((@currLogSizeMB / 8192) > 0) AND (@growStepsMB = 0))
	BEGIN
		SET @growStepsMB = 8192
	END

	-- 4096
	IF(((@currLogSizeMB / 4096) > 0) AND (@growStepsMB = 0))
	BEGIN
		SET @growStepsMB = 4096
	END

	-- 2048
	IF(((@currLogSizeMB / 2048) > 0) AND (@growStepsMB = 0))
	BEGIN
		SET @growStepsMB = 2048
	END

	-- 1024
	IF(((@currLogSizeMB / 1024) > 0) AND (@growStepsMB = 0))
	BEGIN
		SET @growStepsMB = 1024
	END

	-- 512
	IF(((@currLogSizeMB / 512) > 0) AND (@growStepsMB = 0))
	BEGIN
		SET @growStepsMB = 512
	END

	-- too small
	IF(@growStepsMB = 0)
	BEGIN
		SET @msg = FORMAT(GETDATE(), 'yyyy-MM-dd HH:mm:ss') + ' | WARN | Current log file size is too small - nothing to do - terminating script'
		RAISERROR(@msg, 10, 1) WITH NOWAIT;
		RETURN;
	END

	-- SET grow log counter
	IF((@currLogSizeMB / @growStepsMB) >= 8)
	BEGIN
		SET @growLogCounter = 8
	END
	ELSE
	BEGIN
		SET @growLogCounter = @currLogSizeMB / @growStepsMB
	END

	--###########################################
	-- Shrink log file
	SET @cmd = '
		USE [' + @dbName + '];
		DBCC SHRINKFILE (N''' + @logName + ''' , 1);
	'

	WHILE (@i <= @shrinkLoops)
	BEGIN
		EXEC sp_executesql @cmd
		SET @i += 1;
	END

	--#############################################
	-- Get new size of log
	-- if new size is larger than 1 GB --> cancel query
	IF(
		(
			SELECT size * 8 / 1024
			FROM master.sys.master_files
			WHERE database_id = DB_ID(@dbName)
			AND type = 1
		) > 1024
	)
	BEGIN
		SET @msg = FORMAT(GETDATE(), 'yyyy-MM-dd HH:mm:ss') + ' | ERROR | Shrink operations failed - could not shrink log file to smaller size than 1024 MB.' + CHAR(13) + CHAR(10) +
		'If the log gets too fragmented over time it can happen, that shrink operations fail or are ineffective.' + CHAR(13) + CHAR(10) +
		'Please proceed manually!'
		RAISERROR(@msg, 10, 1) WITH NOWAIT;
		RETURN;
	END
	

	-- Resize LOG
	SET @cmd = 'ALTER DATABASE [' + @dbName + '] MODIFY FILE ( NAME = N''' + @logName + ''', SIZE = ' + CONVERT(NVARCHAR(32), @growStepsMB) + 'MB )';
	SET @tmpGrowMB = @growStepsMB
	EXEC sp_executesql @cmd

	WHILE @growLogCounter != 1
	BEGIN
		SET @tmpGrowMB += @growStepsMB
		SET @cmd = 'ALTER DATABASE [' + @dbName + '] MODIFY FILE ( NAME = N''' + @logName + ''', SIZE = ' + CONVERT(NVARCHAR(32), @tmpGrowMB) + 'MB )';
		EXEC sp_executesql @cmd
		
		SET @growLogCounter = @growLogCounter - 1
	END

	-- SET AUTOGROW
	SET @cmd = '
	USE [master];
	ALTER DATABASE [' + @dbName + '] MODIFY FILE ( NAME = N''' + @logName + ''', FILEGROWTH = ' + CONVERT(NVARCHAR(32), @autoGrowMB) + 'MB );
	';
	EXEC sp_executesql @cmd

	-- RESET Recovery Model
	IF(@currRecoveryModel != 'SIMPLE')
	BEGIN
		SET @cmd = '
			USE [master];
			ALTER DATABASE [' + @dbName + '] SET RECOVERY ' + @currRecoveryModel + ' WITH NO_WAIT;
		';
		EXEC sp_executesql @cmd

		SET @msg = FORMAT(GETDATE(), 'yyyy-MM-dd HH:mm:ss') + ' | INFO | Recovery Model set to "' + @currRecoveryModel + '". Please create full backup after this process to start the backup chain!'
		RAISERROR(@msg, 10, 1) WITH NOWAIT;
	END

	-- Get new VLF Count
	SET @newVLFCount = (SELECT COUNT(1) FROM master.sys.dm_db_log_info(DB_ID(@dbName)))

	SET @msg = FORMAT(GETDATE(), 'yyyy-MM-dd HH:mm:ss') + ' | INFO | VLF optimization finished - new VLF Count = ' + CONVERT(NVARCHAR(32), @newVLFCount)
	RAISERROR(@msg, 10, 1) WITH NOWAIT;
	RETURN;

END
