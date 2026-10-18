#!/usr/bin/env python3
import json, urllib.request, urllib.parse
UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36"
def get(url, n=1200, data=None, headers=None, quiet=False):
    h = {"User-Agent": UA, "Accept": "*/*"}
    if headers: h.update(headers)
    try:
        with urllib.request.urlopen(urllib.request.Request(url, data=data, headers=h), timeout=25) as r:
            b = r.read().decode("utf-8", "replace")
            if not quiet: print(f"\n### {r.status} {url} ({len(b)} B)\n{b[:n]}")
            return b
    except urllib.error.HTTPError as e:
        b = e.read().decode("utf-8", "replace"); print(f"\n### HTTP {e.code} {url}\n{b[:400]}")
    except Exception as e:
        print(f"\n### ERR {url} {e!r}")
def sec(s): print("\n\n================ " + s + " ================")

sec("FT search")
for q in ["CA13321L1085", "Cameco", "Paladin Energy", "Kazatomprom", "Ericsson", "TotalEnergies", "Eni", "Equinor", "Nestle", "NexGen Energy", "Skyharbour", "Toyota", "Denison Mines", "Yellow Cake", "Energy Fuels"]:
    b = get("https://markets.ft.com/data/searchapi/searchsecurities?" + urllib.parse.urlencode({"query": q}), quiet=True)
    if b:
        for s in json.loads(b)["data"]["security"][:12]:
            print(f"   {q:16} {s['symbol']:18} xid={s['xid']:10} {s.get('assetClass')} prim={s.get('isPrimary')} {s['name']}")
sec("FT chart")
for xid in ["27182"]:
    body = json.dumps({"days": 400, "dataNormalized": False, "dataPeriod": "Day", "dataInterval": 1, "realtime": False, "yFormat": "0.###", "timeServiceFormat": "JSON", "returnDateType": "ISO8601", "elements": [{"Type": "price", "Symbol": xid, "OverlayIndicators": [], "Params": {}}]}).encode()
    b = get("https://markets.ft.com/data/chartapi/series", 600, data=body, headers={"Content-Type": "application/json"})
    if b:
        j = json.loads(b); print("keys", list(j.keys())); print("dates", j.get("Dates", [])[:3], j.get("Dates", [])[-2:], len(j.get("Dates", [])))
        for el in j.get("Elements", []):
            print("el", el.get("Type"), el.get("Symbol"), el.get("Currency"), el.get("Label"), [(c.get("Type"), c.get("Values", [])[-3:]) for c in el.get("ComponentSeries", [])])
get("https://markets.ft.com/data/equities/tearsheet/summary?s=7203:TYO", 0, quiet=True) and print("tearsheet ok")
sec("CNBC")
get("https://ts-api.cnbc.com/harmony/app/bars/CCO-CA/1D/20250101000000/20261017000000/adjusted/EST5EDT.json", 700)
get("https://quote.cnbc.com/quote-html-webservice/restQuote/symbolType/symbol?symbols=7203-JP%7C7203-TK%7CTM&requestMethod=itv&noform=1&partnerId=2&fund=1&exthrs=1&output=json", 500)
sec("ONVISTA more")
for path in ["eod_history?idNotation=163500&range=Y1", "eod_history?idNotation=163500&range=Y5&startDate=2024-01-01"]:
    b = get("https://api.onvista.de/api/v1/instruments/STOCK/82849/" + path, 0, quiet=True)
    if b:
        j = json.loads(b); print(path, {k: (len(v) if isinstance(v, list) else v) for k, v in j.items() if k not in ("market",)})
b = get("https://api.onvista.de/api/v1/instruments/search/facet?searchValue=Cameco", 0, quiet=True)
for f in json.loads(b)["facets"]:
    for r in (f.get("results") or []): print("  ", f["type"], r.get("entityValue"), r.get("name"), r.get("isin"), r.get("symbol"))
b = get("https://api.onvista.de/api/v1/instruments/search/facet?searchValue=Bitcoin", 0, quiet=True)
for f in json.loads(b)["facets"]:
    for r in (f.get("results") or [])[:3]: print("  ", f["type"], r.get("entityValue"), r.get("name"), r.get("isin"), r.get("symbol"))
sec("LS-TC")
get("https://www.ls-tc.de/_rpc/json/instrument/chart/dataForInstrument?container=chart1&instrumentId=34313&marketId=1&quotetype=mid&series=intraday&type=mini&localeId=2", 400)
sec("TwelveData keyless reference")
get("https://api.twelvedata.com/symbol_search?symbol=JP3633400001", 800)
get("https://api.twelvedata.com/exchanges?type=stock", 600)
