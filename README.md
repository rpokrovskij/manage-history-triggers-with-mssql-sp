# manage-history-triggers-with-mssql-sp
Stored procedure that add and remove history triggers to the source table and add/remove/rename History table.

## What is unique:

Can be configured to use **sequences** for history table id (less locks during massive CRUD operations).

Have history table archiving features. Supports this use case: when you are changing source table, the new history table should be created, in this case SP will rename the history table adding time suffix to the end to the current history table's name, then become possible to create new changes history table.

This can be used to automatize table design updates:

Before update:

Users - entities table
Users_History - history audit table

After update:

Users - changed new history table (e.g. some columns removed, moved to Addresses table)
Users_History - new hisory table
Users_History_Till01012018 - old history table


## Other functionlity:

Event's date type can be configured: `datetime` or `datetime2`.

Can be configured to do not create ID columns for history table at all (id is not always required, when inserting to table without id create less locks - bring more performance). Note, in this case do not relly on change date to maintain order of changes: two changes can have the same date and time even if they was commited in one transaction.
