-- =====================================================================
-- Шаг 3 из 3. ETL из raw в целевую модель Блока 2.
-- Запускать после 00_load_raw.sql и 02_ddl.sql.
-- Вспомогательный скрипт: сами ответы на Q1-Q3 лежат в q1..q3.
--
-- Правила преобразования взяты из 02_model.md, раздел 2.4.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Календарь
-- ---------------------------------------------------------------------
INSERT INTO dds.dim_date (date_key, date_actual, year_month_key, year_quarter_key,
                          quarter_no, month_no, is_weekend)
SELECT to_char(d,'YYYYMMDD')::int,
       d::date,
       to_char(d,'YYYYMM')::int,
       (extract(year FROM d)*10 + extract(quarter FROM d))::int,
       extract(quarter FROM d)::smallint,
       extract(month  FROM d)::smallint,
       extract(isodow FROM d) >= 6
FROM generate_series(DATE '2023-12-01', DATE '2026-12-31', INTERVAL '1 day') d;

-- ---------------------------------------------------------------------
-- 2. Единицы измерения
-- ---------------------------------------------------------------------
INSERT INTO dds.dim_uom (uom_code, uom_name, base_uom_code, factor_to_base)
SELECT uom_code, uom_name, base_uom, factor_to_base FROM raw.uom;

-- ---------------------------------------------------------------------
-- 3. Номенклатура.
--    760 позиций из справочника + 40 late-arriving заготовок по кодам,
--    которые встречаются в заказах, но отсутствуют в справочнике
--    (02_model.md, «Отсутствующая номенклатура»).
--    Допущение: эталонной считается колонка category; расхождение
--    с category_reported (33 позиции) помечается флагом.
-- ---------------------------------------------------------------------
INSERT INTO dds.dim_item (item_id, item_name, category_master, category_reported,
                          has_category_conflict, ref_uom_code, is_unknown)
SELECT item_id, item_name, category, category_reported,
       category IS DISTINCT FROM category_reported, uom_code, false
FROM raw.items;

INSERT INTO dds.dim_item (item_id, item_name, category_master, category_reported,
                          has_category_conflict, ref_uom_code, is_unknown)
SELECT DISTINCT l.item_id, NULL, 'Не определена', NULL, false, NULL, true
FROM raw.po_lines l
LEFT JOIN raw.items i ON i.item_id = l.item_id
WHERE i.item_id IS NULL;

-- позиция закупается в несовместимых базовых единицах (шт/кг/м)
UPDATE dds.dim_item i SET has_uom_conflict = true
WHERE EXISTS (
    SELECT 1 FROM raw.po_lines l JOIN raw.uom u ON u.uom_code = l.uom_code
    WHERE l.item_id = i.item_id
    GROUP BY l.item_id HAVING count(DISTINCT u.base_uom) > 1);

-- ---------------------------------------------------------------------
-- 4. Поставщики: золотая запись + SCD2.
--    Шаг 4.1 — по умолчанию каждая учётная запись получает собственную
--    золотую запись, слияние не выполняется автоматически.
-- ---------------------------------------------------------------------
INSERT INTO dds.dim_supplier_golden (inn, golden_name, region, reliability_class, is_merge_confirmed)
SELECT DISTINCT ON (s.supplier_id)
       s.inn,
       regexp_replace(btrim(s.supplier_name), '\s+', ' ', 'g'),
       s.region, s.reliability_class, false
FROM raw.suppliers s
ORDER BY s.supplier_id, s.valid_from DESC;   -- атрибуты берём из актуальной версии

-- временное соответствие supplier_id -> golden_supplier_id на шаге 4.1
CREATE TEMP TABLE tmp_sup_golden AS
SELECT DISTINCT ON (s.supplier_id) s.supplier_id, g.golden_supplier_id
FROM raw.suppliers s
JOIN dds.dim_supplier_golden g
  ON g.inn = s.inn
 AND g.golden_name = regexp_replace(btrim(s.supplier_name), '\s+', ' ', 'g')
ORDER BY s.supplier_id, s.valid_from DESC;

-- Шаг 4.2. SCD2. valid_from самой ранней версии расширяется до 1900-01-01,
-- иначе 230 заказов не покрываются ни одной действующей версией поставщика.
INSERT INTO dds.dim_supplier (supplier_id, golden_supplier_id, supplier_name, supplier_name_norm,
                              inn, region, reliability_class, valid_from, valid_to, is_current)
SELECT s.supplier_id,
       m.golden_supplier_id,
       s.supplier_name,
       lower(regexp_replace(btrim(s.supplier_name), '\s+', ' ', 'g')),
       s.inn, s.region, s.reliability_class,
       CASE WHEN s.valid_from = MIN(s.valid_from) OVER (PARTITION BY s.supplier_id)
            THEN DATE '1900-01-01' ELSE s.valid_from END,
       s.valid_to,
       s.is_current = 1
FROM raw.suppliers s
JOIN tmp_sup_golden m ON m.supplier_id = s.supplier_id;

-- Шаг 4.3. Имитация ручного подтверждения владельцем справочника.
-- В проде это задача стюарда; здесь 8 пар с совпадающим ИНН подтверждаются
-- как одно юридическое лицо, иначе рейтинг поставщиков заведомо неверен
-- (12,3% оборота, весь ТОП-5 меняется).
WITH survivor AS (
    SELECT inn, min(golden_supplier_id) AS keep_id
    FROM dds.dim_supplier_golden WHERE golden_supplier_id > 0
    GROUP BY inn HAVING count(*) > 1)
UPDATE dds.dim_supplier s SET golden_supplier_id = v.keep_id
FROM survivor v WHERE s.inn = v.inn;

DELETE FROM dds.dim_supplier_golden g
WHERE g.golden_supplier_id > 0
  AND NOT EXISTS (SELECT 1 FROM dds.dim_supplier s WHERE s.golden_supplier_id = g.golden_supplier_id);

UPDATE dds.dim_supplier_golden g
SET is_merge_confirmed = true,
    confirmed_by = 'demo: подтверждение по совпадению ИНН',
    confirmed_at = now(),
    has_attr_conflict = (
        SELECT count(DISTINCT s.reliability_class) > 1
        FROM dds.dim_supplier s WHERE s.golden_supplier_id = g.golden_supplier_id AND s.is_current)
WHERE g.golden_supplier_id > 0
  AND (SELECT count(DISTINCT s.supplier_id) FROM dds.dim_supplier s
       WHERE s.golden_supplier_id = g.golden_supplier_id) > 1;

-- Шаг 4.4. Атрибуты золотой записи по правилу модели: берётся класс
-- версии с более поздним valid_from среди слитых учётных записей.
UPDATE dds.dim_supplier_golden g
SET reliability_class = sub.reliability_class,
    golden_name       = sub.display_name
FROM (SELECT DISTINCT ON (s.golden_supplier_id)
             s.golden_supplier_id,
             s.reliability_class,
             regexp_replace(btrim(s.supplier_name), '\s+', ' ', 'g') AS display_name
      FROM dds.dim_supplier s
      WHERE s.is_current AND s.supplier_key > 0
      ORDER BY s.golden_supplier_id, s.valid_from DESC, s.supplier_key DESC) sub
WHERE sub.golden_supplier_id = g.golden_supplier_id
  AND g.golden_supplier_id > 0;

-- ---------------------------------------------------------------------
-- 5. Курсы валют: полный календарь, выходные закрываются протяжкой
--    последнего известного курса (LOCF). Строка RUB = 1.0 хранится,
--    чтобы ни ETL, ни витрины не содержали CASE по валюте.
-- ---------------------------------------------------------------------
INSERT INTO dds.ref_fx_rate_daily (rate_date, currency_code, rate_to_rub, rate_source)
SELECT c.d, cu.currency,
       (SELECT f.rate_to_rub FROM raw.fx_rates f
         WHERE f.currency = cu.currency AND f.rate_date <= c.d
         ORDER BY f.rate_date DESC LIMIT 1),
       CASE WHEN EXISTS (SELECT 1 FROM raw.fx_rates f
                          WHERE f.currency = cu.currency AND f.rate_date = c.d)
            THEN 'actual' ELSE 'carried_forward' END
FROM (SELECT d::date FROM generate_series(DATE '2024-01-01', DATE '2026-12-31', INTERVAL '1 day') d) c(d)
CROSS JOIN (SELECT DISTINCT currency FROM raw.fx_rates) cu;

INSERT INTO dds.ref_fx_rate_daily (rate_date, currency_code, rate_to_rub, rate_source)
SELECT d::date, 'RUB', 1.0, 'actual'
FROM generate_series(DATE '2024-01-01', DATE '2026-12-31', INTERVAL '1 day') d;

-- ---------------------------------------------------------------------
-- 6. ODS: история версий строк заказа.
--    Полные дубли строк схлопываются (их число уходит в src_dup_cnt),
--    действующая версия определяется по max(updated_at).
-- ---------------------------------------------------------------------
INSERT INTO ods.po_line_version (order_id, line_no, updated_at, item_id_src, qty, price, plan_price,
                                 uom_code_src, planned_delivery_date, status_src,
                                 is_current_version, src_dup_cnt, load_id)
WITH dedup AS (
    SELECT order_id, line_no, updated_at, item_id, qty, price, plan_price, uom_code,
           planned_delivery_date, status, count(*) AS src_dup_cnt
    FROM raw.po_lines
    GROUP BY 1,2,3,4,5,6,7,8,9,10)
SELECT order_id, line_no,
       updated_at AT TIME ZONE 'Europe/Moscow',   -- в источнике время московское
       item_id, qty, price, plan_price, uom_code, planned_delivery_date, status,
       updated_at = max(updated_at) OVER (PARTITION BY order_id, line_no),
       src_dup_cnt, 1
FROM dedup;

-- ---------------------------------------------------------------------
-- 7. Факт: действующая версия строки заказа.
--    Версия поставщика разрешается ЗДЕСЬ, один раз, по дате заказа —
--    в витринах джойн по диапазону дат запрещён (риск задвоения).
-- ---------------------------------------------------------------------
INSERT INTO dds.fact_po_line (
    order_id, line_no, supplier_key, item_key, uom_key, order_date_key, planned_delivery_date_key,
    order_dttm_msk, order_type, delivery_city, item_id_src, currency_code, qty, price, plan_price,
    fx_rate, fx_rate_date, fx_rate_source, amount_rub, base_uom_code, qty_base,
    is_cancelled, version_updated_at, version_cnt, is_item_unresolved, load_id)
SELECT v.order_id, v.line_no, s.supplier_key, i.item_key, u.uom_key,
       dd.date_key, dp.date_key,
       h.order_dttm_msk AT TIME ZONE 'Europe/Moscow',
       h.order_type, h.delivery_city, v.item_id_src, h.currency,
       v.qty, v.price, v.plan_price,
       fx.rate_to_rub, fx.rate_date, fx.rate_source,
       round(v.qty * v.price * fx.rate_to_rub, 4),
       u.base_uom_code,
       round(v.qty * u.factor_to_base, 4),
       v.status_src = 'cancelled',
       v.updated_at,
       cnt.version_cnt,
       i.is_unknown,
       1
FROM ods.po_line_version v
JOIN raw.po_headers h ON h.order_id = v.order_id
JOIN dds.dim_supplier s ON s.supplier_id = h.supplier_id
                       AND h.order_dttm_msk::date BETWEEN s.valid_from AND s.valid_to
JOIN dds.dim_item i ON i.item_id = v.item_id_src
JOIN dds.dim_uom  u ON u.uom_code = v.uom_code_src
JOIN dds.dim_date dd ON dd.date_actual = h.order_dttm_msk::date
JOIN dds.dim_date dp ON dp.date_actual = v.planned_delivery_date
JOIN dds.ref_fx_rate_daily fx ON fx.rate_date = h.order_dttm_msk::date
                             AND fx.currency_code = h.currency
JOIN (SELECT order_id, line_no, count(*)::smallint AS version_cnt
        FROM ods.po_line_version GROUP BY 1,2) cnt
     ON cnt.order_id = v.order_id AND cnt.line_no = v.line_no
WHERE v.is_current_version;

-- ---------------------------------------------------------------------
-- 8. Флаг подозрительного масштаба цен по валюте (02_model.md).
--    Правило, а не хардкод валюты: сравниваем медиану цены за базовую
--    единицу по валюте с рублёвой базой на одинаковых (позиция, базовая ед.);
--    отклонение более чем в 3 раза помечает всю валюту.
-- ---------------------------------------------------------------------
WITH med AS (
    SELECT currency_code, item_key, base_uom_code,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY price_per_base_uom_rub) AS p50
    FROM dds.fact_po_line GROUP BY 1,2,3),
ratio AS (
    SELECT c.currency_code,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY c.p50 / r.p50) AS ratio_to_rub,
           count(*) AS cmp_cnt
    FROM med c
    JOIN med r ON r.item_key = c.item_key AND r.base_uom_code = c.base_uom_code
              AND r.currency_code = 'RUB' AND r.p50 > 0
    WHERE c.currency_code <> 'RUB'
    GROUP BY 1)
UPDATE dds.fact_po_line f SET is_price_scale_suspect = true
FROM ratio WHERE ratio.currency_code = f.currency_code
             AND (ratio.ratio_to_rub > 3 OR ratio.ratio_to_rub < 1.0/3.0);

-- ---------------------------------------------------------------------
-- 9. ЭТАП 2: факт приёмки.
--    Таблица объявлена как точка расширения в 02_model.md и в
--    02_model_diagram.mmd; в DDL первого релиза её нет, но Q1 (OTIF)
--    без неё нерасчётен. Структура — ровно та, что заявлена в модели.
--    Допущение: qty_received выражено в той же единице измерения, что и
--    строка заказа (в receipts.csv колонки единицы нет).
-- ---------------------------------------------------------------------
CREATE TABLE dds.fact_receipt (
    receipt_key       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    receipt_id        text          NOT NULL,
    po_line_key       bigint        NOT NULL REFERENCES dds.fact_po_line,
    received_at_utc   timestamptz   NOT NULL,
    qty_received      numeric(18,3) NOT NULL,
    qty_received_base numeric(20,4) NOT NULL,
    quality_status    text          NOT NULL,
    warehouse_code    text,
    is_before_order   boolean       NOT NULL DEFAULT false,
    CONSTRAINT uq_fact_receipt UNIQUE (receipt_id),
    CONSTRAINT ck_receipt_status CHECK (quality_status IN ('accepted','partially_rejected','rejected')),
    CONSTRAINT ck_receipt_qty    CHECK (qty_received >= 0)
);

INSERT INTO dds.fact_receipt (receipt_id, po_line_key, received_at_utc, qty_received,
                              qty_received_base, quality_status, warehouse_code, is_before_order)
SELECT r.receipt_id, f.po_line_key, r.received_at_utc, r.qty_received,
       round(r.qty_received * u.factor_to_base, 4),
       r.quality_status, r.warehouse_code,
       -- дефект 8: приёмка раньше заказа, сравнение в единой зоне
       r.received_at_utc < f.order_dttm_msk
FROM raw.receipts r
JOIN dds.fact_po_line f ON f.order_id = r.order_id AND f.line_no = r.line_no
JOIN dds.dim_uom u ON u.uom_key = f.uom_key;

CREATE INDEX ix_receipt_line ON dds.fact_receipt (po_line_key);

-- ---------------------------------------------------------------------
-- 10. DQ-метрики загрузки
-- ---------------------------------------------------------------------
INSERT INTO dq.run_metric (load_id, layer, metric_code, metric_value, threshold, severity)
SELECT 1, 'ods', 'dup_line_key_pct',
       round(100.0 * (SELECT count(*) FROM raw.po_lines)
                   / (SELECT count(*) FROM dds.fact_po_line) - 100, 3), 5.0, 'warn'
UNION ALL
SELECT 1, 'dds', 'unknown_item_amount_pct',
       round(100.0 * sum(amount_rub) FILTER (WHERE is_item_unresolved) / sum(amount_rub), 3), 6.0, 'warn'
FROM dds.fact_po_line
UNION ALL
SELECT 1, 'dds', 'fx_carried_forward_amount_pct',
       round(100.0 * sum(amount_rub) FILTER (WHERE fx_rate_source = 'carried_forward') / sum(amount_rub), 3), NULL, 'info'
FROM dds.fact_po_line
UNION ALL
SELECT 1, 'dds', 'price_scale_suspect_lines_pct',
       round(100.0 * count(*) FILTER (WHERE is_price_scale_suspect) / count(*), 3), NULL, 'warn'
FROM dds.fact_po_line
UNION ALL
SELECT 1, 'dds', 'inn_with_many_golden_cnt',
       (SELECT count(*) FROM (SELECT inn FROM dds.dim_supplier_golden WHERE golden_supplier_id > 0
                              GROUP BY inn HAVING count(*) > 1) x), 0, 'warn';

-- ---------------------------------------------------------------------
-- 11. Витрины Блока 2
-- ---------------------------------------------------------------------
REFRESH MATERIALIZED VIEW mart.spend_monthly;
REFRESH MATERIALIZED VIEW mart.price_benchmark;
REFRESH MATERIALIZED VIEW mart.price_dynamics_quarter;

ANALYZE;
