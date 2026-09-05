-- =====================================================================
-- Q2. Ценовые аномалии за последний полный квартал.
--
-- Топ-15 позиций, где наша средневзвешенная цена за базовую единицу
-- отклоняется более чем на 15% от медианной цены той же позиции
-- у других поставщиков. Все суммы в рублях.
--
-- Правила из 02_model.md, которые здесь применяются:
--   * Цена за базовую единицу: SUM(amount_rub) / SUM(qty_base).
--     Именно средневзвешенная по количеству, а НЕ AVG(price): цена
--     не аддитивна, простое среднее по строкам даёт ошибку до 8 раз.
--   * Нормализация единиц: qty_base = qty x factor_to_base, а базовая
--     единица (шт/кг/м) входит в зерно сравнения. Это структурная
--     гарантия того, что цена за килограмм не сравнится с ценой за штуку:
--     в датасете все 800 позиций закупаются в трёх несводимых базовых
--     единицах, поэтому сравнение без этого разреза бессмысленно.
--   * Конвертация валют: курс зафиксирован в строке факта на загрузке
--     (курс на дату размещения заказа, выходные закрыты протяжкой
--     последнего известного курса). Здесь никакой конвертации уже
--     не происходит — берётся amount_rub.
--   * is_price_scale_suspect: строки в валюте с подтверждённым дефектом
--     масштаба цен (в датасете это CNY, цена после конвертации в 7 раз
--     ниже рублёвого аналога) исключаются из сравнения цен. Без этого
--     29,5% позиций получили бы «самого дешёвого поставщика» из артефакта.
--   * Отменённые строки исключаются.
--
-- РАСХОЖДЕНИЕ МОДЕЛИ И ДАННЫХ, потребовавшее явного преобразования:
--   Модель Блока 2 предполагает, что цена строки выражена за указанную
--   в ней единицу, и поэтому сравнивает цены внутри БАЗОВОЙ единицы.
--   В датасете это не выполняется: медианная цена строки составляет
--   ~20 000 руб при ЛЮБОМ коэффициенте единицы (KG=1, PACK6=6,
--   PACK24=24, ROLL50=50, TON=1000), то есть цена не масштабируется
--   вместе с упаковкой. Деление на factor_to_base в этих данных
--   разносит цену внутри одной базовой единицы в 1000 раз (KG против
--   TON: 20 281 против 20,16 руб/кг) и порождает отклонения в миллионы
--   процентов, отражающие упаковку, а не переплату.
--   Поэтому группа сравнения сужена с (позиция, базовая единица) до
--   (позиция, КОД единицы): сравниваются закупки в одинаковой упаковке.
--   Отображаемая цена остаётся ценой за базовую единицу, как требует
--   задание, — внутри группы это деление на константу и на сравнение
--   не влияет. Определение метрики не изменено: сужен только периметр
--   сопоставимости. В квартале это оставляет 1 036 групп сравнения
--   с двумя и более поставщиками — выборки достаточно.
--   Следствие для Блока 2: витрина mart.price_benchmark сгруппирована
--   по base_uom_code и на этих данных подвержена тому же артефакту —
--   зафиксировано в 03_sql/EXECUTION_NOTES.md как правка к следующей
--   ревизии модели (документы Блока 2 в этой задаче не изменяются).
--
-- ЧТО ЭТО ЗНАЧИТ ДЛЯ ИНТЕРПРЕТАЦИИ РЕЗУЛЬТАТА:
--   Запрос корректен, но в этом датасете цена сгенерирована независимо
--   от позиции: коэффициент вариации цены ВНУТРИ группы (позиция,
--   единица) равен 0,543 при глобальном 0,576, средний размах max/min
--   внутри группы — 25,6 раза; plan_price ведёт себя так же (CV 0,551,
--   все значения уникальны), то есть эталонной цены позиции в данных
--   тоже нет. Поэтому получаемый Топ-15 — это хвост случайного
--   распределения, а не свидетельство переплаты. На реальных данных
--   1С:УТ тот же запрос даёт содержательный результат.
--   * Поставщик берётся как ЗОЛОТАЯ запись: 8 пар учётных записей с
--     одним ИНН — это одно юрлицо, иначе оно попадёт в «других
--     поставщиков» само к себе.
-- =====================================================================

WITH params AS (
    SELECT 15.0::numeric AS min_abs_deviation_pct,  -- порог аномалии
           15            AS top_n,                  -- размер выборки
           1             AS min_other_suppliers     -- минимум «других» для медианы;
                                                    -- 1 = без доп. фильтра, как в постановке
),
quarter AS (
    -- Последний ПОЛНЫЙ квартал: текущий незавершённый не берётся.
    -- Поток заказов покрывает его целиком (max дата заказа — 2026-08-12),
    -- поэтому поправка на полноту факта, нужная в Q1, здесь не требуется.
    SELECT (date_trunc('quarter', current_date) - interval '3 month')::date AS q_start,
            date_trunc('quarter', current_date)::date                       AS q_end_excl
),
supplier_price AS (
    -- Зерно: позиция x код единицы измерения x золотой поставщик за квартал.
    -- Соединение с измерением поставщика идёт по равенству суррогата
    -- версии, поэтому SCD2-история не размножает строки факта.
    SELECT f.item_key,
           i.item_id,
           i.item_name,
           i.category_master,
           i.has_uom_conflict,
           f.uom_key,
           u.uom_code,
           f.base_uom_code,
           g.golden_supplier_id,
           g.golden_name,
           sum(f.qty_base)   AS qty_base,
           sum(f.amount_rub) AS amount_rub,
           sum(f.amount_rub) / sum(f.qty_base) AS wavg_price_per_base_uom
    FROM dds.fact_po_line f
    JOIN dds.dim_supplier        s ON s.supplier_key = f.supplier_key
    JOIN dds.dim_supplier_golden g ON g.golden_supplier_id = s.golden_supplier_id
    JOIN dds.dim_item            i ON i.item_key = f.item_key
    JOIN dds.dim_uom             u ON u.uom_key  = f.uom_key
    JOIN dds.dim_date            d ON d.date_key = f.order_date_key
    CROSS JOIN quarter q
    WHERE NOT f.is_cancelled
      AND NOT f.is_price_scale_suspect
      AND d.date_actual >= q.q_start
      AND d.date_actual <  q.q_end_excl
    GROUP BY 1, 2, 3, 4, 5, 6, 7, 8, 9, 10
),
median_others AS (
    -- Медиана по ДРУГИМ поставщикам: сам поставщик исключён условием
    -- соединения b.golden_supplier_id <> a.golden_supplier_id.
    -- Оконной функции здесь недостаточно — percentile_cont не умеет
    -- исключать текущую строку из своего окна, поэтому самосоединение.
    SELECT a.item_key,
           a.uom_key,
           a.golden_supplier_id,
           -- percentile_cont возвращает double precision, приводим к numeric
           percentile_cont(0.5) WITHIN GROUP (ORDER BY b.wavg_price_per_base_uom)::numeric AS median_other_price,
           count(*)                                                               AS other_suppliers_cnt
    FROM supplier_price a
    JOIN supplier_price b
      ON  b.item_key           = a.item_key
      AND b.uom_key            = a.uom_key       -- одинаковая упаковка, см. шапку
      AND b.golden_supplier_id <> a.golden_supplier_id
    GROUP BY 1, 2, 3
),
scored AS (
    SELECT sp.item_id,
           sp.item_name,
           sp.category_master,
           sp.has_uom_conflict,
           sp.uom_code,
           sp.base_uom_code,
           sp.golden_name,
           round(sp.wavg_price_per_base_uom, 2) AS our_wavg_price_rub,
           round(mo.median_other_price, 2)      AS median_other_price_rub,
           round(100.0 * (sp.wavg_price_per_base_uom - mo.median_other_price)
                       / mo.median_other_price, 2) AS deviation_pct,
           round(sp.amount_rub, 2)              AS purchase_amount_rub,
           round(sp.qty_base, 3)                AS qty_base,
           mo.other_suppliers_cnt,
           -- денежное выражение отклонения: во что обходится разница с медианой
           round((sp.wavg_price_per_base_uom - mo.median_other_price) * sp.qty_base, 2)
                                                AS deviation_amount_rub
    FROM supplier_price sp
    JOIN median_others mo
      ON  mo.item_key           = sp.item_key
      AND mo.uom_key            = sp.uom_key
      AND mo.golden_supplier_id = sp.golden_supplier_id
    CROSS JOIN params p
    WHERE mo.median_other_price > 0
      AND mo.other_suppliers_cnt >= p.min_other_suppliers
)
-- Top-15 отбирается ПОСЛЕ применения бизнес-фильтра по отклонению
SELECT s.item_id,
       s.item_name,
       s.category_master AS category,
       s.uom_code,
       s.base_uom_code,
       s.golden_name     AS supplier,
       s.our_wavg_price_rub,
       s.median_other_price_rub,
       s.deviation_pct,
       s.purchase_amount_rub,
       s.deviation_amount_rub,
       s.other_suppliers_cnt,
       s.has_uom_conflict   -- закупки позиции раздроблены между базовыми единицами
FROM scored s
CROSS JOIN params p
WHERE abs(s.deviation_pct) > p.min_abs_deviation_pct
ORDER BY abs(s.deviation_pct) DESC, s.purchase_amount_rub DESC
LIMIT (SELECT top_n FROM params);
