-- =============================================
-- Create Source Database for Drift Detection Test
-- This represents the "baseline" database
-- =============================================

-- Drop database if it exists
IF EXISTS (SELECT name FROM sys.databases WHERE name = 'TestSourceDB')
BEGIN
    ALTER DATABASE TestSourceDB SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE TestSourceDB;
END
GO

-- Create the source database
CREATE DATABASE TestSourceDB;
GO

USE TestSourceDB;
GO

-- Create schemas
IF NOT EXISTS (SELECT * FROM sys.schemas WHERE name = 'HR')
    EXEC('CREATE SCHEMA HR');
GO

IF NOT EXISTS (SELECT * FROM sys.schemas WHERE name = 'Sales')
    EXEC('CREATE SCHEMA Sales');
GO

IF NOT EXISTS (SELECT * FROM sys.schemas WHERE name = 'Inventory')
    EXEC('CREATE SCHEMA Inventory');
GO

-- Create custom data types
IF NOT EXISTS (SELECT * FROM sys.types WHERE name = 'EmailAddress' AND schema_id = SCHEMA_ID('dbo'))
    CREATE TYPE dbo.EmailAddress FROM NVARCHAR(255);
GO

IF NOT EXISTS (SELECT * FROM sys.types WHERE name = 'PhoneNumber' AND schema_id = SCHEMA_ID('dbo'))
    CREATE TYPE dbo.PhoneNumber FROM NVARCHAR(20);
GO

IF NOT EXISTS (SELECT * FROM sys.types WHERE name = 'EmployeeID' AND schema_id = SCHEMA_ID('HR'))
    CREATE TYPE HR.EmployeeID FROM INT;
GO

-- Create tables
IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'Employees' AND schema_id = SCHEMA_ID('HR'))
BEGIN
    CREATE TABLE HR.Employees (
    EmployeeID HR.EmployeeID IDENTITY(1,1) PRIMARY KEY,
    FirstName NVARCHAR(50) NOT NULL,
    LastName NVARCHAR(50) NOT NULL,
    Email dbo.EmailAddress NOT NULL,
    Phone dbo.PhoneNumber,
    HireDate DATE NOT NULL,
    Salary DECIMAL(10,2),
    DepartmentID INT,
    IsActive BIT DEFAULT 1,
    CreatedDate DATETIME2 DEFAULT GETDATE(),
    ModifiedDate DATETIME2 DEFAULT GETDATE()
    );
END
GO

IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'Customers' AND schema_id = SCHEMA_ID('Sales'))
BEGIN
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
        IsActive BIT DEFAULT 1
    );
END
GO

IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'Orders' AND schema_id = SCHEMA_ID('Sales'))
BEGIN
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
        OrderStatus NVARCHAR(20) DEFAULT 'Pending'
    );
END
GO

IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'Products' AND schema_id = SCHEMA_ID('Inventory'))
BEGIN
    CREATE TABLE Inventory.Products (
        ProductID INT IDENTITY(1,1) PRIMARY KEY,
        ProductName NVARCHAR(100) NOT NULL,
        CategoryID INT,
        UnitPrice DECIMAL(10,2) NOT NULL,
        UnitsInStock INT DEFAULT 0,
        UnitsOnOrder INT DEFAULT 0,
        ReorderLevel INT DEFAULT 0,
        Discontinued BIT DEFAULT 0,
        CreatedDate DATETIME2 DEFAULT GETDATE()
    );
END
GO

IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'OrderDetails' AND schema_id = SCHEMA_ID('Sales'))
BEGIN
    CREATE TABLE Sales.OrderDetails (
        OrderID INT NOT NULL,
        ProductID INT NOT NULL,
        UnitPrice DECIMAL(10,2) NOT NULL,
        Quantity INT NOT NULL DEFAULT 1,
        Discount DECIMAL(3,2) DEFAULT 0,
        PRIMARY KEY (OrderID, ProductID)
    );
END
GO
GO

-- Create indexes
CREATE INDEX IX_Employees_DepartmentID ON HR.Employees(DepartmentID);
CREATE INDEX IX_Employees_Email ON HR.Employees(Email);
CREATE INDEX IX_Employees_HireDate ON HR.Employees(HireDate);

CREATE INDEX IX_Customers_CompanyName ON Sales.Customers(CompanyName);
CREATE INDEX IX_Customers_Country ON Sales.Customers(Country);
CREATE INDEX IX_Customers_City ON Sales.Customers(City);

CREATE INDEX IX_Orders_CustomerID ON Sales.Orders(CustomerID);
CREATE INDEX IX_Orders_OrderDate ON Sales.Orders(OrderDate);
CREATE INDEX IX_Orders_ShippedDate ON Sales.Orders(ShippedDate);

CREATE INDEX IX_Products_CategoryID ON Inventory.Products(CategoryID);
CREATE INDEX IX_Products_ProductName ON Inventory.Products(ProductName);
GO

-- Create foreign key constraints
ALTER TABLE Sales.Orders
ADD CONSTRAINT FK_Orders_Customers 
FOREIGN KEY (CustomerID) REFERENCES Sales.Customers(CustomerID);

ALTER TABLE Sales.OrderDetails
ADD CONSTRAINT FK_OrderDetails_Orders 
FOREIGN KEY (OrderID) REFERENCES Sales.Orders(OrderID);

ALTER TABLE Sales.OrderDetails
ADD CONSTRAINT FK_OrderDetails_Products 
FOREIGN KEY (ProductID) REFERENCES Inventory.Products(ProductID);
GO

-- Create check constraints
ALTER TABLE HR.Employees
ADD CONSTRAINT CK_Employees_Salary CHECK (Salary > 0);

ALTER TABLE HR.Employees
ADD CONSTRAINT CK_Employees_Email CHECK (Email LIKE '%@%');

ALTER TABLE Sales.Orders
ADD CONSTRAINT CK_Orders_Freight CHECK (Freight >= 0);

ALTER TABLE Inventory.Products
ADD CONSTRAINT CK_Products_UnitPrice CHECK (UnitPrice > 0);

ALTER TABLE Inventory.Products
ADD CONSTRAINT CK_Products_UnitsInStock CHECK (UnitsInStock >= 0);
GO

-- Create stored procedures
IF EXISTS (SELECT * FROM sys.procedures WHERE name = 'GetEmployeeById' AND schema_id = SCHEMA_ID('HR'))
    DROP PROCEDURE HR.GetEmployeeById;
GO

CREATE PROCEDURE HR.GetEmployeeById
    @EmployeeID INT
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
        IsActive
    FROM HR.Employees
    WHERE EmployeeID = @EmployeeID;
END
GO

IF EXISTS (SELECT * FROM sys.procedures WHERE name = 'GetOrdersByCustomer' AND schema_id = SCHEMA_ID('Sales'))
    DROP PROCEDURE Sales.GetOrdersByCustomer;
GO

CREATE PROCEDURE Sales.GetOrdersByCustomer
    @CustomerID INT,
    @StartDate DATE = NULL,
    @EndDate DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT 
        o.OrderID,
        o.OrderDate,
        o.RequiredDate,
        o.ShippedDate,
        o.Freight,
        o.OrderStatus
    FROM Sales.Orders o
    WHERE o.CustomerID = @CustomerID
    AND (@StartDate IS NULL OR o.OrderDate >= @StartDate)
    AND (@EndDate IS NULL OR o.OrderDate <= @EndDate);
END
GO

IF EXISTS (SELECT * FROM sys.procedures WHERE name = 'GetLowStockProducts' AND schema_id = SCHEMA_ID('Inventory'))
    DROP PROCEDURE Inventory.GetLowStockProducts;
GO

CREATE PROCEDURE Inventory.GetLowStockProducts
    @ReorderLevel INT = 10
AS
BEGIN
    SET NOCOUNT ON;
    SELECT 
        ProductID,
        ProductName,
        UnitsInStock,
        ReorderLevel
    FROM Inventory.Products
    WHERE UnitsInStock <= @ReorderLevel
    AND Discontinued = 0;
END
GO

-- Create functions
IF EXISTS (SELECT * FROM sys.objects WHERE name = 'GetFullName' AND schema_id = SCHEMA_ID('HR') AND type = 'FN')
    DROP FUNCTION HR.GetFullName;
GO

CREATE FUNCTION HR.GetFullName(@FirstName NVARCHAR(50), @LastName NVARCHAR(50))
RETURNS NVARCHAR(101)
AS
BEGIN
    RETURN @FirstName + ' ' + @LastName;
END
GO

IF EXISTS (SELECT * FROM sys.objects WHERE name = 'CalculateOrderTotal' AND schema_id = SCHEMA_ID('Sales') AND type = 'FN')
    DROP FUNCTION Sales.CalculateOrderTotal;
GO

CREATE FUNCTION Sales.CalculateOrderTotal(@OrderID INT)
RETURNS DECIMAL(12,2)
AS
BEGIN
    DECLARE @Total DECIMAL(12,2) = 0;
    
    SELECT @Total = SUM((UnitPrice * Quantity) * (1 - Discount))
    FROM Sales.OrderDetails
    WHERE OrderID = @OrderID;
    
    RETURN ISNULL(@Total, 0);
END
GO

-- Create views
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
    DATEDIFF(YEAR, e.HireDate, GETDATE()) AS YearsOfService
FROM HR.Employees e;
GO

IF EXISTS (SELECT * FROM sys.views WHERE name = 'CustomerOrderSummary' AND schema_id = SCHEMA_ID('Sales'))
    DROP VIEW Sales.CustomerOrderSummary;
GO

CREATE VIEW Sales.CustomerOrderSummary AS
SELECT 
    c.CustomerID,
    c.CompanyName,
    c.ContactName,
    COUNT(o.OrderID) AS TotalOrders,
    SUM(Sales.CalculateOrderTotal(o.OrderID)) AS TotalSpent,
    MAX(o.OrderDate) AS LastOrderDate
FROM Sales.Customers c
LEFT JOIN Sales.Orders o ON c.CustomerID = o.CustomerID
GROUP BY c.CustomerID, c.CompanyName, c.ContactName;
GO

-- Insert sample data
INSERT INTO HR.Employees (FirstName, LastName, Email, Phone, HireDate, Salary, DepartmentID)
VALUES 
    ('John', 'Doe', 'john.doe@company.com', '555-0101', '2020-01-15', 75000.00, 1),
    ('Jane', 'Smith', 'jane.smith@company.com', '555-0102', '2019-03-22', 82000.00, 2),
    ('Mike', 'Johnson', 'mike.johnson@company.com', '555-0103', '2021-06-10', 68000.00, 1);

INSERT INTO Sales.Customers (CompanyName, ContactName, ContactEmail, Phone, Address, City, Country, PostalCode)
VALUES 
    ('Acme Corp', 'Alice Brown', 'alice@acme.com', '555-1001', '123 Main St', 'New York', 'USA', '10001'),
    ('Tech Solutions', 'Bob Wilson', 'bob@techsol.com', '555-1002', '456 Oak Ave', 'Los Angeles', 'USA', '90210'),
    ('Global Inc', 'Carol Davis', 'carol@global.com', '555-1003', '789 Pine Rd', 'Chicago', 'USA', '60601');

INSERT INTO Inventory.Products (ProductName, CategoryID, UnitPrice, UnitsInStock, UnitsOnOrder, ReorderLevel)
VALUES 
    ('Laptop Computer', 1, 1299.99, 25, 10, 5),
    ('Wireless Mouse', 2, 29.99, 100, 50, 20),
    ('USB Cable', 2, 9.99, 200, 100, 50);

INSERT INTO Sales.Orders (CustomerID, OrderDate, RequiredDate, Freight, ShipName, ShipCity, ShipCountry, OrderStatus)
VALUES 
    (1, '2024-01-15', '2024-01-20', 25.00, 'Acme Corp', 'New York', 'USA', 'Shipped'),
    (2, '2024-01-16', '2024-01-21', 15.00, 'Tech Solutions', 'Los Angeles', 'USA', 'Pending');

INSERT INTO Sales.OrderDetails (OrderID, ProductID, UnitPrice, Quantity, Discount)
VALUES 
    (1, 1, 1299.99, 1, 0.05),
    (1, 2, 29.99, 2, 0.00),
    (2, 3, 9.99, 5, 0.10);

-- Create users and permissions
IF EXISTS (SELECT * FROM sys.database_principals WHERE name = 'TestUser' AND type = 'S')
    DROP USER TestUser;
GO

CREATE USER TestUser WITHOUT LOGIN;
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

-- Grant permissions
GRANT SELECT ON SCHEMA::HR TO HR_ReadOnly;
GRANT SELECT, INSERT, UPDATE, DELETE ON SCHEMA::Sales TO Sales_Full;
GRANT EXECUTE ON OBJECT::HR.GetEmployeeById TO HR_ReadOnly;
GRANT EXECUTE ON OBJECT::Sales.GetOrdersByCustomer TO Sales_Full;

ALTER ROLE HR_ReadOnly ADD MEMBER TestUser;
GO

PRINT 'Source database TestSourceDB created successfully with sample schema and data.';
