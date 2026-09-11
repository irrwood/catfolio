from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PORTFOLIO = ROOT / "CatfolioIOS" / "CatfolioIOS" / "PortfolioView.swift"


def _holding_row_source() -> str:
    source = PORTFOLIO.read_text()
    start = source.index("private struct HoldingRow: View")
    end = source.index("private struct PortfolioLoadingView", start)
    return source[start:end]


def test_holding_row_uses_figma_montserrat_type_scale() -> None:
    source = _holding_row_source()

    assert "PortfolioHomeTypography.medium(16, relativeTo: .headline)" in source
    assert "PortfolioHomeTypography.medium(12, relativeTo: .caption)" in source
    assert "PortfolioHomeTypography.medium(17" not in source
    assert "PortfolioHomeTypography.semibold(17" not in source
    assert "PortfolioHomeTypography.medium(13" not in source
    assert "PortfolioHomeTypography.semibold(13" not in source


def test_holding_row_matches_figma_numeric_tracking() -> None:
    source = _holding_row_source()

    assert ".tracking(0.16)" in source
    assert ".tracking(0.12)" in source
    assert ".tracking(1.28)" not in source
    assert ".tracking(0.96)" not in source
    assert ".tracking(1.36)" not in source
    assert ".tracking(1.04)" not in source


def test_ticker_uses_the_same_one_percent_tracking() -> None:
    source = _holding_row_source()
    ticker = source.index("Text(holding.ticker)")
    following = source[ticker : ticker + 180]

    assert "PortfolioHomeTypography.medium(12, relativeTo: .caption)" in following
    assert ".tracking(0.12)" in following
