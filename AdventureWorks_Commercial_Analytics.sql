/*
===============================================================================
ADVENTUREWORKS2022 – COMMERCIAL & CUSTOMER ANALYTICS (SQL PORTFOLIO PROJECT)
===============================================================================
Database:   AdventureWorks2022 (Microsoft SQL Server / T-SQL)
Objective:  Analyze customer retention, product category performance, unsold 
            inventory gaps, and month-over-month revenue growth to support 
            commercial decision-making.
Techniques: Multi-table JOINs, CTEs, Window Functions (DENSE_RANK, LAG, 
            Running Totals), Correlated Subqueries, Conditional Aggregations.
===============================================================================
*/

USE AdventureWorks2022;
GO


/*
===============================================================================
CHAPTER 1: CUSTOMER BEHAVIOR & SEGMENTATION
===============================================================================
*/

-- ----------------------------------------------------------------------------
-- 1.1 High-Value Customer Segmentation
-- Business Question: Which customers have placed at least 5 orders totaling 
-- over $10,000, and what is their order frequency, average order value (AOV), 
-- and purchasing lifespan?
-- ----------------------------------------------------------------------------
WITH CustomerMetrics AS (
    SELECT 
        CustomerID,
        COUNT(SalesOrderID) AS TotalOrders,
        SUM(TotalDue) AS TotalSpend,
        AVG(TotalDue) AS AverageOrderValue,
        MAX(TotalDue) AS MaxOrderValue,
        MIN(OrderDate) AS FirstOrderDate,
        MAX(OrderDate) AS LastOrderDate
    FROM Sales.SalesOrderHeader
    GROUP BY CustomerID
),
HighValueCustomers AS (
    SELECT *
    FROM CustomerMetrics
    WHERE TotalOrders >= 5 
      AND TotalSpend > 10000
)
SELECT * 
FROM HighValueCustomers
ORDER BY TotalSpend DESC;


-- ----------------------------------------------------------------------------
-- 1.2 Above-Average Active Buyers
-- Business Question: Which active customers (with orders after Jan 1, 2013) 
-- outperform the global customer average in both order frequency and total spend?
-- ----------------------------------------------------------------------------
WITH CustomerDetails AS (
    SELECT 
        CustomerID,
        COUNT(*) AS TotalOrders,
        SUM(TotalDue) AS TotalSpend,
        MAX(OrderDate) AS LastOrderDate
    FROM Sales.SalesOrderHeader
    GROUP BY CustomerID
),
GlobalBenchmarks AS (
    SELECT *,
        AVG(CAST(TotalOrders AS DECIMAL(10,2))) OVER() AS AvgOrdersPerCustomer,
        AVG(CAST(TotalSpend AS DECIMAL(10,2))) OVER() AS AvgSpendPerCustomer
    FROM CustomerDetails
)
SELECT 
    CustomerID,
    TotalOrders,
    TotalSpend,
    LastOrderDate,
    AvgOrdersPerCustomer,
    AvgSpendPerCustomer
FROM GlobalBenchmarks
WHERE TotalOrders > AvgOrdersPerCustomer 
  AND TotalSpend > AvgSpendPerCustomer 
  AND LastOrderDate > '2013-01-01'
ORDER BY TotalSpend DESC;


-- ----------------------------------------------------------------------------
-- 1.3 Customer Order Progression & Cumulative Spend
-- Business Question: How does each customer's cumulative spend grow over time, 
-- and how does each order compare in value to their immediately preceding order?
-- ----------------------------------------------------------------------------
SELECT 
    CustomerID,
    SalesOrderID,
    OrderDate,
    TotalDue AS CurrentOrderValue,
    SUM(TotalDue) OVER (
        PARTITION BY CustomerID
        ORDER BY OrderDate, SalesOrderID
    ) AS CumulativeSpend,
    LAG(TotalDue) OVER (
        PARTITION BY CustomerID
        ORDER BY OrderDate, SalesOrderID
    ) AS PreviousOrderValue,
    (TotalDue - LAG(TotalDue) OVER (
        PARTITION BY CustomerID
        ORDER BY OrderDate, SalesOrderID
    )) AS SpendDifferenceVsPrevious
FROM Sales.SalesOrderHeader
ORDER BY CustomerID, OrderDate, SalesOrderID;


-- ----------------------------------------------------------------------------
-- 1.4 Order Share in Customer Lifetime Spend
-- Business Question: What percentage of a customer's total lifetime spend does 
-- each individual order represent?
-- ----------------------------------------------------------------------------
SELECT
    SalesOrderID,
    CustomerID,
    TotalDue AS OrderValue,
    SUM(TotalDue) OVER (
        PARTITION BY CustomerID
    ) AS CustomerLifetimeSpend,
    CAST(
        TotalDue * 100.0 / SUM(TotalDue) OVER (
            PARTITION BY CustomerID
        ) AS DECIMAL(10,2)
    ) AS OrderSharePct
FROM Sales.SalesOrderHeader
ORDER BY CustomerID, OrderSharePct DESC;


/*
===============================================================================
CHAPTER 2: PRODUCT & INVENTORY PERFORMANCE
===============================================================================
*/

-- ----------------------------------------------------------------------------
-- 2.1 Top 5 Best-Selling Products per Category
-- Business Question: Which are the top 5 revenue-generating products within 
-- each product category, and how many units were sold?
-- ----------------------------------------------------------------------------
WITH ProductPerformance AS (
    SELECT 
        p.ProductID,
        p.Name AS ProductName,
        pc.Name AS CategoryName,
        COUNT(*) AS OrderLineCount,
        SUM(sod.OrderQty) AS TotalUnitsSold,
        SUM(sod.LineTotal) AS TotalRevenue,
        p.ListPrice
    FROM Production.Product AS p
    INNER JOIN Production.ProductSubcategory AS ps
        ON p.ProductSubcategoryID = ps.ProductSubcategoryID
    INNER JOIN Production.ProductCategory AS pc
        ON ps.ProductCategoryID = pc.ProductCategoryID
    INNER JOIN Sales.SalesOrderDetail AS sod
        ON p.ProductID = sod.ProductID
    GROUP BY 
        p.ProductID,
        p.Name,
        pc.Name,
        p.ListPrice
),
RankedProducts AS (
    SELECT *,
        DENSE_RANK() OVER (
            PARTITION BY CategoryName
            ORDER BY TotalRevenue DESC
        ) AS CategoryRank
    FROM ProductPerformance
)
SELECT * 
FROM RankedProducts
WHERE CategoryRank <= 5
ORDER BY CategoryName, CategoryRank;


-- ----------------------------------------------------------------------------
-- 2.2 Above-Average Category Product Density
-- Business Question: Which product categories offer a broader catalog (number 
-- of distinct products) than the overall category average, and what are their 
-- average and maximum list prices?
-- ----------------------------------------------------------------------------
WITH CategoryStats AS (
    SELECT 
        pc.ProductCategoryID,
        pc.Name AS CategoryName,
        COUNT(p.ProductID) AS ProductCount,
        AVG(p.ListPrice) AS AvgListPrice,
        MAX(p.ListPrice) AS MaxListPrice
    FROM Production.Product AS p
    INNER JOIN Production.ProductSubcategory AS ps
        ON p.ProductSubcategoryID = ps.ProductSubcategoryID
    INNER JOIN Production.ProductCategory AS pc
        ON ps.ProductCategoryID = pc.ProductCategoryID
    GROUP BY 
        pc.ProductCategoryID,
        pc.Name
),
AverageCategoryDensity AS (
    SELECT
        AVG(ProductCount) AS AvgProductsPerCategory
    FROM CategoryStats
)
SELECT 
    cs.ProductCategoryID,
    cs.CategoryName,
    cs.ProductCount,
    cs.AvgListPrice,
    cs.MaxListPrice,
    acd.AvgProductsPerCategory
FROM CategoryStats AS cs
CROSS JOIN AverageCategoryDensity AS acd
WHERE cs.ProductCount > acd.AvgProductsPerCategory
ORDER BY cs.ProductCount DESC;


-- ----------------------------------------------------------------------------
-- 2.3 Premium-Priced Items Within Subcategories
-- Business Question: Which products are priced higher than the average list 
-- price of their own subcategory?
-- ----------------------------------------------------------------------------
SELECT 
    p.ProductID,
    p.Name AS ProductName,
    p.ProductSubcategoryID,
    p.ListPrice
FROM Production.Product AS p
WHERE p.ListPrice > (
    SELECT AVG(p2.ListPrice)
    FROM Production.Product AS p2
    WHERE p2.ProductSubcategoryID = p.ProductSubcategoryID
)
ORDER BY p.ProductSubcategoryID, p.ListPrice DESC;


-- ----------------------------------------------------------------------------
-- 2.4 Unsold Inventory Gap Analysis
-- Business Question: Which products in the catalog have never been included 
-- in any customer sales order (identifying potential dead stock or internal-only 
-- manufacturing components)?
-- ----------------------------------------------------------------------------
SELECT
    p.ProductID, 
    p.Name AS ProductName,
    p.ListPrice
FROM Production.Product AS p
LEFT JOIN Sales.SalesOrderDetail AS sod
    ON p.ProductID = sod.ProductID
WHERE sod.ProductID IS NULL
ORDER BY p.ListPrice DESC, p.Name;


/*
===============================================================================
CHAPTER 3: REVENUE GROWTH & SEASONALITY
===============================================================================
*/

-- ----------------------------------------------------------------------------
-- 3.1 Month-over-Month (MoM) Revenue & Order Growth
-- Business Question: How do monthly order volumes, total revenue, and average 
-- order value evolve over time, and what is the Month-over-Month (MoM) revenue 
-- percentage change?
-- ----------------------------------------------------------------------------
WITH MonthlySales AS (
    SELECT 
        YEAR(OrderDate) AS SalesYear,
        MONTH(OrderDate) AS SalesMonth,
        COUNT(*) AS TotalOrders,
        SUM(TotalDue) AS TotalRevenue,
        AVG(TotalDue) AS AverageOrderValue
    FROM Sales.SalesOrderHeader
    GROUP BY 
        YEAR(OrderDate),
        MONTH(OrderDate)
),
PreviousMonthComparison AS (
    SELECT *,
        LAG(TotalRevenue) OVER (
            ORDER BY SalesYear, SalesMonth
        ) AS PreviousMonthRevenue
    FROM MonthlySales
)
SELECT 
    SalesYear,
    SalesMonth,
    TotalOrders,
    TotalRevenue,
    AverageOrderValue,
    PreviousMonthRevenue,
    (TotalRevenue - PreviousMonthRevenue) AS MoMRevenueDiff,
    CAST(
    (TotalRevenue - PreviousMonthRevenue) / NULLIF(PreviousMonthRevenue, 0) * 100.0
    AS DECIMAL(10,2)
    ) AS MoMGrowthPct
FROM PreviousMonthComparison
ORDER BY SalesYear, SalesMonth;