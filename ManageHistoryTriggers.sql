/*
MIT License

Copyright (c) 2016 Roman Pokrovskij (Github user rpokrovskij)

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

*/
/*
-- Test

DROP TABLE Test
DROP TABLE Test_History
IF EXISTS(SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'Test_HistorySeq') AND type = 'SO')
	DROP SEQUENCE Test_HistorySeq
CREATE TABLE [dbo].[Test](
	[TestId] [int] IDENTITY(1000,1) NOT NULL,
	[TestValue] [nvarchar](100) NOT NULL,
	[TestRowVersion] [timestamp] NOT NULL,
    PRIMARY KEY CLUSTERED ([TestId] ASC) ON [PRIMARY]
) ON [PRIMARY]
GO
exec [dbo].[ManageHistoryTriggers] 'Test', 'dbo', @PrintOnly=0, @CreateTriggers=1, @CreatePrimaryKey=1, @UseDateTime2=0

INSERT INTO dbo.Test (TestValue) VALUES('A001')
INSERT INTO dbo.Test (TestValue) VALUES('A002'),('A003')
UPDATE dbo.Test  SET TestValue = 'B001' WHERE TestValue= 'A001'
UPDATE dbo.Test  SET TestValue = 'C001' WHERE TestValue= 'B001'
DELETE FROM dbo.Test  
SELECT * FROM Test_History

exec [dbo].[ManageHistoryTriggers] @TableName='Test', @SchemaName='dbo', @RemoveHistory=1

TODO
DROP TRIGGER [historyTrg_U_ElectrodeRemelts] --ON dbo.ElectrodeRemelts
DROP TRIGGER  [historyTrg_D_ElectrodeRemelts] --ON dbo.ElectrodeRemelts
exec sp_rename 'ElectrodeRemelts_History' , 'ElectrodeRemelts_History_20150920_1'   

*/

CREATE PROCEDURE [dbo].[ManageHistoryTriggers]
@TableName VARCHAR(200),
@SchemaName VARCHAR(200) = 'dbo',
@PrintOnly BIT=0,
@CreateTriggers BIT = 1, 
@CreatePrimaryKey BIT = 0,
@UseDateTime2 BIT = 1,
@RemoveHistory BIT = 0
AS 

DECLARE 
	@HistorySchemaTableName sysname, @SchemaTableName sysname,
	@HistorySequenceName sysname, @HistoryTableName sysname, @HistoryTableIdentityName sysname, @TriggerPrefix sysname, @HistoryTableSystemColumnPrefix sysname,
	@InsertTriggerName sysname, @UpdateTriggerName sysname, @DeleteTriggerName sysname
DECLARE
	 @Comment VARCHAR(MAX), @TableSql VARCHAR(MAX)='', @AiTriggerSql VARCHAR(MAX), @AuTriggerSql VARCHAR(MAX), @AdTriggerSql VARCHAR(MAX)
DECLARE
	@TAB CHAR(1)= CHAR(9), @EOL VARCHAR(2)= CHAR(13) + CHAR(10)
DECLARE 
	@BOL VARCHAR(8)= 'GO'+@EOL+@EOL

SET @SchemaTableName ='['+@SchemaName+'].['+@TableName+']'
SET @HistoryTableName         =@TableName+'_History' 
SET @HistorySchemaTableName   ='['+@SchemaName+'].['+@HistoryTableName+']'
SET @HistoryTableIdentityName ='HistoryId' --@TableName+'_HistoryId'
SET @HistorySequenceName      =@TableName+'_HistorySeq'
SET @TriggerPrefix            ='TRG_HISTORY'
SET @HistoryTableSystemColumnPrefix = 'History'
SET @Comment = '-- Auto generated using ' + OBJECT_NAME(@@PROCID)+ ' by ' + SUSER_SNAME() + ' at '+ CONVERT(VARCHAR(32), GETDATE(), 22)

SET @InsertTriggerName = @TriggerPrefix+'_AI_' + @TableName
SET @UpdateTriggerName = @TriggerPrefix+'_AU_' + @TableName
SET @DeleteTriggerName = @TriggerPrefix+'_AD_' + @TableName

IF @RemoveHistory=1
BEGIN
	IF  EXISTS (SELECT * FROM sys.triggers WHERE object_id = OBJECT_ID(N'['+@SchemaName+'].[' + @InsertTriggerName + ']'))
		EXEC('DROP TRIGGER ['+@SchemaName+'].[' + @InsertTriggerName + ']')
	IF  EXISTS (SELECT * FROM sys.triggers WHERE object_id = OBJECT_ID(N'['+@SchemaName+'].[' + @UpdateTriggerName + ']'))
		EXEC('DROP TRIGGER ['+@SchemaName+'].[' + @UpdateTriggerName + ']')
	IF  EXISTS (SELECT * FROM sys.triggers WHERE object_id = OBJECT_ID(N'['+@SchemaName+'].[' + @DeleteTriggerName + ']'))
		EXEC('DROP TRIGGER ['+@SchemaName+'].[' + @DeleteTriggerName + ']')
	IF EXISTS(SELECT * FROM sys.tables WHERE  object_id = OBJECT_ID(N'['+@SchemaName+'].[' + @HistoryTableName + ']'))
	BEGIN
        DECLARE @NewHistoryTableName sysname = @HistoryTableName+'Till'+FORMAT(getdate(), N'yyyymmddThhMM') -- strictly without schema because of sp_rename specific
		exec sp_rename @HistorySchemaTableName , @NewHistoryTableName
	END
END 
ELSE
BEGIN
	DECLARE @ColumnName sysname, 
		    @ColumnTypeName sysname,
			@ColumnMaxLength int, 
	        @ColumnPrecision int,
			@ColumnScale int,
		    @ColumnIsNullable bit
	
	DECLARE @ColumnsList VARCHAR(MAX)
	DECLARE CurHistoryTable CURSOR
	FOR
	SELECT
		  c.name AS ColumnName
		, t.name AS ColumnTypeName
		, c.max_length AS ColumnMaxLength
		, c.[precision] AS ColumnPrecision
		, c.scale AS ColumnScale
		, c.is_nullable ColumnIsNallable
	FROM
	Sys.Objects o
	INNER JOIN Sys.Columns c ON c.[object_id] = o.[object_id] AND o.[type] = 'u'
	-- http://stackoverflow.com/questions/8550427/how-do-i-get-column-type-from-table
	-- duplicate column names for Nvarchar fields
	-- INNER JOIN Sys.Types ST ON SC.system_type_id = ST.system_type_id
	INNER JOIN Sys.Types t ON c.user_type_id = t.user_type_id
	WHERE
	    o.name = @TableName
	ORDER BY c.column_Id ASC
	
	OPEN CurHistoryTable
	FETCH NEXT FROM CurHistoryTable INTO @ColumnName, @ColumnTypeName, @ColumnMaxLength, @ColumnPrecision, @ColumnScale, @ColumnIsNullable
	WHILE @@FETCH_STATUS = 0 
	BEGIN
		IF @ColumnsList IS NULL 
			SET @ColumnsList = '[' + @ColumnName + ']'
		ELSE
			SET @ColumnsList = @ColumnsList + ', [' + @ColumnName + ']'
	
		IF LEN(@TableSql) = 0 
		BEGIN
			SET @TableSql = @Comment + @EOL + 'CREATE TABLE ['+@SchemaName+'].[' + @HistoryTableName + '] (' + @EOL
			IF @CreatePrimaryKey=1
			BEGIN
				SET @TableSql = @TableSql + @TAB + '['+@HistoryTableIdentityName + '] [BIGINT]  DEFAULT NEXT VALUE FOR ['+@SchemaName+'].[' + @HistorySequenceName + '] NOT NULL,' + @EOL
			END
			IF @UseDateTime2=1
				SET @TableSql = @TableSql + @TAB + '['+@HistoryTableSystemColumnPrefix+'RecordedAt]' + @TAB + 'DATETIME2 NOT NULL DEFAULT (SYSDATETIME()),' + @EOL
			ELSE
				SET @TableSql = @TableSql + @TAB + '['+@HistoryTableSystemColumnPrefix+'RecordedAt]' + @TAB + 'DATETIME NOT NULL DEFAULT (GETDATE()),' + @EOL
			SET @TableSql = @TableSql + @TAB + '['+@HistoryTableSystemColumnPrefix+'SysUser]' + @TAB + '[varchar](128) NOT NULL DEFAULT (SUSER_SNAME()),' + @EOL
			SET @TableSql = @TableSql + @TAB + '['+@HistoryTableSystemColumnPrefix+'Application]' + @TAB + '[varchar](128) NULL DEFAULT (APP_NAME()),' + @EOL
			SET @TableSql = @TableSql + @TAB + '['+@HistoryTableSystemColumnPrefix+'Operation]' + @TAB + 'CHAR (1) NOT NULL,' + @EOL
		END
	
		IF UPPER(@ColumnTypeName) IN ( 'TIMESTAMP' ) 
		BEGIN
		    IF @ColumnIsNullable=1
				SET @TableSql = @TableSql + @TAB + '[' + @ColumnName + '] ' + 'varbinary(8)'
			ELSE
				SET @TableSql = @TableSql + @TAB + '[' + @ColumnName + '] ' + 'binary(8)' 
		END
			ELSE
				SET @TableSql = @TableSql + @TAB + '[' + @ColumnName + '] ' + '[' + @ColumnTypeName + ']'
		
		IF UPPER(@ColumnTypeName) IN ( 'CHAR', 'VARCHAR', 'NCHAR', 'NVARCHAR', 'BINARY', 'VARBINARY' ) 
		BEGIN
			IF @ColumnMaxLength = -1 
				SET @TableSql = @TableSql + '(MAX)'
			ELSE
				SET @TableSql = @TableSql + '(' + CAST(@ColumnMaxLength as sysname) + ')'
		END
		ELSE IF UPPER(@ColumnTypeName) IN ( 'DECIMAL', 'NUMERIC' ) 
		BEGIN
			SET @TableSql = @TableSql + '(' + CAST(@ColumnPrecision as sysname) + ', ' + CAST(@ColumnScale as sysname) + ')'
		END
	
		SET @TableSql = @TableSql + ' NULL' -- I have no ideas why history rows could be set up not nullable
		SET @TableSql = @TableSql + ',' + @EOL
	
		FETCH NEXT FROM CurHistoryTable INTO @ColumnName, @ColumnTypeName, @ColumnMaxLength, @ColumnPrecision, @ColumnScale, @ColumnIsNullable
	END
	
	CLOSE CurHistoryTable
	DEALLOCATE CurHistoryTable
	
	-- finish history table script and code for Primary key
	SET @TableSql = @TableSql + ' )' + @EOL 
	IF @CreatePrimaryKey=1
	BEGIN
		SET @TableSql = @TableSql + 'ALTER TABLE ['+@SchemaName+'].[' + @HistoryTableName + ']' + @EOL
		SET @TableSql = @TableSql + @TAB + 'ADD CONSTRAINT [PK_'+@SchemaName+'.'+@HistoryTableName + '] PRIMARY KEY CLUSTERED ([' + @HistoryTableIdentityName + '] ASC)' + @EOL
		SET @TableSql = @TableSql + @TAB
			+ 'WITH (ALLOW_PAGE_LOCKS = ON, ALLOW_ROW_LOCKS = ON, PAD_INDEX = OFF, IGNORE_DUP_KEY = OFF, STATISTICS_NORECOMPUTE = OFF) ON [PRIMARY];' + @EOL
			+ @EOL
	END
	ELSE
	BEGIN
		SET @TableSql = @TableSql + 'CREATE CLUSTERED INDEX [IDX_'+@SchemaName+'.'+@HistoryTableName+'] ON '+@SchemaName+'.'+@HistoryTableName+'(['+@HistoryTableSystemColumnPrefix+'RecordedAt])' + @EOL
	END
	
	
	DECLARE @SequenceSql nvarchar(max)
	SET @SequenceSql  = @Comment+ @EOL +'IF NOT EXISTS(SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N''['+@SchemaName+'].[' + @HistorySequenceName + ']'') AND type = ''SO'')'+ @EOL
	SET @SequenceSql += 'CREATE SEQUENCE ['+@SchemaName+'].[' + @HistorySequenceName + '] AS [bigint] START WITH 1'+@EOL


	IF @CreateTriggers = 1 
	BEGIN
		-- create history insert trigger 
		SET @AiTriggerSql = @Comment + @EOL
		
		SET @AiTriggerSql = @AiTriggerSql + 'CREATE TRIGGER ['+@SchemaName+'].['+@InsertTriggerName + '] ON ['+@SchemaName+'].[' + @TableName + '] AFTER INSERT' + @EOL
		
		SET @AiTriggerSql = @AiTriggerSql + 'AS' + @EOL 
		SET @AiTriggerSql = @AiTriggerSql + 'SET NOCOUNT ON;' + @EOL
		SET @AiTriggerSql = @AiTriggerSql + 'INSERT [dbo].[' + @HistoryTableName + ']' + @EOL
		
		SET @AiTriggerSql = @AiTriggerSql + @TAB + '('+@HistoryTableSystemColumnPrefix+'Operation, ' + @ColumnsList + ')'+ @EOL
		SET @AiTriggerSql = @AiTriggerSql + 'SELECT ''I''' + ', i.*' + @EOL
		SET @AiTriggerSql = @AiTriggerSql + 'FROM inserted AS i' + @EOL
		
		-- create history update trigger
		SET @AuTriggerSql = @Comment + @EOL
		SET @AuTriggerSql = @AuTriggerSql + 'CREATE TRIGGER ['+@SchemaName+'].[' + @UpdateTriggerName + '] ON ['+@SchemaName+'].[' + @TableName + '] AFTER UPDATE' + @EOL
		SET @AuTriggerSql = @AuTriggerSql + 'AS' + @EOL 
		SET @AuTriggerSql = @AuTriggerSql + 'SET NOCOUNT ON;' + @EOL
		SET @AuTriggerSql = @AuTriggerSql + 'INSERT [dbo].[' + @HistoryTableName + ']' + @EOL
		SET @AuTriggerSql = @AuTriggerSql + @TAB + '('+@HistoryTableSystemColumnPrefix+'Operation, ' + @ColumnsList + ')'+ @EOL
		SET @AuTriggerSql = @AuTriggerSql + 'SELECT ''U'''  + ', i.*' + @EOL
		SET @AuTriggerSql = @AuTriggerSql + 'FROM inserted AS i' + @EOL
	
		-- create history delete trigger
		SET @AdTriggerSql = @Comment + @EOL
		SET @AdTriggerSql = @AdTriggerSql + 'CREATE TRIGGER ['+@SchemaName+'].['+ @DeleteTriggerName + '] ON ['+@SchemaName+'].[' + @TableName + '] AFTER DELETE' + @EOL
		SET @AdTriggerSql = @AdTriggerSql + 'AS' + @EOL 
		SET @AdTriggerSql = @AdTriggerSql + 'SET NOCOUNT ON;' + @EOL
		SET @AdTriggerSql = @AdTriggerSql + 'INSERT ['+@SchemaName+'].[' + @HistoryTableName + ']' + @EOL
		SET @AdTriggerSql = @AdTriggerSql + @TAB + '('+@HistoryTableSystemColumnPrefix+'Operation, ' + @ColumnsList + ')'+ @EOL
		SET @AdTriggerSql = @AdTriggerSql + 'SELECT ''D''' +  ', d.*' + @EOL
		SET @AdTriggerSql = @AdTriggerSql + 'FROM deleted AS d' + @EOL
	END
	
	--BEGIN TRY
	    IF @CreatePrimaryKey=1
		BEGIN
			IF @PrintOnly=1
				PRINT @SequenceSql+@BOL
			ELSE
				EXEC(@SequenceSql)
		END
	
		IF @PrintOnly=1
			PRINT @TableSql+@BOL
		ELSE
			EXEC(@TableSql)
		
		IF @CreateTriggers = 1
		BEGIN
		   
		    IF @PrintOnly=1
				PRINT @AiTriggerSql+@BOL
			ELSE
				EXEC(@AiTriggerSql)
	
			IF @PrintOnly=1
				PRINT @AuTriggerSql+@BOL
			ELSE
				EXEC(@AuTriggerSql)
			
			IF @PrintOnly=1
				PRINT @AdTriggerSql+@BOL
			ELSE
				EXEC(@AdTriggerSql)
		END
--END TRY
--BEGIN CATCH
--	;THROW 50000,'Error creating history table',1
--END CATCH
END


