-- =====================================================================
-- Q1. OTIF по поставщикам за последние 6 полных месяцев
--
-- ОПРЕДЕЛЕНИЕ OTIF (02_model.md, раздел 2.5, «Каноническое определение OTIF»):
--
--   OTIF — доля строк заказа, по которым поставка выполнена И В СРОК,
--   И В ПОЛНОМ ОБЪЁМЕ, среди всех действующих неотменённых строк,
--   плановая дата поставки которых попадает в отчётный период.
--
--   Зерно расчёта: одна действующая строка заказа (order_id, line_no).
--     Приёмка не может быть зерном: одна строка дробится на 1-3 события
--     приёмки, и подсчёт по событиям механически завышает метрику.
--   Период атрибуции: по ПЛАНОВОЙ дате поставки, а не по дате приёмки,
--     иначе задержанные поставки уезжают в следующий период.
--   On Time: max(дата приёмки в MSK) <= плановая дата + допуск_дней.
--   In Full: SUM(принято) в базовых единицах >= плановое количество
--            в базовых единицах x (1 - допуск_количества);
--            в принятое засчитывается только quality_status = 'accepted'.
--   Строка без единой приёмки после наступления плановой даты —
--     невыполненная: попадает в знаменатель, не попадает в числитель.
--   Отменённые строки исключаются из числителя и знаменателя одновременно.
--   Версия плана: версия строки, действовавшая на плановую дату поставки.
--   Часовая зона: всё приводится к MSK.
--
--   Параметры версии v1 (в модели вынесены в конфигурацию расчёта):
--     допуск по сроку = 0 дней, допуск по количеству = 0%.
--     Здесь заданы литералами в CTE params.
--
-- РАСХОЖДЕНИЕ МОДЕЛИ И ДАННЫХ, потребовавшее явного преобразования:
--   Поток приёмок в датасете обрывается 2026-08-12, тогда как плановые
--   даты доходят до 2026-09-26. Календарно полный август-2026 фактом
--   покрыт лишь наполовину: доля строк без единой приёмки прыгает с
--   базовых 5,6-8,2% в месяц до 58,5%. Поэтому граница периода берётся
--   не только по current_date, но и по водяному знаку полноты факта.
--   Определение метрики при этом НЕ меняется — меняется только окно,
--   на котором она вообще расчётна.
-- =====================================================================

WITH params AS (
    SELECT 0                AS tolerance_days,      -- допуск по сроку, дней
           0.0::numeric     AS tolerance_qty_pct,   -- допуск по количеству, доля
           20               AS min_lines_period     -- порог поставок за весь период
),
period AS (
    -- Граница окна учитывает два условия одновременно:
    --   1) текущий неполный календарный месяц не входит;
    --   2) месяц обязан быть полностью покрыт фактом приёмки.
    -- Берётся более ранняя из двух границ.
    SELECT month_end_excl,
           (month_end_excl - interval '6 month')::date AS period_start
    FROM (SELECT LEAST(date_trunc('month', current_date),
                       date_trunc('month', max(r.received_at_utc AT TIME ZONE 'Europe/Moscow'))
                 )::date AS month_end_excl
          FROM dds.fact_receipt r) x
),
plan_qty AS (
    -- Плановое количество берётся из версии строки, действовавшей на конец
    -- плановых суток: последняя версия может быть уменьшена задним числом
    -- и замаскировать недопоставку (802 строки датасета пересматривались
    -- по количеству, на 356 это меняет вердикт по In Full).
    -- Плановая дата между версиями не меняется — проверено на данных.
    SELECT v.order_id,
           v.line_no,
           COALESCE(
               (array_agg(v.qty ORDER BY v.updated_at DESC)
                  FILTER (WHERE v.updated_at
                                < ((v.planned_delivery_date + 1)::timestamp AT TIME ZONE 'Europe/Moscow'))
               )[1],
               (array_agg(v.qty ORDER BY v.updated_at))[1]   -- страховка: версий до плановой даты нет
           ) AS plan_qty
    FROM ods.po_line_version v
    GROUP BY v.order_id, v.line_no
),
line_scope AS (
    -- Единица оценки OTIF. Версия поставщика уже разрешена на загрузке,
    -- поэтому соединение идёт по равенству суррогата, а не по диапазону
    -- дат: диапазонный join размножил бы строку заказа.
    SELECT f.po_line_key,
           f.order_id,
           f.line_no,
           g.golden_supplier_id,
           g.golden_name,
           g.inn,
           g.reliability_class,
           g.has_attr_conflict,
           d.year_month_key,
           d.date_actual                          AS planned_date,
           round(p.plan_qty * u.factor_to_base, 4) AS plan_qty_base
    FROM dds.fact_po_line f
    JOIN dds.dim_supplier        s ON s.supplier_key = f.supplier_key
    JOIN dds.dim_supplier_golden g ON g.golden_supplier_id = s.golden_supplier_id
    JOIN dds.dim_date            d ON d.date_key = f.planned_delivery_date_key
    JOIN dds.dim_uom             u ON u.uom_key = f.uom_key
    JOIN plan_qty                p ON p.order_id = f.order_id AND p.line_no = f.line_no
    CROSS JOIN period pr
    WHERE NOT f.is_cancelled                       -- отменённые вне обеих частей метрики
      AND d.date_actual >= pr.period_start
      AND d.date_actual <  pr.month_end_excl
),
receipt_agg AS (
    -- Приёмки сворачиваются ДО строки заказа. Это ключевая защита от
    -- двойного учёта: 63 691 событие приёмки против 53 248 строк заказа,
    -- прямое соединение превратило бы одну опоздавшую строку в несколько
    -- «своевременных» событий.
    SELECT r.po_line_key,
           max((r.received_at_utc AT TIME ZONE 'Europe/Moscow')::date) AS last_received_date_msk,
           sum(r.qty_received_base) FILTER (WHERE r.quality_status = 'accepted') AS qty_accepted_base
    FROM dds.fact_receipt r
    JOIN line_scope l ON l.po_line_key = r.po_line_key
    GROUP BY r.po_line_key
),
otif_line AS (
    SELECT l.golden_supplier_id,
           l.golden_name,
           l.inn,
           l.reliability_class,
           l.has_attr_conflict,
           l.year_month_key,
           (ra.last_received_date_msk IS NOT NULL
            AND ra.last_received_date_msk <= l.planned_date + pa.tolerance_days) AS is_on_time,
           (COALESCE(ra.qty_accepted_base, 0)
            >= l.plan_qty_base * (1 - pa.tolerance_qty_pct))                     AS is_in_full
    FROM line_scope l
    CROSS JOIN params pa
    LEFT JOIN receipt_agg ra ON ra.po_line_key = l.po_line_key   -- строки без приёмок остаются
),
by_month AS (
    SELECT golden_supplier_id,
           year_month_key,
           count(*)                                                        AS lines_month,
           count(*) FILTER (WHERE is_on_time AND is_in_full)               AS lines_otif_month,
           round(100.0 * count(*) FILTER (WHERE is_on_time AND is_in_full) / count(*), 2) AS otif_month_pct,
           round(100.0 * count(*) FILTER (WHERE is_on_time)                / count(*), 2) AS on_time_month_pct,
           round(100.0 * count(*) FILTER (WHERE is_in_full)                / count(*), 2) AS in_full_month_pct
    FROM otif_line
    GROUP BY 1, 2
),
by_period AS (
    -- Порог >= 20 поставок проверяется ЗА ВЕСЬ ПЕРИОД, а не помесячно.
    SELECT golden_supplier_id,
           max(golden_name)                                                AS golden_name,
           max(inn)                                                        AS inn,
           max(reliability_class)                                          AS reliability_class,
           bool_or(has_attr_conflict)                                      AS has_attr_conflict,
           count(*)                                                        AS lines_period,
           round(100.0 * count(*) FILTER (WHERE is_on_time AND is_in_full) / count(*), 2) AS otif_period_pct,
           round(100.0 * count(*) FILTER (WHERE is_on_time)                / count(*), 2) AS on_time_period_pct,
           round(100.0 * count(*) FILTER (WHERE is_in_full)                / count(*), 2) AS in_full_period_pct
    FROM otif_line
    GROUP BY 1
    HAVING count(*) >= (SELECT min_lines_period FROM params)
),
ranked AS (
    -- Ранг считается внутри категории надёжности поставщика
    SELECT bp.*,
           rank()   OVER (PARTITION BY bp.reliability_class ORDER BY bp.otif_period_pct DESC) AS rank_in_class,
           count(*) OVER (PARTITION BY bp.reliability_class)                                  AS suppliers_in_class
    FROM by_period bp
)
SELECT r.golden_supplier_id,
       r.golden_name          AS supplier_name,
       r.inn,
       r.reliability_class,
       r.has_attr_conflict,
       m.year_month_key       AS year_month,
       m.lines_month,
       m.otif_month_pct,
       m.on_time_month_pct,
       m.in_full_month_pct,
       -- динамика месяц к месяцу внутри поставщика
       lag(m.otif_month_pct) OVER (PARTITION BY r.golden_supplier_id ORDER BY m.year_month_key)
                              AS otif_prev_month_pct,
       round(m.otif_month_pct
             - lag(m.otif_month_pct) OVER (PARTITION BY r.golden_supplier_id ORDER BY m.year_month_key), 2)
                              AS mom_delta_pp,
       r.lines_period,
       r.otif_period_pct,
       r.on_time_period_pct,
       r.in_full_period_pct,
       r.rank_in_class,
       r.suppliers_in_class
FROM ranked r
JOIN by_month m ON m.golden_supplier_id = r.golden_supplier_id
ORDER BY r.reliability_class, r.rank_in_class, r.golden_supplier_id, m.year_month_key;
