-- =====================================================================
-- Шаг 1 из 3. Загрузка исходных CSV в схему raw «как есть».
-- Запускать из корня проекта: psql -v ON_ERROR_STOP=1 -f 03_sql/00_load_raw.sql
-- (используется \copy — клиентская загрузка, серверу файлы видеть не нужно).
-- =====================================================================
DROP SCHEMA IF EXISTS raw, ods, dds, mart, dq CASCADE;
CREATE SCHEMA raw;

CREATE TABLE raw.suppliers  (supplier_id text, inn text, supplier_name text, region text,
                             reliability_class text, valid_from date, valid_to date, is_current int);
CREATE TABLE raw.items      (item_id text, item_name text, category text, category_reported text, uom_code text);
CREATE TABLE raw.uom        (uom_code text, uom_name text, base_uom text, factor_to_base numeric);
CREATE TABLE raw.fx_rates   (rate_date date, currency text, rate_to_rub numeric);
CREATE TABLE raw.po_headers (order_id text, supplier_id text, order_dttm_msk timestamp, currency text,
                             delivery_city text, order_type text);
CREATE TABLE raw.po_lines   (order_id text, line_no int, item_id text, qty numeric, price numeric,
                             plan_price numeric, uom_code text, planned_delivery_date date,
                             status text, updated_at timestamp);
CREATE TABLE raw.receipts   (receipt_id text, order_id text, line_no int, received_at_utc timestamptz,
                             qty_received numeric, quality_status text, warehouse_code text);

\copy raw.suppliers  FROM 'data/suppliers.csv'  WITH (FORMAT csv, DELIMITER ';', HEADER true)
\copy raw.items      FROM 'data/items.csv'      WITH (FORMAT csv, DELIMITER ';', HEADER true)
\copy raw.uom        FROM 'data/uom.csv'        WITH (FORMAT csv, DELIMITER ';', HEADER true)
\copy raw.fx_rates   FROM 'data/fx_rates.csv'   WITH (FORMAT csv, DELIMITER ';', HEADER true)
\copy raw.po_headers FROM 'data/po_headers.csv' WITH (FORMAT csv, DELIMITER ';', HEADER true)
\copy raw.po_lines   FROM 'data/po_lines.csv'   WITH (FORMAT csv, DELIMITER ';', HEADER true)
\copy raw.receipts   FROM 'data/receipts.csv'   WITH (FORMAT csv, DELIMITER ';', HEADER true)
