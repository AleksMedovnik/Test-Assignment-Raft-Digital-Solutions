-- =====================================================================
-- Q3. Концентрация поставщиков по категориям.
--
-- Для каждой категории: оборот поставщика, его доля в обороте категории,
-- накопительная доля по убыванию оборота и количество поставщиков,
-- которые суммарно дают 80% оборота категории.
--
-- Правила из 02_model.md:
--   * Оборот = SUM(amount_rub) по действующим НЕотменённым строкам
--     (отменённые — 5,88% оборота, по умолчанию из метрик исключаются).
--   * Поставщик = ЗОЛОТАЯ запись. 8 пар учётных записей с одинаковым
--     ИНН — это одно юрлицо; без склейки ТОП-5 рейтинга неверен целиком
--     (в сыром виде туда не попадает ни один из дублированных, после
--     склейки они занимают все пять мест).
--   * Категория = category_master. Позиции, отсутствующие в справочнике
--     номенклатуры, загружены как late-arriving и образуют honest-строку
--     «Не определена» (5,1% оборота) — она видна в результате, а не
--     теряется молча.
--   * Соединение с dim_supplier идёт ПО РАВЕНСТВУ СУРРОГАТА версии.
--     Это и есть защита от задвоения: в справочнике 143 версии на 128
--     учётных записей, и соединение по supplier_id вместо supplier_key
--     размножило бы строки факта по числу версий поставщика.
--
-- Период: весь доступный горизонт данных. В постановке период не задан;
-- при необходимости он ограничивается фильтром по dim_date в CTE base.
-- =====================================================================

WITH base AS (
    -- Одна строка = категория x золотой поставщик. Свёртка выполняется
    -- ДО оконных функций, поэтому поставщик не может попасть в категорию
    -- дважды даже при нескольких версиях в SCD2.
    SELECT i.category_master                AS category,
           g.golden_supplier_id,
           g.golden_name                    AS supplier_name,
           g.inn,
           g.reliability_class,
           sum(f.amount_rub)                AS supplier_amount_rub,
           count(*)                         AS lines_cnt
    FROM dds.fact_po_line f
    JOIN dds.dim_supplier        s ON s.supplier_key = f.supplier_key
    JOIN dds.dim_supplier_golden g ON g.golden_supplier_id = s.golden_supplier_id
    JOIN dds.dim_item            i ON i.item_key = f.item_key
    WHERE NOT f.is_cancelled
    GROUP BY 1, 2, 3, 4, 5
),
ranked AS (
    -- Все расчёты partitioned по категории; сортировка по убыванию
    -- оборота, tie-break по идентификатору для детерминированности.
    SELECT b.*,
           sum(b.supplier_amount_rub) OVER (PARTITION BY b.category) AS category_amount_rub,
           count(*)                   OVER (PARTITION BY b.category) AS suppliers_in_category,
           row_number() OVER (PARTITION BY b.category
                              ORDER BY b.supplier_amount_rub DESC, b.golden_supplier_id) AS rank_in_category,
           sum(b.supplier_amount_rub) OVER (PARTITION BY b.category
                                            ORDER BY b.supplier_amount_rub DESC, b.golden_supplier_id
                                            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
                                                                     AS cum_amount_rub
    FROM base b
),
shares AS (
    SELECT r.*,
           round(100.0 * r.supplier_amount_rub / r.category_amount_rub, 4) AS share_pct,
           round(100.0 * r.cum_amount_rub      / r.category_amount_rub, 4) AS cum_share_pct
    FROM ranked r
),
pareto AS (
    -- Минимальное число поставщиков, чья накопительная доля впервые
    -- достигает 80%. Именно min(rank) при cum_share >= 80, а не
    -- count(*) при cum_share <= 80: иначе поставщик, пересекающий
    -- границу, не был бы учтён и ответ занижался бы на единицу.
    SELECT category,
           min(rank_in_category) FILTER (WHERE cum_share_pct >= 80.0) AS suppliers_for_80pct
    FROM shares
    GROUP BY category
)
SELECT s.category,
       s.rank_in_category,
       s.supplier_name,
       s.inn,
       s.reliability_class,
       round(s.supplier_amount_rub, 2) AS supplier_amount_rub,
       s.lines_cnt,
       s.share_pct,
       s.cum_share_pct,
       round(s.category_amount_rub, 2) AS category_amount_rub,
       s.suppliers_in_category,
       p.suppliers_for_80pct,
       round(100.0 * p.suppliers_for_80pct / s.suppliers_in_category, 1) AS pct_of_suppliers_for_80pct
FROM shares s
JOIN pareto p ON p.category = s.category
ORDER BY s.category, s.rank_in_category;
