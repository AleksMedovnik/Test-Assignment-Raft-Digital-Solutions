#!/usr/bin/env python3
"""
Воспроизводимые проверки качества данных для датасета test_assignment/data.
Запуск:  python3 dq_checks.py [путь_к_папке_data]
Скрипт работает ТОЛЬКО НА ЧТЕНИЕ и ничего не изменяет в исходных файлах.
Зависимостей нет — используется стандартная библиотека.

Каждая функция check_N соответствует дефекту N из data_defects.md.
"""
import csv, os, sys, datetime as dt, statistics as st
from collections import Counter, defaultdict

D = sys.argv[1] if len(sys.argv) > 1 else 'data'

def load(name):
    with open(os.path.join(D, name), encoding='utf-8') as f:
        return list(csv.DictReader(f, delimiter=';'))

SUP, ITEMS, UOM = load('suppliers.csv'), load('items.csv'), load('uom.csv')
FX, POH, POL, REC = load('fx_rates.csv'), load('po_headers.csv'), load('po_lines.csv'), load('receipts.csv')

HDR  = {r['order_id']: r for r in POH}
ITM  = {r['item_id']: r for r in ITEMS}
UF   = {r['uom_code']: float(r['factor_to_base']) for r in UOM}   # коэффициент к базовой единице
UB   = {r['uom_code']: r['base_uom'] for r in UOM}                # базовая единица
RATE = {(r['rate_date'], r['currency']): float(r['rate_to_rub']) for r in FX}

# Последняя версия строки заказа: ключ (order_id, line_no), выбор по max(updated_at)
LAST, VERSIONS = {}, defaultdict(list)
for r in POL:
    k = (r['order_id'], r['line_no'])
    VERSIONS[k].append(r)
    if k not in LAST or r['updated_at'] > LAST[k]['updated_at']:
        LAST[k] = r

REC_BY_LINE = defaultdict(list)
for r in REC:
    REC_BY_LINE[(r['order_id'], r['line_no'])].append(r)

def rate_ffill(day, cur, max_back=10):
    """Курс на дату; при отсутствии — протяжка последнего известного (LOCF)."""
    if cur == 'RUB':
        return 1.0
    d0 = dt.date.fromisoformat(day)
    for i in range(max_back):
        k = ((d0 - dt.timedelta(days=i)).isoformat(), cur)
        if k in RATE:
            return RATE[k]
    return None

def amount_rub(line):
    h = HDR[line['order_id']]
    rt = rate_ffill(h['order_dttm_msk'][:10], h['currency']) or 0
    return float(line['qty']) * float(line['price']) * rt

def utc_to_msk(s):
    return dt.datetime.strptime(s, '%Y-%m-%dT%H:%M:%SZ') + dt.timedelta(hours=3)


def check_1_duplicate_and_versioned_lines():
    """Дефект 1. Дубли и неразрешённые версии строк заказа в po_lines."""
    groups = {k: v for k, v in VERSIONS.items() if len(v) > 1}
    exact = sum(1 for v in groups.values() if len({tuple(r.items()) for r in v}) == 1)
    naive = sum(float(r['qty']) * float(r['price']) for r in POL)
    dedup = sum(float(r['qty']) * float(r['price']) for r in LAST.values())
    # ложная перепоставка как следствие: получено > qty последней версии, но <= max по версиям
    recv = {k: sum(float(x['qty_received']) for x in v) for k, v in REC_BY_LINE.items()}
    over_last = [k for k, q in recv.items() if k in LAST and q > float(LAST[k]['qty']) * 1.0001]
    over_max  = [k for k, q in recv.items() if k in LAST and q > max(float(x['qty']) for x in VERSIONS[k]) * 1.0001]
    return {'групп с дублем ключа': len(groups),
            'из них полные дубли строк': exact,
            'из них версии (отличаются qty/price/updated_at)': len(groups) - exact,
            'лишних строк всего': sum(len(v) - 1 for v in groups.values()),
            'завышение суммы qty*price, %': round(100 * (naive / dedup - 1), 2),
            'ложная перепоставка (получено > последней версии)': len(over_last),
            'реальная перепоставка (получено > максимума версий)': len(over_max)}


def check_2_uom_inconsistency():
    """Дефект 2. Единицы измерения строки заказа не согласованы со справочником номенклатуры."""
    mism = [r for r in LAST.values() if r['item_id'] in ITM and r['uom_code'] != ITM[r['item_id']]['uom_code']]
    bases = defaultdict(set)
    for r in LAST.values():
        bases[r['item_id']].add(UB[r['uom_code']])
    multi = {k: v for k, v in bases.items() if len(v) > 1}
    worst = []
    by_item = defaultdict(list)
    for r in LAST.values():
        by_item[r['item_id']].append(r)
    for iid, rows in by_item.items():
        naive = sum(float(r['price']) for r in rows) / len(rows)
        norm  = sum(float(r['price']) / UF[r['uom_code']] for r in rows) / len(rows)
        worst.append((iid, naive / norm))
    worst.sort(key=lambda x: -x[1])
    return {'строк с uom != uom номенклатуры': len(mism),
            'доля от строк, %': round(100 * len(mism) / len(LAST), 1),
            'номенклатур в несовместимых базовых ед. (шт/кг/м)': len(multi),
            'всего номенклатур в заказах': len(bases),
            'макс. искажение средней цены (наивная/нормализованная)': round(worst[0][1], 1)}


def check_3_supplier_duplicates():
    """Дефект 3. Дубли поставщиков по ИНН и история, начинающаяся позже первых заказов."""
    inn2ids = defaultdict(set)
    for r in SUP:
        inn2ids[r['inn']].add(r['supplier_id'])
    dup = {k: v for k, v in inn2ids.items() if len(v) > 1}
    dup_ids = {i for v in dup.values() for i in v}
    amt, by_inn = defaultdict(float), defaultdict(float)
    sid2inn = {r['supplier_id']: r['inn'] for r in SUP}
    for r in LAST.values():
        if r['status'] == 'cancelled':
            continue
        s = HDR[r['order_id']]['supplier_id']
        a = amount_rub(r)
        amt[s] += a
        by_inn[sid2inn[s]] += a
    top_raw = [s for s, _ in sorted(amt.items(), key=lambda x: -x[1])[:5]]
    top_mrg = [i for i, _ in sorted(by_inn.items(), key=lambda x: -x[1])[:5]]
    # заказы вне периода действия любой версии поставщика
    by_sup = defaultdict(list)
    for r in SUP:
        by_sup[r['supplier_id']].append(r)
    nocover = sum(1 for r in POH
                  if not any(s['valid_from'] <= r['order_dttm_msk'][:10] <= s['valid_to']
                             for s in by_sup[r['supplier_id']]))
    conflict = sum(1 for ids in dup.values()
                   if len({r['reliability_class'] for r in SUP
                           if r['supplier_id'] in ids and r['is_current'] == '1'}) > 1)
    return {'ИНН с несколькими supplier_id': len(dup),
            'затронуто supplier_id': len(dup_ids),
            'доля в обороте, %': round(100 * sum(amt[i] for i in dup_ids) / sum(amt.values()), 1),
            'дублей в ТОП-5 сырого рейтинга': sum(1 for s in top_raw if s in dup_ids),
            'дублей в ТОП-5 после склейки по ИНН': sum(1 for i in top_mrg if len(inn2ids[i]) > 1),
            'заказов вне периода действия версии поставщика': nocover,
            'пар с противоречивым reliability_class': conflict,
            'наименований с хвостовыми пробелами': sum(1 for r in SUP if r['supplier_name'] != r['supplier_name'].strip())}


def check_4_cny_price_scale():
    """Дефект 4. Цены в CNY несопоставимы по масштабу с RUB/USD после конвертации."""
    grp = defaultdict(lambda: defaultdict(list))
    for r in LAST.values():
        h = HDR[r['order_id']]
        rt = rate_ffill(h['order_dttm_msk'][:10], h['currency'])
        if rt is None:
            continue
        grp[(r['item_id'], r['uom_code'])][h['currency']].append(float(r['price']) * rt)
    ratios = {'USD': [], 'CNY': []}
    for d in grp.values():
        if len(d['RUB']) >= 2:
            base = st.median(d['RUB'])
            for c in ('USD', 'CNY'):
                if d[c]:
                    ratios[c].append(st.median(d[c]) / base)
    cheapest_cny = tot = 0
    for d in grp.values():
        if len([c for c in d if d[c]]) > 1:
            tot += 1
            if min((min(v), c) for c, v in d.items() if v)[1] == 'CNY':
                cheapest_cny += 1
    return {'медиана CNY/RUB по одинаковым (номенклатура, ед.изм.)': round(st.median(ratios['CNY']), 3),
            'медиана USD/RUB (контроль)': round(st.median(ratios['USD']), 3),
            'сравнений CNY': len(ratios['CNY']),
            'пар с закупками в разных валютах': tot,
            'из них минимальная цена у CNY': cheapest_cny,
            'доля, %': round(100 * cheapest_cny / tot, 1)}


def check_5_unknown_items():
    """Дефект 5. Строки заказа ссылаются на отсутствующую в справочнике номенклатуру."""
    unk = [r for r in LAST.values() if r['item_id'] not in ITM]
    tot = sum(amount_rub(r) for r in LAST.values())
    return {'строк с неизвестным item_id': len(unk),
            'доля строк, %': round(100 * len(unk) / len(LAST), 1),
            'уникальных отсутствующих item_id': len({r['item_id'] for r in unk}),
            'оборот, млрд руб': round(sum(amount_rub(r) for r in unk) / 1e9, 2),
            'доля оборота, %': round(100 * sum(amount_rub(r) for r in unk) / tot, 1)}


def check_6_receipts_on_cancelled():
    """Дефект 6. Приёмки по отменённым строкам заказа."""
    canc = {k: r for k, r in LAST.items() if r['status'] == 'cancelled'}
    before = after = 0
    for k, rows in REC_BY_LINE.items():
        if k in canc:
            u = dt.datetime.fromisoformat(canc[k]['updated_at'])
            for r in rows:
                if utc_to_msk(r['received_at_utc']) < u:
                    before += 1
                else:
                    after += 1
    qc = sum(float(r['qty_received']) for k, v in REC_BY_LINE.items() if k in canc for r in v)
    qt = sum(float(r['qty_received']) for r in REC)
    amt_c = sum(amount_rub(r) for r in canc.values())
    amt_t = sum(amount_rub(r) for r in LAST.values())
    return {'отменённых строк': len(canc),
            'из них с приёмками': len([k for k in canc if k in REC_BY_LINE]),
            'приёмок всего': before + after,
            'приёмок ПОСЛЕ отметки об отмене': after,
            'доля в полученном количестве, %': round(100 * qc / qt, 2),
            'оборот отменённых строк, % от общего': round(100 * amt_c / amt_t, 2)}


def check_7_fx_gaps():
    """Дефект 7. В справочнике курсов отсутствуют выходные дни."""
    days = sorted({r['rate_date'] for r in FX})
    d0, d1 = dt.date.fromisoformat(days[0]), dt.date.fromisoformat(days[-1])
    alld = {(d0 + dt.timedelta(days=i)).isoformat() for i in range((d1 - d0).days + 1)}
    missing = sorted(alld - set(days))
    no_rate = [r for r in POH if r['currency'] != 'RUB'
               and (r['order_dttm_msk'][:10], r['currency']) not in RATE]
    lines = [r for r in LAST.values()
             if HDR[r['order_id']]['currency'] != 'RUB'
             and (HDR[r['order_id']]['order_dttm_msk'][:10], HDR[r['order_id']]['currency']) not in RATE]
    lost = sum(amount_rub(r) for r in lines)
    tot = sum(amount_rub(r) for r in LAST.values())
    return {'календарных дней в периоде': len(alld),
            'дат с курсом': len(days),
            'отсутствует дат': len(missing),
            'из них суббот и воскресений': sum(1 for d in missing
                                               if dt.date.fromisoformat(d).weekday() >= 5),
            'валютных заказов без курса на дату': len(no_rate),
            'строк заказа без курса': len(lines),
            'потеря оборота при inner join, %': round(100 * lost / tot, 2)}


def check_8_receipt_before_order():
    """Дефект 8. Приёмка датирована раньше заказа (сравнение в единой зоне MSK)."""
    gaps = []
    for r in REC:
        o = dt.datetime.fromisoformat(HDR[r['order_id']]['order_dttm_msk'])
        rc = utc_to_msk(r['received_at_utc'])
        if rc < o:
            gaps.append((o - rc).total_seconds() / 3600)
    gaps.sort()
    return {'приёмок раньше заказа': len(gaps),
            'доля от всех приёмок, %': round(100 * len(gaps) / len(REC), 2),
            'медиана опережения, ч': round(gaps[len(gaps) // 2], 1),
            'максимум, ч': round(gaps[-1], 1),
            'из них меньше 3 ч (объяснимо смещением зоны)': sum(1 for g in gaps if g < 3)}


def check_9_timezone_otif():
    """Дефект 9. Смешение UTC и MSK меняет вердикт «в срок» на границе суток."""
    flip = late_utc = late_msk = tot = 0
    for r in REC:
        k = (r['order_id'], r['line_no'])
        if k not in LAST:
            continue
        pdd = dt.date.fromisoformat(LAST[k]['planned_delivery_date'])
        u = dt.datetime.strptime(r['received_at_utc'], '%Y-%m-%dT%H:%M:%SZ')
        tot += 1
        lu, lm = u.date() > pdd, (u + dt.timedelta(hours=3)).date() > pdd
        late_utc += lu
        late_msk += lm
        flip += (lu != lm)
    return {'приёмок сопоставлено': tot,
            'опозданий при трактовке как UTC, %': round(100 * late_utc / tot, 2),
            'опозданий при переводе в MSK, %': round(100 * late_msk / tot, 2),
            'приёмок с меняющимся вердиктом': flip,
            'сдвиг OTIF, п.п.': round(100 * abs(late_msk - late_utc) / tot, 2)}


def check_10_two_category_columns():
    """Дефект 10. Две конкурирующие колонки категории в справочнике номенклатуры."""
    mism = {r['item_id'] for r in ITEMS if r['category'] != r['category_reported']}
    a, b = defaultdict(float), defaultdict(float)
    moved = 0.0
    for r in LAST.values():
        if r['item_id'] in ITM and r['status'] != 'cancelled':
            v = amount_rub(r)
            a[ITM[r['item_id']]['category']] += v
            b[ITM[r['item_id']]['category_reported']] += v
            if r['item_id'] in mism:
                moved += v
    ra = [k for k, _ in sorted(a.items(), key=lambda x: -x[1])]
    rb = [k for k, _ in sorted(b.items(), key=lambda x: -x[1])]
    shift = max(((b.get(k, 0) - a[k]) / a[k] for k in a), key=abs)
    return {'номенклатур с расхождением категорий': len(mism),
            'доля от справочника, %': round(100 * len(mism) / len(ITEMS), 1),
            'оборот, переезжающий между категориями, %': round(100 * moved / sum(a.values()), 2),
            'макс. сдвиг категории, %': round(100 * shift, 1),
            'ТОП-3 категорий совпадает': ra[:3] == rb[:3],
            'ТОП-3 по category': ra[:3],
            'ТОП-3 по category_reported': rb[:3]}


def reconciliation():
    """Сводная сверка оборота: наивный расчёт против последовательно очищенного."""
    naive = sum(amount_rub(r) for r in POL)
    s1 = sum(amount_rub(r) for r in LAST.values())
    s2 = sum(amount_rub(r) for r in LAST.values() if r['status'] != 'cancelled')
    s3 = sum(amount_rub(r) for r in LAST.values() if r['status'] != 'cancelled' and r['item_id'] in ITM)
    return {'наивно, млрд': round(naive / 1e9, 3),
            'после дедупликации и выбора версии, млрд': round(s1 / 1e9, 3),
            'без отменённых строк, млрд': round(s2 / 1e9, 3),
            'только известная номенклатура, млрд': round(s3 / 1e9, 3),
            'разрыв наивный/очищенный, %': round(100 * (naive / s3 - 1), 2)}


if __name__ == '__main__':
    checks = [check_1_duplicate_and_versioned_lines, check_2_uom_inconsistency,
              check_3_supplier_duplicates, check_4_cny_price_scale, check_5_unknown_items,
              check_6_receipts_on_cancelled, check_7_fx_gaps, check_8_receipt_before_order,
              check_9_timezone_otif, check_10_two_category_columns]
    print(f"Датасет: {os.path.abspath(D)}")
    print(f"Строк загружено: suppliers={len(SUP)} items={len(ITEMS)} uom={len(UOM)} "
          f"fx_rates={len(FX)} po_headers={len(POH)} po_lines={len(POL)} receipts={len(REC)}\n")
    for fn in checks:
        print(f"--- {fn.__doc__.strip().splitlines()[0]}")
        for k, v in fn().items():
            print(f"      {k}: {v}")
        print()
    print("--- Сводная сверка оборота")
    for k, v in reconciliation().items():
        print(f"      {k}: {v}")
