import csv
import json
from collections import defaultdict
from dataclasses import dataclass
from datetime import datetime
from decimal import Decimal, InvalidOperation, getcontext
from pathlib import Path

getcontext().prec = 28

import os, glob as _glob
def _init_source_files():
    data_dir = os.environ.get("CATFOLIO_DATA_DIR") or os.environ.get("HELM_DATA_DIR") or ""
    if data_dir and os.path.isdir(data_dir):
        csv_files = sorted(_glob.glob(os.path.join(data_dir, "*.csv")))
        result = []
        for f in csv_files:
            basename = os.path.basename(f)
            account = "A" if "A" in basename.split("-")[0] else "B"
            result.append((account, f))
        return result
    return []
SOURCE_FILES = _init_source_files()

BUY_ACTIONS = {"Market buy", "Limit buy"}
SELL_ACTIONS = {"Market sell"}
SHARE_ACTIONS = BUY_ACTIONS | SELL_ACTIONS | {"Stock dividends"}
REPORT_FX_TO_USD = {
    "USD": Decimal("1"),
    "GBP": Decimal("1.3460"),
    "GBX": Decimal("0.013460"),
    "EUR": Decimal("1.1630"),
}
REPORT_FX_SOURCE = "currencyrate.today, 2026-06-03 UTC: GBP/USD 1.3460; EUR/USD 1.1630"
YAHOO_SYMBOL_OVERRIDES = {
    "BRK.B": "BRK-B",
    "ENR": "ENR.DE",
    "RWE": "RWE.DE",
    "VUAG": "VUAG.L",
    "VUSA": "VUSA.L",
    "BARC": "BARC.L",
}


def dec(value):
    if value is None or value == "":
        return Decimal("0")
    try:
        return Decimal(str(value).replace(",", ""))
    except InvalidOperation:
        return Decimal("0")


def _parse_datetime(time_str):
    if not time_str:
        return None
    time_str = time_str.strip()
    if " +" in time_str:
        time_str = time_str.split(" +")[0]
    if " UTC" in time_str:
        time_str = time_str.replace(" UTC", "")
        
    for fmt in ["%Y-%m-%d %H:%M:%S", "%Y-%m-%d %H:%M:%S.%f", "%d/%m/%Y %H:%M:%S", "%Y/%m/%d %H:%M:%S", "%Y-%m-%d", "%d/%m/%Y"]:
        try:
            return datetime.strptime(time_str, fmt)
        except ValueError:
            continue
            
    try:
        if len(time_str) >= 10:
            if time_str[4] == "-" and time_str[7] == "-":
                return datetime.strptime(time_str[:10], "%Y-%m-%d")
            elif time_str[2] == "/" and time_str[5] == "/":
                return datetime.strptime(time_str[:10], "%d/%m/%Y")
    except Exception:
        pass
    return None


def money_currency(row):
    return row.get("Currency (Total)") or row.get("Currency (Price / share)") or ""


def price_currency(row):
    return row.get("Currency (Price / share)") or ""


def price_currency_equivalent(row):
    total = dec(row.get("Total"))
    total_currency = money_currency(row)
    quote_currency = price_currency(row)
    rate = dec(row.get("Exchange rate"))
    if not quote_currency:
        return None
    if total_currency == quote_currency:
        return total
    if quote_currency == "GBX" and total_currency == "GBP":
        return total * Decimal("100")
    if quote_currency == "GBP" and total_currency == "GBX":
        return total / Decimal("100")
    if total_currency == "GBP" and rate:
        return total * rate
    if quote_currency == "GBP" and rate:
        return total / rate
    return None


def gbp_equivalent(row):
    total = dec(row.get("Total"))
    currency = money_currency(row)
    rate = dec(row.get("Exchange rate"))
    if currency == "GBP":
        return total
    if currency == "GBX":
        return total / Decimal("100")
    if rate and rate != 1:
        return total / rate
    return None


def usd_report_equivalent(amount, currency):
    rate = REPORT_FX_TO_USD.get(currency)
    if rate is None:
        return Decimal("0")
    return amount * rate


def yahoo_symbol(ticker, currency):
    if ticker in YAHOO_SYMBOL_OVERRIDES:
        return YAHOO_SYMBOL_OVERRIDES[ticker]
    if currency in {"GBP", "GBX"} and "." not in ticker:
        return f"{ticker}.L"
    return ticker


@dataclass
class Position:
    shares: Decimal = Decimal("0")
    cost_native: Decimal = Decimal("0")
    cost_gbp: Decimal = Decimal("0")
    realized_native: Decimal = Decimal("0")
    realized_gbp: Decimal = Decimal("0")


def read_transactions():
    rows = []
    for account, file_path in SOURCE_FILES:
        path = Path(file_path)
        with path.open("r", encoding="utf-8-sig", newline="") as handle:
            reader = csv.DictReader(handle)
            for row in reader:
                row["Account"] = account
                row["Source file"] = path.name
                time_val = row.get("Time") or row.get("Date") or ""
                dt = _parse_datetime(time_val)
                if not dt:
                    continue
                row["dt"] = dt
                rows.append(row)
    rows.sort(key=lambda row: (row["dt"], row["Account"], row.get("ID", "")))
    return rows


def main():
    transactions = read_transactions()
    positions = defaultdict(Position)
    meta = {}
    trade_counts = defaultdict(lambda: defaultdict(int))
    cash = defaultdict(Decimal)
    interest = defaultdict(Decimal)
    dividends = defaultdict(Decimal)
    fees_gbp = Decimal("0")
    last_trade = {}
    warnings = []

    for row in transactions:
        action = row["Action"]
        account = row["Account"]
        ticker = row.get("Ticker") or row.get("Symbol") or ""
        total = dec(row.get("Total"))
        currency = money_currency(row)

        if action == "Interest on cash":
            interest[(account, currency)] += total
            cash[(account, currency)] += total
        elif action in {"Deposit", "Spending cashback", "Currency conversion"}:
            cash[(account, currency)] += total
        elif action in {"Withdrawal", "Card debit"}:
            cash[(account, currency)] -= total
        elif action.startswith("Dividend") or action == "Result adjustment":
            dividends[(account, currency)] += total
            cash[(account, currency)] += total

        fee = gbp_equivalent({"Total": row.get("Currency conversion fee"), "Currency (Total)": row.get("Currency (Currency conversion fee)"), "Exchange rate": "1"})
        if fee:
            fees_gbp += fee

        if action not in SHARE_ACTIONS or not ticker:
            continue

        key = (account, ticker)
        shares = dec(row.get("No. of shares") or row.get("Quantity"))
        native_total = price_currency_equivalent(row)
        gbp_total = gbp_equivalent(row)
        pos = positions[key]
        meta[key] = {
            "account": account,
            "ticker": ticker,
            "isin": row.get("ISIN", ""),
            "name": row.get("Name", ""),
            "price_currency": price_currency(row),
            "cost_currency": price_currency(row),
        }
        trade_counts[key][action] += 1

        if action in BUY_ACTIONS:
            pos.shares += shares
            if native_total is not None:
                pos.cost_native += native_total
            if gbp_total is not None:
                pos.cost_gbp += gbp_total
            last_trade[key] = row
        elif action in SELL_ACTIONS:
            if pos.shares <= 0:
                warnings.append(f"{account} {ticker}: sell without opening quantity at {row['Time']}")
                avg_native = Decimal("0")
                avg_gbp = Decimal("0")
            else:
                avg_native = pos.cost_native / pos.shares
                avg_gbp = pos.cost_gbp / pos.shares if pos.cost_gbp else Decimal("0")
            removed_native = avg_native * shares
            removed_gbp = avg_gbp * shares
            pos.shares -= shares
            pos.cost_native -= removed_native
            pos.cost_gbp -= removed_gbp
            if native_total is not None:
                pos.realized_native += native_total - removed_native
            if gbp_total is not None:
                pos.realized_gbp += gbp_total - removed_gbp
            if abs(pos.shares) < Decimal("0.00000001"):
                pos.shares = Decimal("0")
                pos.cost_native = Decimal("0")
                pos.cost_gbp = Decimal("0")
            last_trade[key] = row
        elif action == "Stock dividends":
            pos.shares += shares
            last_trade[key] = row

    holdings_by_account = []
    closed = []
    for key, pos in sorted(positions.items()):
        info = meta[key]
        avg_native = pos.cost_native / pos.shares if pos.shares else Decimal("0")
        avg_gbp = pos.cost_gbp / pos.shares if pos.shares else Decimal("0")
        cost_usd = usd_report_equivalent(pos.cost_native, info["cost_currency"])
        avg_usd = cost_usd / pos.shares if pos.shares else Decimal("0")
        row = {
            **info,
            "yahoo_symbol": yahoo_symbol(info["ticker"], info["cost_currency"]),
            "shares": float(pos.shares),
            "cost_native": float(pos.cost_native),
            "avg_cost_native": float(avg_native),
            "cost_gbp_available": float(pos.cost_gbp),
            "avg_cost_gbp_available": float(avg_gbp),
            "cost_usd_standard": float(cost_usd),
            "avg_cost_usd_standard": float(avg_usd),
            "realized_native": float(pos.realized_native),
            "realized_gbp_available": float(pos.realized_gbp),
            "buys": trade_counts[key]["Market buy"] + trade_counts[key]["Limit buy"],
            "sells": trade_counts[key]["Market sell"],
            "stock_dividends": trade_counts[key]["Stock dividends"],
        }
        if key in last_trade:
            lt = last_trade[key]
            row.update({
                "last_trade_time": lt.get("Time") or lt.get("Date") or "",
                "last_trade_action": lt["Action"],
                "last_trade_price": float(dec(lt.get("Price / share"))),
                "last_trade_price_currency": price_currency(lt),
            })
        if pos.shares > Decimal("0.0000001"):
            holdings_by_account.append(row)
        else:
            closed.append(row)

    accounts_by_ticker = defaultdict(set)
    combined_positions = defaultdict(Position)
    combined_meta = {}
    combined_counts = defaultdict(lambda: defaultdict(int))
    combined_last = {}
    for row in holdings_by_account:
        ticker = row["ticker"]
        accounts_by_ticker[ticker].add(row["account"])
        combined_meta[ticker] = {
            "ticker": ticker,
            "isin": row["isin"],
            "name": row["name"],
            "price_currency": row["price_currency"],
            "cost_currency": row["cost_currency"],
        }
        pos = combined_positions[ticker]
        pos.shares += Decimal(str(row["shares"]))
        pos.cost_native += Decimal(str(row["cost_native"]))
        pos.cost_gbp += Decimal(str(row["cost_gbp_available"]))
        pos.realized_native += Decimal(str(row["realized_native"]))
        pos.realized_gbp += Decimal(str(row["realized_gbp_available"]))
        combined_counts[ticker]["buys"] += int(row["buys"])
        combined_counts[ticker]["sells"] += int(row["sells"])
        combined_counts[ticker]["stock_dividends"] += int(row["stock_dividends"])
        if ticker not in combined_last or row.get("last_trade_time", "") > combined_last[ticker].get("last_trade_time", ""):
            combined_last[ticker] = row

    holdings = []
    for ticker, pos in sorted(combined_positions.items()):
        info = combined_meta[ticker]
        avg_native = pos.cost_native / pos.shares if pos.shares else Decimal("0")
        avg_gbp = pos.cost_gbp / pos.shares if pos.shares and pos.cost_gbp else Decimal("0")
        cost_usd = usd_report_equivalent(pos.cost_native, info["cost_currency"])
        avg_usd = cost_usd / pos.shares if pos.shares else Decimal("0")
        last = combined_last.get(ticker, {})
        holdings.append({
            **info,
            "yahoo_symbol": yahoo_symbol(info["ticker"], info["cost_currency"]),
            "accounts": ",".join(sorted(accounts_by_ticker[ticker])),
            "shares": float(pos.shares),
            "cost_native": float(pos.cost_native),
            "avg_cost_native": float(avg_native),
            "cost_gbp_available": float(pos.cost_gbp),
            "avg_cost_gbp_available": float(avg_gbp),
            "cost_usd_standard": float(cost_usd),
            "avg_cost_usd_standard": float(avg_usd),
            "realized_native": float(pos.realized_native),
            "realized_gbp_available": float(pos.realized_gbp),
            "buys": combined_counts[ticker]["buys"],
            "sells": combined_counts[ticker]["sells"],
            "stock_dividends": combined_counts[ticker]["stock_dividends"],
            "last_trade_time": last.get("last_trade_time", ""),
            "last_trade_action": last.get("last_trade_action", ""),
            "last_trade_price": last.get("last_trade_price", 0),
            "last_trade_price_currency": last.get("last_trade_price_currency", ""),
        })

    by_currency = defaultdict(lambda: {"positions": 0, "cost_native": Decimal("0"), "cost_gbp_available": Decimal("0")})
    by_account = defaultdict(lambda: {"positions": 0, "cost_gbp_available": Decimal("0")})
    total_cost_usd_standard = Decimal("0")
    for row in holdings_by_account:
        cur = row["cost_currency"]
        by_currency[cur]["positions"] += 1
        by_currency[cur]["cost_native"] += Decimal(str(row["cost_native"]))
        by_currency[cur]["cost_gbp_available"] += Decimal(str(row["cost_gbp_available"]))
        by_account[row["account"]]["positions"] += 1
        by_account[row["account"]]["cost_gbp_available"] += Decimal(str(row["cost_gbp_available"]))
        total_cost_usd_standard += Decimal(str(row["cost_usd_standard"]))

    interest_usd_standard = sum(
        usd_report_equivalent(amount, currency)
        for (account, currency), amount in interest.items()
    )
    dividends_usd_standard = sum(
        usd_report_equivalent(amount, currency)
        for (account, currency), amount in dividends.items()
    )

    summary = {
        "as_of": "2026-06-03",
        "source_files": len(SOURCE_FILES),
        "transactions": len(transactions),
        "open_positions": len(holdings),
        "open_positions_by_account": len(holdings_by_account),
        "closed_positions": len(closed),
        "report_fx_to_usd": {currency: float(rate) for currency, rate in REPORT_FX_TO_USD.items()},
        "report_fx_source": REPORT_FX_SOURCE,
        "total_cost_usd_standard": float(total_cost_usd_standard),
        "cost_scale_by_currency": {
            cur: {
                "positions": val["positions"],
                "cost_native": float(val["cost_native"]),
                "cost_gbp_available": float(val["cost_gbp_available"]),
            }
            for cur, val in sorted(by_currency.items())
        },
        "cost_scale_by_account_gbp_available": {
            account: {
                "positions": val["positions"],
                "cost_gbp_available": float(val["cost_gbp_available"]),
            }
            for account, val in sorted(by_account.items())
        },
        "cash_movements_by_account_currency": {
            f"{account}_{currency}": float(amount)
            for (account, currency), amount in sorted(cash.items())
        },
        "interest_by_account_currency": {
            f"{account}_{currency}": float(amount)
            for (account, currency), amount in sorted(interest.items())
        },
        "interest_by_currency": {
            currency: float(sum(amount for (account, cur), amount in interest.items() if cur == currency))
            for currency in sorted({currency for account, currency in interest})
        },
        "interest_usd_standard": float(interest_usd_standard),
        "dividends_by_account_currency": {
            f"{account}_{currency}": float(amount)
            for (account, currency), amount in sorted(dividends.items())
        },
        "dividends_by_currency": {
            currency: float(sum(amount for (account, cur), amount in dividends.items() if cur == currency))
            for currency in sorted({currency for account, currency in dividends})
        },
        "dividends_usd_standard": float(dividends_usd_standard),
        "warnings": warnings,
    }

    out_dir = Path("outputs/portfolio_analysis")
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "portfolio_analysis.json").write_text(
        json.dumps({"summary": summary, "holdings": holdings, "holdings_by_account": holdings_by_account, "closed_positions": closed}, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )

    for name, rows in [("holdings.csv", holdings), ("holdings_by_account.csv", holdings_by_account), ("closed_positions.csv", closed)]:
        if not rows:
            continue
        with (out_dir / name).open("w", encoding="utf-8-sig", newline="") as handle:
            writer = csv.DictWriter(handle, fieldnames=list(rows[0].keys()))
            writer.writeheader()
            writer.writerows(rows)

    print(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
