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
/* Test

CREATE TABLE [dbo].[ManageHistoryTriggersTestTable](
	[TestId] [int] IDENTITY(1000,1) NOT NULL,
	[TestValue] [nvarchar](100) NOT NULL,
	[TestRowVersion] [timestamp] NOT NULL,
        PRIMARY KEY CLUSTERED ([TestId] ASC)
)
GO
exec [dbo].[ManageHistoryTriggers] 'ManageHistoryTriggersTestTable', 'dbo', @PrintOnly=0, @CreateTriggers=1, @CreatePrimaryKey=1, @UseDateTime2=0

INSERT INTO dbo.ManageHistoryTriggersTestTable (TestValue) VALUES('A001')
INSERT INTO dbo.ManageHistoryTriggersTestTable (TestValue) VALUES('A002'),('A003')
UPDATE dbo.ManageHistoryTriggersTestTable  SET TestValue = 'B001' WHERE TestValue= 'A001'
UPDATE dbo.ManageHistoryTriggersTestTable  SET TestValue = 'C001' WHERE TestValue= 'B001'
DELETE FROM dbo.ManageHistoryTriggersTestTable  
SELECT * FROM dbo.ManageHistoryTriggersTestTable_History

exec [dbo].[ManageHistoryTriggers] @TableName='ManageHistoryTriggersTestTable', @SchemaName='dbo', @RemoveHistory=1, @ArchiveRemovedData=1
exec [dbo].[ManageHistoryTriggers] 'ManageHistoryTriggersTestTable', 'dbo', @PrintOnly=0, @CreateTriggers=1, @CreatePrimaryKey=1, @UseDateTime2=0
exec [dbo].[ManageHistoryTriggers] @TableName='ManageHistoryTriggersTestTable', @SchemaName='dbo',  @PrintOnly=0, @RemoveHistory=1, @ArchiveRemovedData=0

DROP TABLE ManageHistoryTriggersTestTable
*/

CREATE PROCEDURE [dbo].[ManageHistoryTriggers]
	@TableName VARCHAR(200),
	@SchemaName VARCHAR(200) = 'dbo',
	@PrintOnly BIT=0,
	@CreateTriggers BIT = 1, 
	@CreatePrimaryKey BIT = 1,
	@UseDateTime2 BIT = 0,
	@RemoveHistory BIT = 0,
	@ArchiveRemovedData BIT = 1
AS 

DECLARE 
	@HistorySchemaTableName sysname, @SchemaTableName sysname,
	@HistorySequenceName sysname, @HistoryTableName sysname, @HistoryTableIdentityName sysname, @TriggerPrefix sysname, @HistoryTableSystemColumnPrefix sysname,
	@InsertTriggerName sysname, @UpdateTriggerName sysname, @DeleteTriggerName sysname, @ConstraintDefaultName sysname, @PrimaryKeyDefaultName sysname
DECLARE
	 @Comment VARCHAR(MAX), @TableSql VARCHAR(MAX)='', @AiTriggerSql VARCHAR(MAX), @AuTriggerSql VARCHAR(MAX), @AdTriggerSql VARCHAR(MAX)
DECLARE
	@TAB CHAR(1)= CHAR(9), @EOL VARCHAR(2)= CHAR(13) + CHAR(10)
DECLARE 
	@BOL VARCHAR(8)= 'GO'+@EOL+@EOL

SET @SchemaTableName ='['+@SchemaName+'].['+@TableName+']'
SET @HistoryTableName         =@TableName+'_History' 
SET @HistorySchemaTableName   ='['+@SchemaName+'].['+@HistoryTableName+']'
SET @HistoryTableIdentityName ='HistoryId'
SET @HistorySequenceName      =@TableName+'_HistorySeq'
SET @TriggerPrefix            ='TRG_HISTORY'
SET @HistoryTableSystemColumnPrefix = 'History'
SET @Comment = '-- Auto generated using ' + OBJECT_NAME(@@PROCID)+ ' by ' + SUSER_SNAME() + ' at '+ CONVERT(VARCHAR(32), GETDATE(), 22)

SET @InsertTriggerName = @TriggerPrefix+'_AI_' + @TableName
SET @UpdateTriggerName = @TriggerPrefix+'_AU_' + @TableName
SET @DeleteTriggerName = @TriggerPrefix+'_AD_' + @TableName

SET @ConstraintDefaultName = '[DF_'+@SchemaName+'.'+@HistorySequenceName+']'
SET @PrimaryKeyDefaultName = '[PK_'+@SchemaName+'.'+@HistoryTableName+']'

IF OBJECT_ID(@SchemaTableName, 'U') IS NULL 
BEGIN
	DECLARE @ErrMessage NVARCHAR(MAX) = N'The table ' + @SchemaTableName+' doesn''t exist '
	RAISERROR (@ErrMessage, 10, 1, @SchemaTableName) WITH SETERROR;
	RETURN; 
END

IF @RemoveHistory=1
BEGIN
	DECLARE @RemoveInsertTriggerSql VARCHAR(MAX), @RemoveDeleteTriggerSql VARCHAR(MAX), @RemoveUpdateTriggerSql VARCHAR(MAX)
	DECLARE @RemovePrimaryKey VARCHAR(MAX), @RemoveConstraint VARCHAR(MAX), @RenameTable VARCHAR(MAX), @RemoveTables VARCHAR(MAX)
	IF  EXISTS (SELECT * FROM sys.triggers WHERE object_id = OBJECT_ID(N'['+@SchemaName+'].[' + @InsertTriggerName + ']'))
		SET @RemoveInsertTriggerSql='DROP TRIGGER ['+@SchemaName+'].[' + @InsertTriggerName + ']'+@EOL
	IF  EXISTS (SELECT * FROM sys.triggers WHERE object_id = OBJECT_ID(N'['+@SchemaName+'].[' + @UpdateTriggerName + ']'))
		SET @RemoveUpdateTriggerSql='DROP TRIGGER ['+@SchemaName+'].[' + @UpdateTriggerName + ']'+@EOL
	IF  EXISTS (SELECT * FROM sys.triggers WHERE object_id = OBJECT_ID(N'['+@SchemaName+'].[' + @DeleteTriggerName + ']'))
		SET @RemoveDeleteTriggerSql='DROP TRIGGER ['+@SchemaName+'].[' + @DeleteTriggerName + ']'+@EOL
	
	DECLARE @IsHistoryTableExists BIT=0
	IF EXISTS(SELECT * FROM sys.tables WHERE  object_id = OBJECT_ID(N'['+@SchemaName+'].[' + @HistoryTableName + ']'))
		SET @IsHistoryTableExists= 1

	IF  @ArchiveRemovedData=0
	BEGIN
		SET @RemoveTables = 'EXEC sp_MSforeachtable '''+ 'IF PARSENAME("?",2)='''''+@SchemaName+''''' AND PARSENAME("?",1) like '''''+@HistoryTableName+'%'''' DROP TABLE ?' +''''+@EOL
	END
	ELSE
	BEGIN
		IF @IsHistoryTableExists=1
		BEGIN
			IF EXISTS (SELECT * FROM sys.objects WHERE  [object_id]= OBJECT_ID(@ConstraintDefaultName) AND [type]='D')
				SET @RemoveConstraint = 'ALTER TABLE ' + @HistorySchemaTableName + 'DROP CONSTRAINT ' + @ConstraintDefaultName+@EOL

			IF EXISTS (SELECT * FROM sys.objects WHERE  [object_id]= OBJECT_ID(@PrimaryKeyDefaultName) AND [type]='PK')
				SET @RemovePrimaryKey = 'ALTER TABLE ' + @HistorySchemaTableName + 'DROP CONSTRAINT ' + @PrimaryKeyDefaultName+@EOL
			
			DECLARE @NewHistoryTableName sysname = @HistoryTableName+'Till'+FORMAT(getdate(), N'yyyymmddThhMM') -- strictly without schema because of sp_rename specific
			SET @RenameTable = 'EXEC sp_rename '''+@HistorySchemaTableName+''' , '''+@NewHistoryTableName+''''+@EOL
		END
	END

	IF (@PrintOnly=1)
	BEGIN
		PRINT @RemoveInsertTriggerSql+@BOL
		PRINT @RemoveUpdateTriggerSql+@BOL
		PRINT @RemoveDeleteTriggerSql+@BOL
		IF (@ArchiveRemovedData=1)
		BEGIN
			IF(@IsHistoryTableExists=1)
			BEGIN
				PRINT @RemoveConstraint+@BOL
				PRINT @RemovePrimaryKey+@BOL
				PRINT @RenameTable+@BOL
			END
		END
		ELSE
		BEGIN
			PRINT @RemoveTables+@BOL
		END
	END
	ELSE
	BEGIN
		EXEC(@RemoveInsertTriggerSql)
		EXEC(@RemoveUpdateTriggerSql)
		EXEC(@RemoveDeleteTriggerSql)
		IF (@ArchiveRemovedData=1)
		BEGIN
			IF(@IsHistoryTableExists=1)
			BEGIN
				EXEC(@RemoveConstraint)
				EXEC(@RemovePrimaryKey)
				EXEC(@RenameTable)
			END
		END
		ELSE
		BEGIN
			EXEC(@RemoveTables)
		END
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
				SET @TableSql = @TableSql + @TAB + '['+@HistoryTableIdentityName + '] [BIGINT] CONSTRAINT ' + @ConstraintDefaultName + ' DEFAULT NEXT VALUE FOR ['+@SchemaName+'].[' + @HistorySequenceName + '] NOT NULL,' + @EOL
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
	
		SET @TableSql = @TableSql + ' NULL' 
		SET @TableSql = @TableSql + ',' + @EOL
	
		FETCH NEXT FROM CurHistoryTable INTO @ColumnName, @ColumnTypeName, @ColumnMaxLength, @ColumnPrecision, @ColumnScale, @ColumnIsNullable
	END
	
	CLOSE CurHistoryTable
	DEALLOCATE CurHistoryTable
	
	-- finish history table script with code for Primary key
	SET @TableSql = @TableSql + ' )' + @EOL 
	IF @CreatePrimaryKey=1
	BEGIN
		SET @TableSql = @TableSql + 'ALTER TABLE ['+@SchemaName+'].[' + @HistoryTableName + ']' + @EOL
		SET @TableSql = @TableSql + @TAB + 'ADD CONSTRAINT ' + @PrimaryKeyDefaultName + ' PRIMARY KEY CLUSTERED ([' + @HistoryTableIdentityName + '] ASC)' + @EOL
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
		SET @AiTriggerSql = @AiTriggerSql + 'INSERT ['+@SchemaName+'].[' + @HistoryTableName + ']' + @EOL
		
		SET @AiTriggerSql = @AiTriggerSql + @TAB + '('+@HistoryTableSystemColumnPrefix+'Operation, ' + @ColumnsList + ')'+ @EOL
		SET @AiTriggerSql = @AiTriggerSql + 'SELECT ''I''' + ', i.*' + @EOL
		SET @AiTriggerSql = @AiTriggerSql + 'FROM inserted AS i' + @EOL
		
		-- create history update trigger
		SET @AuTriggerSql = @Comment + @EOL
		SET @AuTriggerSql = @AuTriggerSql + 'CREATE TRIGGER ['+@SchemaName+'].[' + @UpdateTriggerName + '] ON ['+@SchemaName+'].[' + @TableName + '] AFTER UPDATE' + @EOL
		SET @AuTriggerSql = @AuTriggerSql + 'AS' + @EOL 
		SET @AuTriggerSql = @AuTriggerSql + 'SET NOCOUNT ON;' + @EOL
		SET @AuTriggerSql = @AuTriggerSql + 'INSERT ['+@SchemaName+'].[' + @HistoryTableName + ']' + @EOL
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
