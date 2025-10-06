# Database Schema Drift Detection - Test Setup Instructions

## Overview
This setup creates two test databases with intentional schema differences to demonstrate the drift detection capabilities:

- **TestSourceDB**: The baseline/reference database
- **TestTargetDB**: A modified version with schema changes to detect drift

## Setup Steps

### 1. Create Source Database
Execute the following script in SQL Server Management Studio or Azure Data Studio:
```sql
-- Run this first - the script includes proper IF EXISTS logic and GO batch separators
-- You can run this multiple times safely
01_CreateSourceDatabase.sql
```

### 2. Create Target Database
Execute the following script:
```sql
-- Run this second - also includes proper IF EXISTS logic and GO batch separators
-- You can run this multiple times safely
02_CreateTargetDatabase.sql
```

### 3. Run Drift Detection
Execute the PowerShell script to compare the databases:
```powershell
.\DatabaseSchemaDriftDetection.ps1 -SourceServer "localhost" -SourceDatabase "TestSourceDB" -TargetServer "localhost" -TargetDatabase "TestTargetDB" -OutputPath ".\DriftReport.html"
```

## Intentional Schema Differences

The target database includes the following intentional changes to demonstrate drift detection:

### Schemas
- **Missing**: `Inventory` schema (exists in source, missing in target)
- **Added**: `Finance` schema (new in target)

### Data Types
- **Modified**: `EmailAddress` type length changed from 255 to 300 characters
- **Missing**: `HR.EmployeeID` custom type (replaced with standard INT)
- **Added**: `ZipCode` custom type (new in target)

### Tables
- **Missing**: `Inventory.Products` table
- **Added**: `Sales.Products` table (different structure and schema)
- **Added**: `Finance.Invoices` table (completely new)
- **Modified**: All existing tables have additional columns

### Columns Added to Existing Tables
- `HR.Employees`: Added `EmployeeCode` column
- `Sales.Customers`: Added `CustomerType` and `CreditLimit` columns
- `Sales.Orders`: Added `OrderPriority` and `Discount` columns
- `Sales.OrderDetails`: Added `LineTotal` computed column

### Indexes
- **Missing**: Several indexes from source database
- **Added**: New indexes for new columns
- **Modified**: Different indexing strategy for Products table

### Constraints
- **Modified**: Email validation constraint has different pattern
- **Modified**: UnitPrice constraint allows zero values (was > 0, now >= 0)
- **Added**: New constraints for Invoice table

### Stored Procedures
- **Missing**: `Inventory.GetLowStockProducts` procedure
- **Added**: `Sales.GetProductsByCategory` procedure (different functionality)
- **Added**: `Finance.GetOutstandingInvoices` procedure (new)
- **Modified**: Existing procedures have additional parameters and logic

### Functions
- **Modified**: `GetFullName` function includes TRIM operations
- **Modified**: `CalculateOrderTotal` function includes order-level discount calculation
- **Added**: `Finance.CalculateOutstanding` function (new)

### Views
- **Modified**: `EmployeeSummary` view includes new columns and experience level calculation
- **Modified**: `CustomerOrderSummary` view includes customer type and average order value
- **Added**: `Finance.InvoiceSummary` view (completely new)

### Users and Permissions
- **Added**: Additional user `FinanceUser`
- **Added**: Additional role `Finance_ReadOnly`
- **Modified**: Different permission assignments

## Expected Drift Detection Results

When you run the drift detection tool, you should see:

1. **Tables Section**: Shows missing Inventory.Products, new Finance.Invoices, and modified table structures
2. **Columns Section**: Shows all the new columns added to existing tables
3. **Indexes Section**: Shows missing and new indexes
4. **Constraints Section**: Shows modified and new constraints
5. **Functions Section**: Shows modified functions and new Finance functions
6. **Stored Procedures Section**: Shows missing, new, and modified procedures
7. **Views Section**: Shows modified and new views
8. **Data Types Section**: Shows missing HR.EmployeeID type and new ZipCode type
9. **Users Section**: Shows the new FinanceUser
10. **Permissions Section**: Shows new permissions and role assignments

## Sample Data

Both databases include sample data to demonstrate:
- Different data volumes (target has more records)
- Different data values (some customers have different types)
- New data relationships (invoices linked to orders)

## Cleanup

To remove the test databases after testing:
```sql
-- Clean up test databases
DROP DATABASE TestSourceDB;
DROP DATABASE TestTargetDB;
```
