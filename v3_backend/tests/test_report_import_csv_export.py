from pathlib import Path
import sys


ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "scripts"
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))


def test_import_ready_csv_export_matches_upload_template():
    from report_import_export import build_import_csv_text

    transactions = [
        {
            "Ticker": "NASDAQ:AAPL",
            "Action": "Market buy",
            "No. of shares": "10",
            "Price / share": "217",
            "Currency conversion fee": "0",
            "Time": "2024-09-17 0:00:00",
        },
        {
            "Ticker": "NASDAQ:AAPL",
            "Action": "Market sell",
            "No. of shares": "10",
            "Price / share": "240.01",
            "Time": "2024-09-18 0:00:00",
        },
        {
            "Ticker": "NASDAQ:AAPL",
            "Action": "Dividend (Ordinary)",
            "Total": "0.25",
            "Time": "2024-11-14 0:00:00",
        },
        {
            "Action": "Withdrawal",
            "Total": "-2000",
            "Time": "2024-08-25 1:20:12",
        },
        {
            "Action": "Deposit",
            "Total": "5000",
            "Time": "2024-08-24 0:00:00",
        },
        {
            "Action": "Taxes and fees",
            "Total": "-10.25",
            "Currency conversion fee": "0",
            "Time": "2023-08-25 10:37:00",
        },
    ]

    assert build_import_csv_text(transactions) == "\n".join(
        [
            "Symbol,Side,Qty,Fill Price,Commission,Closing Time",
            "NASDAQ:AAPL,Buy,10,217,0,2024-09-17 0:00:00",
            "NASDAQ:AAPL,Sell,10,240.01,,2024-09-18 0:00:00",
            "NASDAQ:AAPL,Dividend,0.25,,,2024-11-14 0:00:00",
            "$CASH,Withdrawal,2000,,,2024-08-25 1:20:12",
            "$CASH,Deposit,5000,0,0,2024-08-24 0:00:00",
            "$CASH,Taxes and fees,10.25,,0,2023-08-25 10:37:00",
        ]
    )


def test_import_ready_csv_export_accepts_normalized_uploaded_transactions():
    from report_import_export import build_import_csv_text

    transactions = [
        {
            "ticker": "MSFT",
            "action": "BUY",
            "quantity": 2,
            "price": 410.5,
            "date": "2026-06-23 09:30:00",
        },
        {
            "ticker": "MSFT",
            "action": "SELL",
            "quantity": 1,
            "price": 420,
            "date": "2026-06-24",
        },
        {
            "ticker": "MSFT",
            "action": "DIVIDEND",
            "quantity": 0.83,
            "date": "2026-06-25",
        },
    ]

    assert build_import_csv_text(transactions) == "\n".join(
        [
            "Symbol,Side,Qty,Fill Price,Commission,Closing Time",
            "MSFT,Buy,2,410.5,,2026-06-23 09:30:00",
            "MSFT,Sell,1,420,,2026-06-24",
            "MSFT,Dividend,0.83,,,2026-06-25",
        ]
    )


def test_import_ready_csv_export_can_fallback_to_current_holdings():
    from report_import_export import build_import_csv_rows_from_holdings

    rows = build_import_csv_rows_from_holdings(
        [
            {
                "ticker": "AAPL",
                "shares": 10,
                "avg_cost_native": 217,
                "last_trade_time": "Trading 212 API snapshot",
            }
        ],
        closing_time="2026-06-23 12:00:00",
    )

    assert rows == [
        {
            "Symbol": "AAPL",
            "Side": "Buy",
            "Qty": "10",
            "Fill Price": "217",
            "Commission": "0",
            "Closing Time": "2024-01-01 0:00:00",
        }
    ]


def test_audit_report_includes_import_ready_csv_download(tmp_path):
    from build_portfolio_html import main

    data_dir = tmp_path / "portfolio_analysis"
    data_dir.mkdir()
    output = data_dir / "portfolio_cost_basis.html"
    (data_dir / "portfolio_analysis.json").write_text(
        """
        {
          "summary": {
            "as_of": "2026-06-23",
            "transactions": 1,
            "open_positions": 0,
            "open_positions_by_account": 0,
            "closed_positions": 0,
            "total_cost_usd_standard": 0,
            "cost_scale_by_currency": {},
            "warnings": []
          },
          "holdings": [],
          "import_transactions": [
            {
              "Symbol": "NASDAQ:AAPL",
              "Side": "Buy",
              "Qty": "10",
              "Fill Price": "217",
              "Commission": "0",
              "Closing Time": "2024-09-17 0:00:00"
            }
          ]
        }
        """,
        encoding="utf-8",
    )

    main(data_dir=data_dir, out_path=output)

    html = output.read_text(encoding="utf-8")
    assert 'id="exportImportCsv" type="button"' in html
    assert 'const importCsvRows = [{"Symbol": "NASDAQ:AAPL"' in html
    assert 'link.download = "portfolio_import_ready.csv"' in html


def test_audit_report_builds_import_csv_from_holdings_when_history_missing(tmp_path):
    from build_portfolio_html import main

    data_dir = tmp_path / "portfolio_analysis"
    data_dir.mkdir()
    output = data_dir / "portfolio_cost_basis.html"
    (data_dir / "portfolio_analysis.json").write_text(
        """
        {
          "summary": {
            "as_of": "2026-06-23 12:00:00",
            "transactions": 0,
            "open_positions": 1,
            "open_positions_by_account": 1,
            "closed_positions": 0,
            "total_cost_usd_standard": 2170,
            "cost_scale_by_currency": {},
            "warnings": []
          },
          "holdings": [
            {
              "ticker": "AAPL",
              "name": "Apple",
              "shares": 10,
              "cost_currency": "USD",
              "cost_usd_standard": 2170,
              "avg_cost_usd_standard": 217,
              "cost_native": 2170,
              "avg_cost_native": 217,
              "accounts": "Trading212 API",
              "last_trade_price": 240,
              "last_trade_time": "Trading 212 API snapshot"
            }
          ]
        }
        """,
        encoding="utf-8",
    )

    main(data_dir=data_dir, out_path=output)

    html = output.read_text(encoding="utf-8")
    assert 'const importCsvRows = [{"Symbol": "AAPL", "Side": "Buy", "Qty": "10", "Fill Price": "217", "Commission": "0", "Closing Time": "2024-01-01 0:00:00"}]' in html
