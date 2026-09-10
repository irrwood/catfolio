import pytest
from fastapi import HTTPException


def test_asset_logo_symbol_accepts_market_suffixes():
    from app.routes.api import _normalize_asset_logo_symbol

    assert _normalize_asset_logo_symbol(" vuag.l ") == "VUAG.L"
    assert _normalize_asset_logo_symbol("BRK-B") == "BRK-B"


@pytest.mark.parametrize("symbol", ["", "../AAPL", "AAPL/../../x", "<script>"])
def test_asset_logo_symbol_rejects_unsafe_values(symbol):
    from app.routes.api import _normalize_asset_logo_symbol

    with pytest.raises(HTTPException) as exc_info:
        _normalize_asset_logo_symbol(symbol)

    assert exc_info.value.status_code == 404
