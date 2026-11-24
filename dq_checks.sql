-- =====================================================================
-- Food Product Data Quality Audit – Open Food Facts (Netherlands)
-- Engine: DuckDB (run in DBeaver)
-- Author: Melis Gönden
-- =====================================================================


-- ---------------------------------------------------------------------
-- 0. LOAD DATA
-- Source: https://static.openfoodfacts.org/data/en.openfoodfacts.org.products.csv.gz
-- Tab-separated, ~9 GB uncompressed. Only products sold in the Netherlands are kept.
-- ---------------------------------------------------------------------
CREATE TABLE products_raw AS
SELECT *
FROM read_csv('/path/to/en.openfoodfacts.org.products.csv.gz',
     delim='\t', header=true, quote='',
     all_varchar=true, ignore_errors=true)
WHERE countries_tags LIKE '%en:netherlands%';
-- Result: 116,660 products


-- ---------------------------------------------------------------------
-- 1. TYPED WORKING TABLE
-- All columns were loaded as text. TRY_CAST converts nutrient values to
-- numbers and turns unparseable values into NULL instead of failing.
-- ---------------------------------------------------------------------
CREATE TABLE products AS
SELECT
  code,
  product_name,
  brands,
  categories_tags,
  ingredients_text,
  allergens,
  nutriscore_grade,
  TRY_CAST("energy-kcal_100g"   AS DOUBLE) AS energy_kcal,
  TRY_CAST(fat_100g             AS DOUBLE) AS fat,
  TRY_CAST("saturated-fat_100g" AS DOUBLE) AS sat_fat,
  TRY_CAST(carbohydrates_100g   AS DOUBLE) AS carbs,
  TRY_CAST(sugars_100g          AS DOUBLE) AS sugars,
  TRY_CAST(proteins_100g        AS DOUBLE) AS protein,
  TRY_CAST(salt_100g            AS DOUBLE) AS salt
FROM products_raw;


-- ---------------------------------------------------------------------
-- 2. COMPLETENESS – share of filled fields
-- ---------------------------------------------------------------------
SELECT
  COUNT(*) AS total_products,
  ROUND(100.0 * COUNT(NULLIF(TRIM(product_name), ''))     / COUNT(*), 1) AS product_name_pct,
  ROUND(100.0 * COUNT(NULLIF(TRIM(brands), ''))           / COUNT(*), 1) AS brand_pct,
  ROUND(100.0 * COUNT(NULLIF(TRIM(ingredients_text), '')) / COUNT(*), 1) AS ingredients_pct,
  ROUND(100.0 * COUNT(NULLIF(TRIM(allergens), ''))        / COUNT(*), 1) AS allergens_pct,
  ROUND(100.0 * COUNT(energy_kcal)                        / COUNT(*), 1) AS energy_kcal_pct,
  ROUND(100.0 * COUNT(NULLIF(TRIM(nutriscore_grade), '')) / COUNT(*), 1) AS nutriscore_pct
FROM products;


-- ---------------------------------------------------------------------
-- 3. UNIQUENESS – duplicate or empty barcodes
-- ---------------------------------------------------------------------
SELECT
  COUNT(*)                        AS total_rows,
  COUNT(DISTINCT code)            AS unique_barcodes,
  COUNT(*) - COUNT(DISTINCT code) AS duplicate_rows,
  COUNT(*) FILTER (WHERE code IS NULL OR TRIM(code) = '') AS empty_barcodes
FROM products;


-- ---------------------------------------------------------------------
-- 4. VALIDITY – barcode format
-- ---------------------------------------------------------------------
SELECT
  CASE
    WHEN NOT regexp_matches(code, '^[0-9]+$') THEN 'non-numeric'
    WHEN length(code) = 13 THEN 'EAN-13'
    WHEN length(code) = 8  THEN 'EAN-8'
    WHEN length(code) = 12 THEN 'UPC-A'
    ELSE 'other length'
  END AS barcode_type,
  COUNT(*) AS products,
  ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct
FROM products
GROUP BY 1
ORDER BY products DESC;


-- ---------------------------------------------------------------------
-- 5. VALIDITY – GS1 check digit
-- Digits are weighted 3,1,3,1... from the right (excluding the check digit);
-- the check digit brings the sum up to the next multiple of 10.
-- ---------------------------------------------------------------------
CREATE OR REPLACE MACRO is_valid_gs1(c) AS
  CAST(right(c, 1) AS INT) =
  (10 - list_sum([
      CAST(substr(c, i, 1) AS INT)
      * CASE WHEN (length(c) - i) % 2 = 1 THEN 3 ELSE 1 END
      FOR i IN range(1, length(c))
   ]) % 10) % 10;

SELECT
  CASE length(code) WHEN 13 THEN 'EAN-13' ELSE 'EAN-8' END AS barcode_type,
  COUNT(*) AS products,
  COUNT(*) FILTER (WHERE NOT is_valid_gs1(code)) AS invalid,
  ROUND(100.0 * COUNT(*) FILTER (WHERE NOT is_valid_gs1(code)) / COUNT(*), 2) AS invalid_pct
FROM products
WHERE length(code) IN (8, 13) AND regexp_matches(code, '^[0-9]+$')
GROUP BY 1
ORDER BY 1;


-- ---------------------------------------------------------------------
-- 6. ROOT CAUSE – invalid vs valid 8-digit codes (control group)
-- ---------------------------------------------------------------------
-- 6a. Pareto by brand (no concentration found -> not brand-specific)
SELECT
  COALESCE(NULLIF(TRIM(lower(split_part(brands, ',', 1))), ''), '(no brand)') AS brand,
  COUNT(*) AS invalid_codes,
  ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct,
  ROUND(100.0 * SUM(COUNT(*)) OVER (ORDER BY COUNT(*) DESC ROWS UNBOUNDED PRECEDING)
        / SUM(COUNT(*)) OVER (), 1) AS cumulative_pct
FROM products
WHERE length(code) = 8 AND regexp_matches(code, '^[0-9]+$') AND NOT is_valid_gs1(code)
GROUP BY 1
ORDER BY invalid_codes DESC
LIMIT 15;

-- 6b. Random sample for manual review
SELECT code, product_name, brands, categories_tags
FROM products
WHERE length(code) = 8 AND regexp_matches(code, '^[0-9]+$') AND NOT is_valid_gs1(code)
USING SAMPLE 30 ROWS;

-- 6c. Pattern comparison: invalid vs valid
SELECT
  CASE WHEN is_valid_gs1(code) THEN 'valid' ELSE 'invalid' END AS status,
  COUNT(*) AS products,
  ROUND(100.0 * COUNT(*) FILTER (WHERE code LIKE '00%') / COUNT(*), 1)                          AS starts_with_00_pct,
  ROUND(100.0 * COUNT(*) FILTER (WHERE contains(product_name, substr(code, 2))) / COUNT(*), 1)  AS code_in_name_pct,
  ROUND(100.0 * COUNT(*) FILTER (WHERE starts_with(lower(product_name),
        lower(TRIM(split_part(brands, ',', 1))))) / COUNT(*), 1)                                AS brand_equals_first_word_pct,
  ROUND(100.0 * COUNT(*) FILTER (WHERE categories_tags IS NULL
        OR TRIM(categories_tags) = '') / COUNT(*), 1)                                           AS no_category_pct
FROM products
WHERE length(code) = 8 AND regexp_matches(code, '^[0-9]+$')
GROUP BY 1;


-- ---------------------------------------------------------------------
-- 7. PLAUSIBILITY – physically impossible nutrient values (per 100 g)
-- ---------------------------------------------------------------------
SELECT
  COUNT(*) FILTER (WHERE fat < 0 OR carbs < 0 OR sugars < 0
                      OR protein < 0 OR salt < 0 OR energy_kcal < 0) AS negative_value,
  COUNT(*) FILTER (WHERE fat > 100 OR carbs > 100 OR sugars > 100
                      OR protein > 100 OR salt > 100)                AS over_100g,
  COUNT(*) FILTER (WHERE energy_kcal > 900)                         AS over_900_kcal,
  COUNT(*) FILTER (WHERE sugars  > carbs + 0.5)                     AS sugars_gt_carbs,
  COUNT(*) FILTER (WHERE sat_fat > fat   + 0.5)                     AS satfat_gt_fat,
  COUNT(*) FILTER (WHERE fat + carbs + protein > 105)               AS macros_over_100g
FROM products;


-- ---------------------------------------------------------------------
-- 8. CONSISTENCY – declared energy vs 4P + 4C + 9F
-- Tolerance: max(20 kcal, 20%) to allow for fibre, alcohol, polyols and rounding.
-- Ratio ~4.2 = likely kJ value entered in the kcal field.
-- ---------------------------------------------------------------------
WITH k AS (
  SELECT energy_kcal, 4 * protein + 4 * carbs + 9 * fat AS calc_kcal
  FROM products
  WHERE energy_kcal > 0
    AND protein IS NOT NULL AND carbs IS NOT NULL AND fat IS NOT NULL
)
SELECT
  COUNT(*) AS checked,
  COUNT(*) FILTER (WHERE abs(energy_kcal - calc_kcal) <= GREATEST(20, 0.20 * calc_kcal)) AS consistent,
  COUNT(*) FILTER (WHERE abs(energy_kcal - calc_kcal) >  GREATEST(20, 0.20 * calc_kcal)) AS inconsistent,
  COUNT(*) FILTER (WHERE calc_kcal >= 20
                   AND energy_kcal / calc_kcal BETWEEN 3.8 AND 4.6)                      AS likely_kj_error
FROM k;


-- ---------------------------------------------------------------------
-- 9. CONSISTENCY – allergens in ingredients but missing from allergen fields
-- ---------------------------------------------------------------------
-- 9a. Which allergen column is actually used?
SELECT
  ROUND(100.0 * COUNT(NULLIF(TRIM(allergens), ''))    / COUNT(*), 1) AS allergens_pct,
  ROUND(100.0 * COUNT(NULLIF(TRIM(allergens_en), '')) / COUNT(*), 1) AS allergens_en_pct
FROM products_raw;

-- 9b. Allergen check using both columns
WITH rules(allergen, field_pattern, ingredient_pattern) AS (
  VALUES
    ('Milk',      'milk',           'melk|milk|boter|kaas|room|wei|lactose'),
    ('Gluten',    'gluten',         'tarwe|wheat|gerst|rogge|spelt|gluten'),
    ('Egg',       'egg',            'kippenei|eieren|eigeel|(^|[^a-z])ei([^a-z]|$)|egg'),
    ('Soy',       'soy',            'soja|soy'),
    ('Peanut',    'peanut',         'pinda|peanut'),
    ('Tree nuts', '(^|[^a-z])nuts', 'hazelno|amandel|walno|cashew|pistach')
),
p AS (
  SELECT
    lower(ingredients_text) AS ingredients,
    lower(COALESCE(allergens, '') || ',' || COALESCE(allergens_en, '')) AS allergen_fields
  FROM products_raw
  WHERE NULLIF(TRIM(ingredients_text), '') IS NOT NULL
),
m AS (
  SELECT r.allergen, regexp_matches(p.allergen_fields, r.field_pattern) AS declared
  FROM p
  JOIN rules r ON regexp_matches(p.ingredients, r.ingredient_pattern)
)
SELECT
  allergen,
  COUNT(*) AS in_ingredients,
  COUNT(*) FILTER (WHERE NOT declared) AS not_declared,
  ROUND(100.0 * COUNT(*) FILTER (WHERE NOT declared) / COUNT(*), 1) AS not_declared_pct
FROM m
GROUP BY allergen
ORDER BY in_ingredients DESC;

-- 9c. Milk false positives (cocoa butter, peanut butter, plant-based "milks")
WITH p AS (
  SELECT
    regexp_replace(lower(ingredients_text),
      'cacaoboter|cacao boter|pindakaas|kokosmelk|kokosroom|havermelk|amandelmelk|sojamelk|rijstmelk|sheaboter',
      '', 'g') AS cleaned,
    lower(ingredients_text) AS ingredients,
    lower(COALESCE(allergens, '') || ',' || COALESCE(allergens_en, '')) AS allergen_fields
  FROM products_raw
  WHERE NULLIF(TRIM(ingredients_text), '') IS NOT NULL
)
SELECT
  COUNT(*) AS milk_flagged,
  COUNT(*) FILTER (WHERE NOT regexp_matches(cleaned, 'melk|milk|boter|kaas|room|wei|lactose')) AS false_positive,
  COUNT(*) FILTER (WHERE     regexp_matches(cleaned, 'melk|milk|boter|kaas|room|wei|lactose')) AS true_suspect
FROM p
WHERE regexp_matches(ingredients, 'melk|milk|boter|kaas|room|wei|lactose')
  AND NOT regexp_matches(allergen_fields, 'milk');


-- ---------------------------------------------------------------------
-- 10. ISSUE LOG – one row per product per issue
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE dq_issues AS
WITH a AS (
  SELECT
    code,
    lower(ingredients_text) AS ing,
    regexp_replace(lower(ingredients_text),
      'cacaoboter|cacao boter|pindakaas|kokosmelk|kokosroom|havermelk|amandelmelk|sojamelk|rijstmelk|sheaboter',
      '', 'g') AS ing_milk,
    lower(COALESCE(allergens, '') || ',' || COALESCE(allergens_en, '')) AS al
  FROM products_raw
  WHERE NULLIF(TRIM(ingredients_text), '') IS NOT NULL
)
SELECT code, 'Completeness' AS dimension, 'Ingredients missing' AS issue
  FROM products WHERE NULLIF(TRIM(ingredients_text), '') IS NULL
UNION ALL
SELECT code, 'Completeness', 'Brand missing'
  FROM products WHERE NULLIF(TRIM(brands), '') IS NULL
UNION ALL
SELECT code, 'Completeness', 'Product name missing'
  FROM products WHERE NULLIF(TRIM(product_name), '') IS NULL
UNION ALL
SELECT code, 'Completeness', 'Energy (kcal) missing'
  FROM products WHERE energy_kcal IS NULL
UNION ALL
SELECT code, 'Validity', 'Non-standard barcode'
  FROM products WHERE length(code) NOT IN (8, 12, 13) OR NOT regexp_matches(code, '^[0-9]+$')
UNION ALL
SELECT code, 'Validity', 'GS1 check digit invalid'
  FROM products
  WHERE length(code) IN (8, 12, 13) AND regexp_matches(code, '^[0-9]+$')
    AND NOT is_valid_gs1(code)
UNION ALL
SELECT code, 'Validity', 'Impossible nutrient value'
  FROM products
  WHERE fat < 0 OR carbs < 0 OR sugars < 0 OR protein < 0 OR salt < 0 OR energy_kcal < 0
     OR fat > 100 OR carbs > 100 OR sugars > 100 OR protein > 100 OR salt > 100
     OR energy_kcal > 900 OR sugars > carbs + 0.5 OR sat_fat > fat + 0.5
     OR fat + carbs + protein > 105
UNION ALL
SELECT code, 'Consistency', 'kcal ≠ 4P+4C+9F'
  FROM products
  WHERE energy_kcal > 0 AND protein IS NOT NULL AND carbs IS NOT NULL AND fat IS NOT NULL
    AND abs(energy_kcal - (4*protein + 4*carbs + 9*fat))
        > GREATEST(20, 0.20 * (4*protein + 4*carbs + 9*fat))
UNION ALL
SELECT DISTINCT code, 'Consistency', 'Allergen field incomplete'
  FROM a
  WHERE (regexp_matches(ing_milk, 'melk|milk|boter|kaas|room|wei|lactose') AND NOT regexp_matches(al, 'milk'))
     OR (regexp_matches(ing, 'tarwe|wheat|gerst|rogge|spelt|gluten')       AND NOT regexp_matches(al, 'gluten'))
     OR (regexp_matches(ing, 'kippenei|eieren|eigeel|(^|[^a-z])ei([^a-z]|$)|egg') AND NOT regexp_matches(al, 'egg'))
     OR (regexp_matches(ing, 'soja|soy')                                   AND NOT regexp_matches(al, 'soy'))
     OR (regexp_matches(ing, 'pinda|peanut')                               AND NOT regexp_matches(al, 'peanut'))
     OR (regexp_matches(ing, 'hazelno|amandel|walno|cashew|pistach')       AND NOT regexp_matches(al, '(^|[^a-z])nuts'));


-- ---------------------------------------------------------------------
-- 11. PARETO SUMMARY
-- ---------------------------------------------------------------------
SELECT
  dimension,
  issue,
  COUNT(*) AS affected_products,
  ROUND(100.0 * COUNT(*) / (SELECT COUNT(*) FROM products), 1) AS pct_of_products,
  ROUND(100.0 * SUM(COUNT(*)) OVER (ORDER BY COUNT(*) DESC ROWS UNBOUNDED PRECEDING)
        / SUM(COUNT(*)) OVER (), 1) AS cumulative_pct
FROM dq_issues
GROUP BY dimension, issue
ORDER BY affected_products DESC;
