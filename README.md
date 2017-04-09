# manage-history-triggers-with-mssql-sp
Stored procedure that add and remove history triggers to the source table and add/remove/rename History table.

Can be configured to use **sequences** for history table id (less locks during massive CRUD operations).

Can be configured with type of operation date: `datetime` or `datetime2`.

Can be configured to do not use id for history table at all (note: there are possible situations when it is impossible to unambiguously order history records just on change date because two changes can have the same date and time).

Have history table archiving features. If you are changing source table, and the history table should be recreated, this SP will rename the history table (archive it) adding time suffix to the end of table's name, then become possible to create new changes history table.
