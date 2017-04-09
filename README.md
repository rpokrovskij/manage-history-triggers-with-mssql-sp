# manage-history-triggers-with-mssql-sp
Stored procedure that add and remove history triggers to the source table and add/remove/rename History table.

Can be configured to use sequences for history table id (less locks during massive CRUD operations).
Can be configured with type of operation date: datetime or datetime2.
Can be configured to do not use id in history table at all (note: then become possible situations when it is impossible to unambiguously order history records).

Have History archivу features. If you change source table, and the history table should be recreated, this SP will renamethe history table (archive it) adding time suffix to the end of table's name.
