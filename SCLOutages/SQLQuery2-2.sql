--select top 100 format( MAX_POINT_X,'0.################'), MAX_POINT_X from OMS_Device_Outages_2024

select top 100 *
from scl_2024_oms_device_outages_2024
where event_idx =160010 and serv_loc_id = 10984091


geometry::Point(MAX_POINT_X, MAX_POINT_Y, 2285).STTransform(4326).STY AS Lat,
  geometry::Point(MAX_POINT_X, MAX_POINT_Y, 2285).STTransform(4326).STX AS Lon,

* 


from OMS_Device_Outages_2024
where MIN_SUBSTATION = 'shoreline'
and MAX_NUM_CUST_OUT < 30;


select top 100 * from OMS_Device_Outages_2024
where event_idx =160040
and MAX_POINT_X=1282351


SELECT @@VERSION;   -- shows product & build





ALTER TABLE dbo.OMS_Device_Outages_2024 ADD CONSTRAINT
	PK_OMS_Device_Outages_2024 PRIMARY KEY CLUSTERED 
	(
	EVENT_IDX,
	SERV_LOC_ID
	) WITH( STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]


The transaction log for database 'StOrage' is full due to 'ACTIVE_TRANSACTION' and the holdup lsn is (87:328:3).
To resolve the ACTIVE_TRANSACTION error in your 'StOrage' database, you must identify and address the uncommitted transaction currently holding the Log Sequence Number (LSN) (87:328:3). This LSN represents the start of the oldest active transaction that is preventing the transaction log from truncating. 
1. Identify the Problematic Transaction 
Run the following command in SQL Server Management Studio (SSMS) while connected to the 'StOrage' database: 
sql
DBCC OPENTRAN('StOrage');
Use code with caution.

This command will return the SPID (Server Process ID) and the Start Time associated with the oldest active transaction (the one matching your holdup LSN). 
Alternatively, use this query to see more details, including the actual SQL code being executed: 
sql
SELECT 
    st.session_id, 
    dt.database_transaction_begin_time, 
    s.login_name, 
    s.host_name, 
    txt.text AS [SQL Text]
FROM sys.dm_tran_database_transactions dt
JOIN sys.dm_tran_session_transactions st ON dt.transaction_id = st.transaction_id
JOIN sys.dm_exec_sessions s ON st.session_id = s.session_id
CROSS APPLY sys.dm_exec_sql_text(s.session_id) txt -- Note: May need sys.dm_exec_requests for current handle
WHERE dt.database_id = DB_ID('StOrage');
Use code with caution.

2. Resolve the Active Transaction 
Commit or Rollback: If the session is still active and you recognize the process, try to finish it normally.
Kill the Session: If the transaction is orphaned (the application disconnected but the transaction stayed open) or it is a long-running runaway query, you can terminate it:
sql
KILL <SPID>; -- Replace <SPID> with the ID found in Step 1
Use code with caution.

Caution: Killing a transaction will initiate a rollback, which may take considerable time depending on the amount of data modified. 
3. Immediate Space Recovery
If the log is completely full and you cannot even run a KILL command, you may need to provide temporary "breathing room":
Increase Log File Size: If disk space permits, manually increase the log file size or the MAXSIZE limit in Database Properties.
Add a Temporary Log File: Add a second log file on a different drive with more space.
Log Backup: If the database is in FULL recovery mode, run a transaction log backup to truncate the inactive portion of the log:
sql
BACKUP LOG [StOrage] TO DISK = 'C:\Backups\StOrage_Log_Emergency.trn';
Use code with caution.

 
4. Long-term Prevention
Review Recovery Model: If you do not need point-in-time recovery, consider switching to SIMPLE recovery mode.
Scheduled Backups: Ensure you have a SQL Server Maintenance Plan or a tool like Ola Hallengren's scripts to back up logs frequently. 




What applications/queries are causing long-running transactions?

What's the difference between truncating and shrinking a transaction log?

What are the implications of switching from FULL to SIMPLE recovery mode?

undefined
undefined
undefined
19 sites
Troubleshoot a full transaction log (SQL Server Error 9002)
Sep 25, 2025 — In this article * Common reasons for a full transaction log. * 1. Truncate the log. * 2. Resolve full disk volume. * 3. Change log...

Microsoft Learn
SQL Server How To Solve 'The transaction log for database x ...
Feb 14, 2023 — Here are some steps you can try: * Identify the active transaction causing the log to fill up: To do this, you can use the sys. dm...

Beekeeper Studio

Fixing the SQL Server Transaction Log Full Issue - Medium
Apr 27, 2025 — Fixing the SQL Server Transaction Log Full Issue: A DBA's... * Step 1: Identify Open Transactions Blocking the Log. What to Do: Ch...

Medium


SELECT name, log_reuse_wait_desc FROM sys.databases WHERE name = 'scloutage'


SELECT 
    s.session_id, 
    s.status, 
    s.login_name, 
    s.host_name, 
    dt.database_transaction_begin_time, 
    dt.database_transaction_log_record_count
FROM sys.dm_tran_database_transactions dt
JOIN sys.dm_tran_session_transactions st ON dt.transaction_id = st.transaction_id
JOIN sys.dm_exec_sessions s ON st.session_id = s.session_id
WHERE dt.database_id = DB_ID('SclOutage');
SELECT name, log_reuse_wait_desc FROM sys.databases WHERE name = 'scloutage';



DBCC SHRINKFILE (N'scloutage_log', 1); -- Replace with your actual logical log name
