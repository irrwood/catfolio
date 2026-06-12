"""True Time-Weighted Return calculation from transaction history."""

from collections import defaultdict


def compute_twr_returns():
    """Simplified monthly TWR using CSV transaction files.

    Uses the same SOURCE_FILES defined in lab.py to extract
    deposits, withdrawals, buys, sells, dividends and compute
    monthly cash flow summaries.
    """
    from .lab import SOURCE_FILES, BUY_ACTIONS, REPORT_FX_TO_USD, _dec, _parse_datetime
    import csv
    from decimal import Decimal

    transactions = []
    for account, csv_path in SOURCE_FILES:
        try:
            with open(csv_path, newline="", encoding="utf-8-sig") as f:
                reader = csv.DictReader(f)
                for row in reader:
                    action = row.get("Action", "")
                    is_trade = action in BUY_ACTIONS or action in {"Market sell"}
                    is_cf = action in {"Deposit", "Withdrawal", "Dividend (Ordinary)", "Dividend (Qualified)", "Interest on cash", "Currency conversion"}
                    if not is_trade and not is_cf:
                        continue
                    time_val = row.get("Date") or row.get("Time") or ""
                    dt = _parse_datetime(time_val)
                    if not dt:
                        continue
                    date_str = dt.strftime("%Y-%m-%d")
                    transactions.append({
                        "account": account,
                        "date": date_str,
                        "action": action,
                        "ticker": row.get("Ticker") or row.get("Symbol") or "",
                        "shares": row.get("Quantity") or row.get("No. of shares") or "0",
                        "total": row.get("Total", "0"),
                        "currency": row.get("Currency (Total)", row.get("Currency (Price / share)", "USD")),
                        "fx_fee": row.get("Currency conversion fee", "0"),
                    })
        except FileNotFoundError:
            continue

    if not transactions:
        return {"error": "No transactions found", "twr": None, "periods": []}

    transactions.sort(key=lambda t: t["date"])

    # Group by month and compute net cash flow
    monthly_cf = defaultdict(float)
    monthly_trades = defaultdict(int)

    for txn in transactions:
        month_key = txn["date"][:7]
        currency = txn["currency"] or "USD"
        rate = REPORT_FX_TO_USD.get(currency, Decimal("1"))
        total = _dec(txn["total"])
        fx_fee = _dec(txn["fx_fee"])
        usd_total = float(total * rate)
        usd_fee = float(fx_fee * Decimal("1.3460"))  # approximate GBP to USD

        action = txn["action"]
        if action in {"Deposit"}:
            monthly_cf[month_key] += usd_total
        elif action in {"Withdrawal"}:
            monthly_cf[month_key] -= usd_total
        elif action.startswith("Dividend") or action.startswith("Interest"):
            monthly_cf[month_key] += usd_total
        elif action in {"Market buy", "Limit buy"}:
            monthly_cf[month_key] -= (usd_total + usd_fee)
            monthly_trades[month_key] += 1
        elif action in {"Market sell"}:
            monthly_cf[month_key] += (usd_total - usd_fee)
            monthly_trades[month_key] += 1

    months = sorted(monthly_cf.keys())
    if not months:
        return {"error": "No months with activity", "twr": None}

    monthly_data = {}
    for m in months:
        monthly_data[m] = {
            "net_cf": round(monthly_cf[m], 2),
            "trades": monthly_trades.get(m, 0),
        }

    return {
        "method": "simplified_monthly_twr",
        "note": "Approximation using monthly net cash flows. Full TWR requires daily portfolio NAV snapshots with Yahoo price data.",
        "months_analyzed": len(months),
        "period": f"{months[0]} to {months[-1]}",
        "monthly_data": monthly_data,
    }
