import pytest

from app.strategy_engine import _compile_strategy


class FakeCtx:
    universe = ["AAPL", "MSFT"]
    date = "2026-01-02"
    i = 12

    def price(self, ticker):
        return {"AAPL": 100, "MSFT": 200}.get(ticker)

    def history(self, ticker, n):
        return [self.price(ticker)] * n

    def sma(self, ticker, n):
        return self.price(ticker)

    def momentum(self, ticker, n):
        return {"AAPL": 0.1, "MSFT": -0.1}.get(ticker, 0)


def test_strategy_compiler_allows_existing_template_shape():
    code = """
def strategy(ctx):
    picks = [t for t in ctx.universe if (ctx.momentum(t, 60) or 0) > 0]
    if not picks:
        return {}
    w = 1.0 / len(picks)
    return {t: w for t in picks}
"""
    strategy = _compile_strategy(code)

    assert strategy(FakeCtx()) == {"AAPL": 1.0}


@pytest.mark.parametrize(
    "code",
    [
        "import os\ndef strategy(ctx):\n    return {}",
        "def strategy(ctx):\n    return open('/tmp/x').read()",
        "def strategy(ctx):\n    return __import__('os').system('id')",
        "def strategy(ctx):\n    return ().__class__.__mro__",
        "def strategy(ctx):\n    return ctx.__class__",
        "def strategy(ctx):\n    return globals()",
    ],
)
def test_strategy_compiler_rejects_rce_primitives(code):
    with pytest.raises(ValueError, match="策略代码不安全"):
        _compile_strategy(code)


def test_strategy_compiler_rejects_extra_top_level_code():
    code = """
result = 1
def strategy(ctx):
    return {}
"""
    with pytest.raises(ValueError, match="顶层只允许"):
        _compile_strategy(code)


def test_strategy_compiler_rejects_top_level_calls():
    code = """
sum(range(10))
def strategy(ctx):
    return {}
"""
    with pytest.raises(ValueError, match="顶层只允许"):
        _compile_strategy(code)
