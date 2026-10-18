#!/usr/bin/env python3
"""Probes free market data endpoints from CI and prints compact results."""
import json, sys, urllib.request, urllib.parse, ssl, time, http.cookiejar

UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_5) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"
cj = http.cookiejar.CookieJar()
opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cj))

def get(url, n=1800, data=None, headers=None):
    h = {"User-Agent": UA, "Accept": "*/*"}
    if headers: h.update(headers)
    req = urllib.request.Request(url, data=data, headers=h)
    t = time.time()
    try:
        with opener.open(req, timeout=25) as r:
            body = r.read().decode("utf-8", "replace")
            print(f"\n### {r.status} {url}  ({time.time()-t:.1f}s, {len(body)} bytes)")
            print(body[:n])
            return body
    except urllib.error.HTTPError as e:
        b = e.read().decode("utf-8", "replace")
        print(f"\n### HTTP {e.code} {url}\n{b[:600]}")
    except Exception as e:
        print(f"\n### ERR {url} {e!r}")
    return None

def section(s): print("\n\n================ " + s + " ================")

section("YAHOO")
get("https://query1.finance.yahoo.com/v8/finance/chart/7203.T?range=5d&interval=1d", 2500)
get("https://query2.finance.yahoo.com/v8/finance/chart/SHEL.L?range=5d&interval=1d", 900)
get("https://query1.finance.yahoo.com/v7/finance/spark?symbols=AAPL,7203.T,SAP.DE,CCO.TO&range=5d&interval=1d", 1500)
get("https://query1.finance.yahoo.com/v7/finance/quote?symbols=AAPL,7203.T", 600)
for q in ["DE0007164600", "JP3633400001", "CA13321L1085", "Cameco", "Paladin Energy", "Yellow Cake", "NexGen Energy", "Kazatomprom"]:
    b = get("https://query2.finance.yahoo.com/v1/finance/search?" + urllib.parse.urlencode({"q": q, "quotesCount": 25, "newsCount": 0, "listsCount": 0, "enableFuzzyQuery": "false"}), 0)
    if b:
        try:
            for it in json.loads(b).get("quotes", []):
                print("   ", it.get("symbol"), "|", it.get("exchange"), "|", it.get("exchDisp"), "|", it.get("quoteType"), "|", it.get("shortname"))
        except Exception as e: print("parse", e)
get("https://query2.finance.yahoo.com/v1/finance/search?q=SDS.ST&quotesCount=5&newsCount=0", 700)

section("ONVISTA")
b = get("https://api.onvista.de/api/v1/instruments/search/facet?searchValue=DE0007164600", 1200)
b = get("https://api.onvista.de/api/v1/instruments/query?searchValue=DE0007164600", 1200)
snap = get("https://api.onvista.de/api/v1/stocks/ISIN:DE0007164600/snapshot", 600)
ent = None; notations = []
if snap:
    try:
        j = json.loads(snap)
        ent = j.get("instrument", {}).get("entityValue")
        print("entityValue", ent, "keys", list(j.keys()))
        ql = j.get("quoteList", {}).get("list", [])
        for q in ql:
            m = q.get("market", {})
            print("   ", q.get("idNotation"), "|", m.get("name"), "|", m.get("codeMarket"), "|", q.get("isoCurrency"), "|", q.get("last"), "|", q.get("datetimeLast"))
            notations.append((q.get("idNotation"), m.get("name")))
    except Exception as e: print("parse", e)
if ent and notations:
    idn = notations[0][0]
    for nm in notations:
        if nm[1] and "Tradegate" in nm[1]: idn = nm[0]
    get(f"https://api.onvista.de/api/v1/instruments/STOCK/{ent}/eod_history?idNotation={idn}&range=M1&startDate=2026-09-01", 1500)
    get(f"https://api.onvista.de/api/v1/instruments/STOCK/{ent}/chart_history?idNotation={idn}&range=M1&resolution=1D", 1200)
    get(f"https://api.onvista.de/api/v1/instruments/STOCK/{ent}/times_and_sales?idNotation={idn}&limit=2", 600)
snap2 = get("https://api.onvista.de/api/v1/stocks/ISIN:JP3633400001/snapshot", 0)
if snap2:
    try:
        j = json.loads(snap2)
        for q in j.get("quoteList", {}).get("list", []):
            m = q.get("market", {})
            print("   JP", q.get("idNotation"), "|", m.get("name"), "|", m.get("codeMarket"), "|", q.get("isoCurrency"), "|", q.get("last"))
    except Exception as e: print("parse", e)
snap3 = get("https://api.onvista.de/api/v1/stocks/ISIN:CA13321L1085/snapshot", 0)
if snap3:
    try:
        j = json.loads(snap3)
        for q in j.get("quoteList", {}).get("list", []):
            m = q.get("market", {})
            print("   CA", q.get("idNotation"), "|", m.get("name"), "|", m.get("codeMarket"), "|", q.get("isoCurrency"), "|", q.get("last"))
    except Exception as e: print("parse", e)

section("STOOQ")
get("https://stooq.com/q/d/l/?s=aapl.us&i=d", 400)
get("https://stooq.com/q/l/?s=aapl.us+7203.jp&f=sd2t2ohlcv&h&e=csv", 400)

section("BITFINEX")
get("https://api-pub.bitfinex.com/v2/ticker/tBTCUSD", 400)
get("https://api-pub.bitfinex.com/v2/candles/trade:1D:tBTCUSD/hist?limit=3", 400)
get("https://api-pub.bitfinex.com/v2/conf/pub:list:pair:exchange", 500)

section("FX")
get("https://www.ecb.europa.eu/stats/eurofxref/eurofxref-hist-90d.xml", 700)
get("https://api.frankfurter.dev/v1/latest?base=EUR", 500)
get("https://api.frankfurter.app/2026-01-02..2026-01-06?from=EUR&to=JPY,USD", 500)

section("TRADEGATE / LS")
get("https://www.tradegate.de/refresh.php?isin=DE0007164600", 600)
get("https://www.ls-tc.de/_rpc/json/.lstc/instrument/search/main?q=DE0007164600&localeId=2", 600)

section("KEYED DEMO")
get("https://eodhd.com/api/eod/AAPL.US?api_token=demo&fmt=json&from=2026-10-01", 600)
get("https://eodhd.com/api/real-time/AAPL.US?api_token=demo&fmt=json", 600)
get("https://eodhd.com/api/exchanges-list/?api_token=demo&fmt=json", 600)
get("https://api.twelvedata.com/time_series?symbol=AAPL&interval=1day&outputsize=3&apikey=demo", 700)
get("https://api.twelvedata.com/quote?symbol=AAPL&apikey=demo", 700)
get("https://api.twelvedata.com/symbol_search?symbol=DE0007164600", 900)
get("https://www.alphavantage.co/query?function=TIME_SERIES_DAILY&symbol=IBM&apikey=demo", 600)
get("https://www.alphavantage.co/query?function=SYMBOL_SEARCH&keywords=tesco&apikey=demo", 700)
get("https://www.alphavantage.co/query?function=GLOBAL_QUOTE&symbol=IBM&apikey=demo", 600)
get("https://finnhub.io/api/v1/quote?symbol=AAPL&token=", 300)

section("NTFY")
get("https://ntfy.sh/watchdog-ci-probe-7f3k", 300, data="Watchdog CI probe".encode(), headers={"Title": "Probe", "Tags": "green_circle"})
