import csv
import io
from datetime import datetime
from decimal import Decimal, InvalidOperation


IMPORT_CSV_HEADERS = ["Symbol", "Side", "Qty", "Fill Price", "Commission", "Closing Time"]
SNAPSHOT_FALLBACK_CLOSING_TIME = "2024-01-01 0:00:00"

BUY_ACTIONS = {"Market buy", "Limit buy", "BUY"}
SELL_ACTIONS = {"Market sell", "SELL"}
DEPOSIT_ACTIONS = {"Deposit", "Spending cashback"}
WITHDRAWAL_ACTIONS = {"Withdrawal", "Card debit"}


def _first(row, *keys):
    for key in keys:
        value = row.get(key)
        if value not in (None, ""):
            return value
    return ""


def _number(value, absolute=False):
    if value in (None, ""):
        return ""
    try:
        number = Decimal(str(value).replace(",", "").strip())
    except InvalidOperation:
        return str(value).strip()
    if absolute:
        number = abs(number)
    if number == 0:
        return "0"
    return format(number.normalize(), "f")


def _closing_time(row):
    value = _first(row, "Closing Time", "Time", "Date", "date")
    if isinstance(value, datetime):
        return value.strftime("%Y-%m-%d %H:%M:%S")
    return str(value).strip()


def _trade_row(row, side):
    return {
        "Symbol": str(_first(row, "Symbol", "Ticker", "ticker")).strip(),
        "Side": side,
        "Qty": _number(_first(row, "Qty", "No. of shares", "Quantity", "quantity"), absolute=True),
        "Fill Price": _number(_first(row, "Fill Price", "Price / share", "Price", "price")),
        "Commission": _number(_first(row, "Commission", "Currency conversion fee")),
        "Closing Time": _closing_time(row),
    }


def _cash_row(row, side, fill_price="", commission=""):
    return {
        "Symbol": "$CASH",
        "Side": side,
        "Qty": _number(_first(row, "Qty", "Total", "Amount"), absolute=True),
        "Fill Price": fill_price,
        "Commission": commission,
        "Closing Time": _closing_time(row),
    }


def build_import_csv_rows(transactions):
    rows = []
    for row in transactions:
        action = str(row.get("Action") or row.get("Side") or row.get("action") or "").strip()
        if action in BUY_ACTIONS:
            rows.append(_trade_row(row, "Buy"))
        elif action in SELL_ACTIONS:
            rows.append(_trade_row(row, "Sell"))
        elif action == "Stock dividends":
            rows.append(_trade_row(row, "Dividend"))
            rows[-1]["Fill Price"] = ""
            rows[-1]["Commission"] = ""
        elif action.startswith("Dividend") or action in {"DIVIDEND", "Result adjustment"}:
            rows.append(
                {
                    "Symbol": str(_first(row, "Symbol", "Ticker", "ticker")).strip(),
                    "Side": "Dividend",
                    "Qty": _number(_first(row, "Qty", "Total", "Amount", "quantity"), absolute=True),
                    "Fill Price": "",
                    "Commission": "",
                    "Closing Time": _closing_time(row),
                }
            )
        elif action in WITHDRAWAL_ACTIONS:
            rows.append(_cash_row(row, "Withdrawal"))
        elif action in DEPOSIT_ACTIONS:
            rows.append(_cash_row(row, "Deposit", fill_price="0", commission="0"))
        elif action in {"Taxes and fees", "Tax", "Fee"}:
            rows.append(_cash_row(row, "Taxes and fees", commission=_number(_first(row, "Commission", "Currency conversion fee"))))
    return rows


def build_import_csv_rows_from_holdings(holdings, closing_time=""):
    rows = []
    for row in holdings:
        shares = _number(row.get("shares"), absolute=True)
        if not shares or shares == "0":
            continue
        raw_time = _closing_time(row)
        if not raw_time or "snapshot" in raw_time.lower():
            raw_time = SNAPSHOT_FALLBACK_CLOSING_TIME
        rows.append(
            {
                "Symbol": str(row.get("ticker") or row.get("Symbol") or "").strip(),
                "Side": "Buy",
                "Qty": shares,
                "Fill Price": _number(row.get("avg_cost_native")),
                "Commission": "0",
                "Closing Time": raw_time,
            }
        )
    return rows


def build_import_csv_text(transactions):
    output = io.StringIO()
    writer = csv.DictWriter(output, fieldnames=IMPORT_CSV_HEADERS, lineterminator="\n")
    writer.writeheader()
    writer.writerows(build_import_csv_rows(transactions))
    return output.getvalue().rstrip("\n")
