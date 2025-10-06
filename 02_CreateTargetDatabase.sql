-- =============================================
-- Create Target Database for Drift Detection Test
-- This represents a "modified" version with intentional differences
-- =============================================

-- Drop database if it exists
IF EXISTS (SELECT name FROM sys.databases WHERE name = 'TestTargetDB')
BEGIN
    ALTER DATABASE TestTargetDB SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE TestTargetDB;
END
GO

-- Create the target database
CREATE DATABASE TestTargetDB;
GO

USE TestTargetDB;
GO

-- Create schemas (Note: Missing 'Inventory' schema - intentional drift)
IF NOT EXISTS (SELECT * FROM sys.schemas WHERE name = 'HR')
    EXEC('CREATE SCHEMA HR');
GO

IF NOT EXISTS (SELECT * FROM sys.schemas WHERE name = 'Sales')
    EXEC('CREATE SCHEMA Sales');
GO

-- Missing: CREATE SCHEMA Inventory; -- Intentional drift
-- CREATE SCHEMA Inventory;

IF NOT EXISTS (SELECT * FROM sys.schemas WHERE name = 'Finance')
    EXEC('CREATE SCHEMA Finance'); -- New schema not in source
GO

-- Create custom data types (Note: Modified EmailAddress length - intentional drift)
IF EXISTS (SELECT * FROM sys.types WHERE name = 'EmailAddress' AND schema_id = SCHEMA_ID('dbo'))
    DROP TYPE dbo.EmailAddress;
GO

CREATE TYPE dbo.EmailAddress FROM NVARCHAR(300); -- Changed from 255 to 300
GO

IF EXISTS (SELECT * FROM sys.types WHERE name = 'PhoneNumber' AND schema_id = SCHEMA_ID('dbo'))
    DROP TYPE dbo.PhoneNumber;
GO

CREATE TYPE dbo.PhoneNumber FROM NVARCHAR(20);
GO

-- Missing: CREATE TYPE HR.EmployeeID; -- This type is missing (intentional drift)
-- IF EXISTS (SELECT * FROM sys.types WHERE name = 'EmployeeID' AND schema_id = SCHEMA_ID('HR'))
--     DROP TYPE HR.EmployeeID;
-- GO
-- CREATE TYPE HR.EmployeeID FROM INT;

IF EXISTS (SELECT * FROM sys.types WHERE name = 'ZipCode' AND schema_id = SCHEMA_ID('dbo'))
    DROP TYPE dbo.ZipCode;
GO

CREATE TYPE dbo.ZipCode FROM NVARCHAR(10); -- New type not in source
GO

-- Create tables (with some modifications)
IF EXISTS (SELECT * FROM sys.tables WHERE name = 'Employees' AND schema_id = SCHEMA_ID('HR'))
    DROP TABLE HR.Employees;
GO

CREATE TABLE HR.Employees (
    EmployeeID INT IDENTITY(1,1) PRIMARY KEY, -- Changed from HR.EmployeeID to INT
    FirstName NVARCHAR(50) NOT NULL,
    LastName NVARCHAR(50) NOT NULL,
    Email dbo.EmailAddress NOT NULL,
    Phone dbo.PhoneNumber,
    HireDate DATE NOT NULL,
    Salary DECIMAL(10,2),
    DepartmentID INT,
    IsActive BIT DEFAULT 1,
    CreatedDate DATETIME2 DEFAULT GETDATE(),
    ModifiedDate DATETIME2 DEFAULT GETDATE(),
    EmployeeCode NVARCHAR(10) -- New column not in source
);
GO

IF EXISTS (SELECT * FROM sys.tables WHERE name = 'Customers' AND schema_id = SCHEMA_ID('Sales'))
    DROP TABLE Sales.Customers;
GO

CREATE TABLE Sales.Customers (
    CustomerID INT IDENTITY(1,1) PRIMARY KEY,
    CompanyName NVARCHAR(100) NOT NULL,
    ContactName NVARCHAR(100),
    ContactEmail dbo.EmailAddress,
    Phone dbo.PhoneNumber,
    Address NVARCHAR(255),
    City NVARCHAR(50),
    Country NVARCHAR(50),
    PostalCode NVARCHAR(20),
    CreatedDate DATETIME2 DEFAULT GETDATE(),
    IsActive BIT DEFAULT 1,
    CustomerType NVARCHAR(20) DEFAULT 'Standard', -- New column not in source
    CreditLimit DECIMAL(12,2) -- New column not in source
);
GO

IF EXISTS (SELECT * FROM sys.tables WHERE name = 'Orders' AND schema_id = SCHEMA_ID('Sales'))
    DROP TABLE Sales.Orders;
GO

CREATE TABLE Sales.Orders (
    OrderID INT IDENTITY(1,1) PRIMARY KEY,
    CustomerID INT NOT NULL,
    OrderDate DATE NOT NULL,
    RequiredDate DATE,
    ShippedDate DATE,
    Freight DECIMAL(10,2) DEFAULT 0,
    ShipName NVARCHAR(100),
    ShipAddress NVARCHAR(255),
    ShipCity NVARCHAR(50),
    ShipCountry NVARCHAR(50),
    OrderStatus NVARCHAR(20) DEFAULT 'Pending',
    OrderPriority NVARCHAR(10) DEFAULT 'Normal', -- New column not in source
    Discount DECIMAL(3,2) DEFAULT 0 -- New column not in source
);
GO

-- Missing: Inventory.Products table - intentional drift
-- Instead, create a different Products table in Sales schema
IF EXISTS (SELECT * FROM sys.tables WHERE name = 'Products' AND schema_id = SCHEMA_ID('Sales'))
    DROP TABLE Sales.Products;
GO

CREATE TABLE Sales.Products ( -- Different schema and structure
    ProductID INT IDENTITY(1,1) PRIMARY KEY,
    ProductName NVARCHAR(100) NOT NULL,
    CategoryID INT,
    UnitPrice DECIMAL(10,2) NOT NULL,
    UnitsInStock INT DEFAULT 0,
    UnitsOnOrder INT DEFAULT 0,
    ReorderLevel INT DEFAULT 0,
    Discontinued BIT DEFAULT 0,
    CreatedDate DATETIME2 DEFAULT GETDATE(),
    ProductCode NVARCHAR(20), -- Additional column
    SupplierID INT -- Additional column
);
GO

-- Modified: Different structure for OrderDetails
IF EXISTS (SELECT * FROM sys.tables WHERE name = 'OrderDetails' AND schema_id = SCHEMA_ID('Sales'))
    DROP TABLE Sales.OrderDetails;
GO

CREATE TABLE Sales.OrderDetails (
    OrderID INT NOT NULL,
    ProductID INT NOT NULL,
    UnitPrice DECIMAL(10,2) NOT NULL,
    Quantity INT NOT NULL DEFAULT 1,
    Discount DECIMAL(3,2) DEFAULT 0,
    LineTotal AS (UnitPrice * Quantity * (1 - Discount)), -- Computed column not in source
    PRIMARY KEY (OrderID, ProductID)
);
GO

-- New table not in source
IF EXISTS (SELECT * FROM sys.tables WHERE name = 'Invoices' AND schema_id = SCHEMA_ID('Finance'))
    DROP TABLE Finance.Invoices;
GO

CREATE TABLE Finance.Invoices (
    InvoiceID INT IDENTITY(1,1) PRIMARY KEY,
    OrderID INT NOT NULL,
    InvoiceNumber NVARCHAR(50) NOT NULL,
    InvoiceDate DATE NOT NULL,
    DueDate DATE NOT NULL,
    TotalAmount DECIMAL(12,2) NOT NULL,
    PaidAmount DECIMAL(12,2) DEFAULT 0,
    Status NVARCHAR(20) DEFAULT 'Open'
);
GO
GO

-- Create indexes (some different from source)
CREATE INDEX IX_Employees_DepartmentID ON HR.Employees(DepartmentID);
CREATE INDEX IX_Employees_Email ON HR.Employees(Email);
-- Missing: IX_Employees_HireDate index
CREATE INDEX IX_Employees_EmployeeCode ON HR.Employees(EmployeeCode); -- New index

CREATE INDEX IX_Customers_CompanyName ON Sales.Customers(CompanyName);
CREATE INDEX IX_Customers_Country ON Sales.Customers(Country);
-- Missing: IX_Customers_City index
CREATE INDEX IX_Customers_CustomerType ON Sales.Customers(CustomerType); -- New index

CREATE INDEX IX_Orders_CustomerID ON Sales.Orders(CustomerID);
CREATE INDEX IX_Orders_OrderDate ON Sales.Orders(OrderDate);
-- Missing: IX_Orders_ShippedDate index
CREATE INDEX IX_Orders_OrderPriority ON Sales.Orders(OrderPriority); -- New index

-- Different indexes for Products (since it's in different schema)
CREATE INDEX IX_Products_CategoryID ON Sales.Products(CategoryID);
CREATE INDEX IX_Products_ProductName ON Sales.Products(ProductName);
CREATE INDEX IX_Products_SupplierID ON Sales.Products(SupplierID); -- New index

-- New indexes for Invoices
CREATE INDEX IX_Invoices_OrderID ON Finance.Invoices(OrderID);
CREATE INDEX IX_Invoices_InvoiceDate ON Finance.Invoices(InvoiceDate);
GO

-- Create foreign key constraints (some modified)
ALTER TABLE Sales.Orders
ADD CONSTRAINT FK_Orders_Customers 
FOREIGN KEY (CustomerID) REFERENCES Sales.Customers(CustomerID);

ALTER TABLE Sales.OrderDetails
ADD CONSTRAINT FK_OrderDetails_Orders 
FOREIGN KEY (OrderID) REFERENCES Sales.Orders(OrderID);

ALTER TABLE Sales.OrderDetails
ADD CONSTRAINT FK_OrderDetails_Products 
FOREIGN KEY (ProductID) REFERENCES Sales.Products(ProductID);

-- New foreign key constraint
ALTER TABLE Finance.Invoices
ADD CONSTRAINT FK_Invoices_Orders 
FOREIGN KEY (OrderID) REFERENCES Sales.Orders(OrderID);
GO

-- Create check constraints (some modified)
ALTER TABLE HR.Employees
ADD CONSTRAINT CK_Employees_Salary CHECK (Salary > 0);

-- Modified email constraint (different pattern)
ALTER TABLE HR.Employees
ADD CONSTRAINT CK_Employees_Email CHECK (Email LIKE '%@%.%' AND LEN(Email) > 5);

ALTER TABLE Sales.Orders
ADD CONSTRAINT CK_Orders_Freight CHECK (Freight >= 0);

-- Modified constraint for Products
ALTER TABLE Sales.Products
ADD CONSTRAINT CK_Products_UnitPrice CHECK (UnitPrice >= 0); -- Changed from > 0 to >= 0

ALTER TABLE Sales.Products
ADD CONSTRAINT CK_Products_UnitsInStock CHECK (UnitsInStock >= 0);

-- New constraints
ALTER TABLE Finance.Invoices
ADD CONSTRAINT CK_Invoices_TotalAmount CHECK (TotalAmount > 0);

ALTER TABLE Finance.Invoices
ADD CONSTRAINT CK_Invoices_PaidAmount CHECK (PaidAmount >= 0 AND PaidAmount <= TotalAmount);
GO

-- Create stored procedures (some modified)
IF EXISTS (SELECT * FROM sys.procedures WHERE name = 'GetEmployeeById' AND schema_id = SCHEMA_ID('HR'))
    DROP PROCEDURE HR.GetEmployeeById;
GO

CREATE PROCEDURE HR.GetEmployeeById
    @EmployeeID INT,
    @IncludeInactive BIT = 0 -- New parameter not in source
AS
BEGIN
    SET NOCOUNT ON;
    SELECT 
        EmployeeID,
        FirstName,
        LastName,
        Email,
        Phone,
        HireDate,
        Salary,
        DepartmentID,
        IsActive,
        EmployeeCode -- New column
    FROM HR.Employees
    WHERE EmployeeID = @EmployeeID
    AND (@IncludeInactive = 1 OR IsActive = 1); -- Modified logic
END
GO

-- Modified procedure with different parameters
IF EXISTS (SELECT * FROM sys.procedures WHERE name = 'GetOrdersByCustomer' AND schema_id = SCHEMA_ID('Sales'))
    DROP PROCEDURE Sales.GetOrdersByCustomer;
GO

CREATE PROCEDURE Sales.GetOrdersByCustomer
    @CustomerID INT,
    @StartDate DATE = NULL,
    @EndDate DATE = NULL,
    @OrderStatus NVARCHAR(20) = NULL -- New parameter
AS
BEGIN
    SET NOCOUNT ON;
    SELECT 
        o.OrderID,
        o.OrderDate,
        o.RequiredDate,
        o.ShippedDate,
        o.Freight,
        o.OrderStatus,
        o.OrderPriority -- New column
    FROM Sales.Orders o
    WHERE o.CustomerID = @CustomerID
    AND (@StartDate IS NULL OR o.OrderDate >= @StartDate)
    AND (@EndDate IS NULL OR o.OrderDate <= @EndDate)
    AND (@OrderStatus IS NULL OR o.OrderStatus = @OrderStatus); -- New condition
END
GO

-- Missing: Inventory.GetLowStockProducts procedure
-- Instead, create a different procedure
IF EXISTS (SELECT * FROM sys.procedures WHERE name = 'GetProductsByCategory' AND schema_id = SCHEMA_ID('Sales'))
    DROP PROCEDURE Sales.GetProductsByCategory;
GO

CREATE PROCEDURE Sales.GetProductsByCategory
    @CategoryID INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT 
        ProductID,
        ProductName,
        UnitPrice,
        UnitsInStock,
        ProductCode
    FROM Sales.Products
    WHERE CategoryID = @CategoryID
    AND Discontinued = 0;
END
GO

-- New procedure not in source
IF EXISTS (SELECT * FROM sys.procedures WHERE name = 'GetOutstandingInvoices' AND schema_id = SCHEMA_ID('Finance'))
    DROP PROCEDURE Finance.GetOutstandingInvoices;
GO

CREATE PROCEDURE Finance.GetOutstandingInvoices
    @CustomerID INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT 
        i.InvoiceID,
        i.InvoiceNumber,
        i.InvoiceDate,
        i.DueDate,
        i.TotalAmount,
        i.PaidAmount,
        (i.TotalAmount - i.PaidAmount) AS OutstandingAmount
    FROM Finance.Invoices i
    INNER JOIN Sales.Orders o ON i.OrderID = o.OrderID
    WHERE (@CustomerID IS NULL OR o.CustomerID = @CustomerID)
    AND i.Status = 'Open';
END
GO

-- Create functions (some modified)
IF EXISTS (SELECT * FROM sys.objects WHERE name = 'GetFullName' AND schema_id = SCHEMA_ID('HR') AND type = 'FN')
    DROP FUNCTION HR.GetFullName;
GO

CREATE FUNCTION HR.GetFullName(@FirstName NVARCHAR(50), @LastName NVARCHAR(50))
RETURNS NVARCHAR(101)
AS
BEGIN
    RETURN TRIM(@FirstName) + ' ' + TRIM(@LastName); -- Modified to include TRIM
END
GO

-- Modified function with different calculation
IF EXISTS (SELECT * FROM sys.objects WHERE name = 'CalculateOrderTotal' AND schema_id = SCHEMA_ID('Sales') AND type = 'FN')
    DROP FUNCTION Sales.CalculateOrderTotal;
GO

CREATE FUNCTION Sales.CalculateOrderTotal(@OrderID INT)
RETURNS DECIMAL(12,2)
AS
BEGIN
    DECLARE @Total DECIMAL(12,2) = 0;
    DECLARE @OrderDiscount DECIMAL(3,2) = 0;
    
    -- Get order-level discount
    SELECT @OrderDiscount = ISNULL(Discount, 0)
    FROM Sales.Orders
    WHERE OrderID = @OrderID;
    
    -- Calculate total with order-level discount
    SELECT @Total = SUM((UnitPrice * Quantity) * (1 - Discount))
    FROM Sales.OrderDetails
    WHERE OrderID = @OrderID;
    
    RETURN ISNULL(@Total * (1 - @OrderDiscount), 0); -- Modified calculation
END
GO

-- New function not in source
IF EXISTS (SELECT * FROM sys.objects WHERE name = 'CalculateOutstanding' AND schema_id = SCHEMA_ID('Finance') AND type = 'FN')
    DROP FUNCTION Finance.CalculateOutstanding;
GO

CREATE FUNCTION Finance.CalculateOutstanding(@InvoiceID INT)
RETURNS DECIMAL(12,2)
AS
BEGIN
    DECLARE @Outstanding DECIMAL(12,2) = 0;
    
    SELECT @Outstanding = TotalAmount - PaidAmount
    FROM Finance.Invoices
    WHERE InvoiceID = @InvoiceID;
    
    RETURN ISNULL(@Outstanding, 0);
END
GO

-- Create views (some modified)
IF EXISTS (SELECT * FROM sys.views WHERE name = 'EmployeeSummary' AND schema_id = SCHEMA_ID('HR'))
    DROP VIEW HR.EmployeeSummary;
GO

CREATE VIEW HR.EmployeeSummary AS
SELECT 
    e.EmployeeID,
    HR.GetFullName(e.FirstName, e.LastName) AS FullName,
    e.Email,
    e.HireDate,
    e.Salary,
    e.DepartmentID,
    e.IsActive,
    e.EmployeeCode, -- New column
    DATEDIFF(YEAR, e.HireDate, GETDATE()) AS YearsOfService,
    CASE 
        WHEN DATEDIFF(YEAR, e.HireDate, GETDATE()) >= 5 THEN 'Senior'
        WHEN DATEDIFF(YEAR, e.HireDate, GETDATE()) >= 2 THEN 'Intermediate'
        ELSE 'Junior'
    END AS ExperienceLevel -- New column
FROM HR.Employees e;
GO

-- Modified view with different logic
IF EXISTS (SELECT * FROM sys.views WHERE name = 'CustomerOrderSummary' AND schema_id = SCHEMA_ID('Sales'))
    DROP VIEW Sales.CustomerOrderSummary;
GO

CREATE VIEW Sales.CustomerOrderSummary AS
SELECT 
    c.CustomerID,
    c.CompanyName,
    c.ContactName,
    c.CustomerType, -- New column
    COUNT(o.OrderID) AS TotalOrders,
    SUM(Sales.CalculateOrderTotal(o.OrderID)) AS TotalSpent,
    MAX(o.OrderDate) AS LastOrderDate,
    AVG(Sales.CalculateOrderTotal(o.OrderID)) AS AverageOrderValue -- New calculation
FROM Sales.Customers c
LEFT JOIN Sales.Orders o ON c.CustomerID = o.CustomerID
GROUP BY c.CustomerID, c.CompanyName, c.ContactName, c.CustomerType; -- Modified GROUP BY
GO

-- New view not in source
IF EXISTS (SELECT * FROM sys.views WHERE name = 'InvoiceSummary' AND schema_id = SCHEMA_ID('Finance'))
    DROP VIEW Finance.InvoiceSummary;
GO

CREATE VIEW Finance.InvoiceSummary AS
SELECT 
    i.InvoiceID,
    i.InvoiceNumber,
    i.InvoiceDate,
    i.DueDate,
    i.TotalAmount,
    i.PaidAmount,
    Finance.CalculateOutstanding(i.InvoiceID) AS OutstandingAmount,
    i.Status,
    CASE 
        WHEN i.DueDate < GETDATE() AND Finance.CalculateOutstanding(i.InvoiceID) > 0 THEN 'Overdue'
        WHEN Finance.CalculateOutstanding(i.InvoiceID) = 0 THEN 'Paid'
        ELSE 'Open'
    END AS PaymentStatus
FROM Finance.Invoices i;
GO

-- Insert sample data (some different from source)
INSERT INTO HR.Employees (FirstName, LastName, Email, Phone, HireDate, Salary, DepartmentID, EmployeeCode)
VALUES 
    ('John', 'Doe', 'john.doe@company.com', '555-0101', '2020-01-15', 75000.00, 1, 'EMP001'),
    ('Jane', 'Smith', 'jane.smith@company.com', '555-0102', '2019-03-22', 82000.00, 2, 'EMP002'),
    ('Mike', 'Johnson', 'mike.johnson@company.com', '555-0103', '2021-06-10', 68000.00, 1, 'EMP003'),
    ('Sarah', 'Wilson', 'sarah.wilson@company.com', '555-0104', '2022-09-05', 71000.00, 3, 'EMP004'); -- Additional employee

INSERT INTO Sales.Customers (CompanyName, ContactName, ContactEmail, Phone, Address, City, Country, PostalCode, CustomerType, CreditLimit)
VALUES 
    ('Acme Corp', 'Alice Brown', 'alice@acme.com', '555-1001', '123 Main St', 'New York', 'USA', '10001', 'Premium', 100000.00),
    ('Tech Solutions', 'Bob Wilson', 'bob@techsol.com', '555-1002', '456 Oak Ave', 'Los Angeles', 'USA', '90210', 'Standard', 50000.00),
    ('Global Inc', 'Carol Davis', 'carol@global.com', '555-1003', '789 Pine Rd', 'Chicago', 'USA', '60601', 'Premium', 150000.00),
    ('StartupXYZ', 'David Lee', 'david@startup.com', '555-1004', '321 Innovation Dr', 'Seattle', 'USA', '98101', 'Standard', 25000.00); -- Additional customer

INSERT INTO Sales.Products (ProductName, CategoryID, UnitPrice, UnitsInStock, UnitsOnOrder, ReorderLevel, ProductCode, SupplierID)
VALUES 
    ('Laptop Computer', 1, 1299.99, 25, 10, 5, 'LAP001', 1),
    ('Wireless Mouse', 2, 29.99, 100, 50, 20, 'MOU001', 2),
    ('USB Cable', 2, 9.99, 200, 100, 50, 'USB001', 2),
    ('Monitor 24"', 1, 299.99, 15, 5, 3, 'MON001', 1); -- Additional product

INSERT INTO Sales.Orders (CustomerID, OrderDate, RequiredDate, Freight, ShipName, ShipCity, ShipCountry, OrderStatus, OrderPriority, Discount)
VALUES 
    (1, '2024-01-15', '2024-01-20', 25.00, 'Acme Corp', 'New York', 'USA', 'Shipped', 'High', 0.05),
    (2, '2024-01-16', '2024-01-21', 15.00, 'Tech Solutions', 'Los Angeles', 'USA', 'Pending', 'Normal', 0.00),
    (3, '2024-01-17', '2024-01-22', 20.00, 'Global Inc', 'Chicago', 'USA', 'Processing', 'Normal', 0.02); -- Additional order

INSERT INTO Sales.OrderDetails (OrderID, ProductID, UnitPrice, Quantity, Discount)
VALUES 
    (1, 1, 1299.99, 1, 0.05),
    (1, 2, 29.99, 2, 0.00),
    (2, 3, 9.99, 5, 0.10),
    (3, 4, 299.99, 2, 0.00); -- Additional order detail

INSERT INTO Finance.Invoices (OrderID, InvoiceNumber, InvoiceDate, DueDate, TotalAmount, PaidAmount, Status)
VALUES 
    (1, 'INV-2024-001', '2024-01-15', '2024-02-15', 1354.97, 1354.97, 'Paid'),
    (2, 'INV-2024-002', '2024-01-16', '2024-02-16', 44.91, 0.00, 'Open'),
    (3, 'INV-2024-003', '2024-01-17', '2024-02-17', 599.98, 200.00, 'Open');

-- Create users and permissions (different from source)
IF EXISTS (SELECT * FROM sys.database_principals WHERE name = 'TestUser' AND type = 'S')
    DROP USER TestUser;
GO

CREATE USER TestUser WITHOUT LOGIN;
GO

IF EXISTS (SELECT * FROM sys.database_principals WHERE name = 'FinanceUser' AND type = 'S')
    DROP USER FinanceUser;
GO

CREATE USER FinanceUser WITHOUT LOGIN; -- Additional user
GO

IF EXISTS (SELECT * FROM sys.database_principals WHERE name = 'HR_ReadOnly' AND type = 'R')
    DROP ROLE HR_ReadOnly;
GO

CREATE ROLE HR_ReadOnly;
GO

IF EXISTS (SELECT * FROM sys.database_principals WHERE name = 'Sales_Full' AND type = 'R')
    DROP ROLE Sales_Full;
GO

CREATE ROLE Sales_Full;
GO

IF EXISTS (SELECT * FROM sys.database_principals WHERE name = 'Finance_ReadOnly' AND type = 'R')
    DROP ROLE Finance_ReadOnly;
GO

CREATE ROLE Finance_ReadOnly; -- Additional role
GO

-- Grant permissions
GRANT SELECT ON SCHEMA::HR TO HR_ReadOnly;
GRANT SELECT, INSERT, UPDATE, DELETE ON SCHEMA::Sales TO Sales_Full;
GRANT SELECT ON SCHEMA::Finance TO Finance_ReadOnly;
GRANT EXECUTE ON OBJECT::HR.GetEmployeeById TO HR_ReadOnly;
GRANT EXECUTE ON OBJECT::Sales.GetOrdersByCustomer TO Sales_Full;
GRANT EXECUTE ON OBJECT::Finance.GetOutstandingInvoices TO Finance_ReadOnly;

ALTER ROLE HR_ReadOnly ADD MEMBER TestUser;
ALTER ROLE Finance_ReadOnly ADD MEMBER FinanceUser; -- Additional role assignment
GO

PRINT 'Target database TestTargetDB created successfully with modified schema and additional data.';
