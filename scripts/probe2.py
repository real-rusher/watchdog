#!/usr/bin/env python3
import json, sys, urllib.request, urllib.parse, time, http.cookiejar, re
UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36"
cj = http.cookiejar.CookieJar()
op = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cj))
def get(url, n=1500, data=None, headers=None, quiet=False):
    h = {"User-Agent": UA, "Accept": "*/*", "Accept-Language": "de-DE,de;q=0.9,en;q=0.8"}
    if headers: h.update(headers)
    try:
        with op.open(urllib.request.Request(url, data=data, headers=h), timeout=25) as r:
            b = r.read().decode("utf-8", "replace")
            if not quiet: print(f"\n### {r.status} {r.geturl()} ({len(b)} B)\n{b[:n]}")
            return b
    except urllib.error.HTTPError as e:
        b = e.read().decode("utf-8", "replace"); print(f"\n### HTTP {e.code} {url}\n{b[:300]}")
    except Exception as e:
        print(f"\n### ERR {url} {e!r}")
def sec(s): print("\n\n================ " + s + " ================")

sec("YAHOO cookie+crumb")
get("https://fc.yahoo.com", 200)
print("cookies:", [c.name + "@" + c.domain for c in cj])
crumb = get("https://query1.finance.yahoo.com/v1/test/getcrumb", 100)
print("crumb:", crumb)
if crumb and len(crumb) < 30:
    get(f"https://query1.finance.yahoo.com/v8/finance/chart/7203.T?range=5d&interval=1d&crumb={crumb}", 1200)
    get(f"https://query1.finance.yahoo.com/v7/finance/quote?symbols=AAPL,7203.T&crumb={crumb}", 800)
get("https://finance.yahoo.com/quote/7203.T/", 300)
print("cookies after page:", [c.name + "@" + c.domain for c in cj])

sec("ONVISTA detail")
s = get("https://api.onvista.de/api/v1/stocks/ISIN:DE0007164600/snapshot", 0, quiet=True)
j = json.loads(s)
print("quote keys:", json.dumps(j["quote"])[:1200])
print("\nfirst quoteList entry:", json.dumps(j["quoteList"]["list"][0])[:1500])
print("\nchart:", json.dumps(j.get("chart"))[:800])
q0 = j["quoteList"]["list"][1]
idn = q0.get("market", {}).get("idNotation") or q0.get("idNotation")
print("idNotation candidates", {k: v for k, v in q0.items() if "otation" in k.lower()}, {k: v for k, v in q0.get("market", {}).items()})
for path in ["eod_history?idNotation={i}&range=Y1&startDate=2025-10-01", "chart_history?idNotation={i}&range=M1&resolution=1D", "eod_history?idNotation={i}&range=M1"]:
    get(f"https://api.onvista.de/api/v1/instruments/STOCK/82849/" + path.format(i=idn), 900)
for isin in ["US0378331005", "AU000000PDN8", "JE00BF50RG45", "SE0000108656"]:
    s = get(f"https://api.onvista.de/api/v1/stocks/ISIN:{isin}/snapshot", 0, quiet=True)
    if s:
        jj = json.loads(s)
        print(isin, jj["instrument"].get("name"), [(q["market"].get("name"), q["market"].get("codeMarket"), q.get("isoCurrency")) for q in jj.get("quoteList", {}).get("list", [])])
get("https://api.onvista.de/api/v1/instruments/search/facet?searchValue=Cameco", 600)

sec("CNBC")
get("https://quote.cnbc.com/quote-html-webservice/restQuote/symbolType/symbol?symbols=7203-JP%7CCCO-CA%7CPDN-AU%7CSHEL-GB&requestMethod=itv&noform=1&partnerId=2&fund=1&exthrs=1&output=json", 1500)
get("https://ts-api.cnbc.com/harmony/app/charts/1Y.json?symbol=7203-JP", 800)
get("https://ts-api.cnbc.com/harmony/app/bars/7203-JP/1D/20250101000000/20261017000000/adjusted/EST5EDT.json", 800)

sec("FT")
get("https://markets.ft.com/data/searchapi/searchsecurities?query=toyota", 800)
body = json.dumps({"days": 30, "dataNormalized": False, "dataPeriod": "Day", "dataInterval": 1, "realtime": False, "yFormat": "0.###", "timeServiceFormat": "JSON", "returnDateType": "ISO8601", "elements": [{"Type": "price", "Symbol": "7203:TYO"}]}).encode()
get("https://markets.ft.com/data/chartapi/series", 800, data=body, headers={"Content-Type": "application/json"})

sec("STOOQ")
get("https://stooq.com/q/d/l/?s=7203.jp&i=d", 300)

sec("LS-TC history")
get("https://www.ls-tc.de/_rpc/json/instrument/chart/dataForInstrument?container=chart1&instrumentId=34313&marketId=1&quotetype=mid&series=history&type=mini&localeId=2", 600)
