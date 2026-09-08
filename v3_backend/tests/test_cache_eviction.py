"""The TTL cache reclaims space instead of growing for the life of the process.

Expired entries were never deleted: the read path returns early on a hit and
skips past a miss, so only clear_all() ever freed anything — and a browse-only
session never triggers a data refresh. The analytics caches are keyed by the
snapshot's loaded_at timestamp, a fresh key roughly every 10s, so the store grew
without bound.

The load-bearing property is that reclaiming space must not cost a refetch: the
12h lab/api results are the only cached values whose rebuild hits the network,
so they must outlive the cheap short-TTL entries under pressure.
"""

import pytest


@pytest.fixture(autouse=True)
def _clean_store():
    from app import cache
    cache.clear_all()
    yield
    cache.clear_all()


def test_expired_entries_are_reclaimed_once_the_store_is_over_budget(monkeypatch):
    from app import cache

    monkeypatch.setattr(cache, "_MAX_ENTRIES", 50)
    clock = {"t": 1000.0}
    monkeypatch.setattr(cache.time, "time", lambda: clock["t"])

    @cache.cached(ttl=30, key=lambda s: s)
    def pure(s):
        return s

    for i in range(40):
        pure(f"snap-{i}")
    assert cache.cache_size() == 40

    clock["t"] += 60  # every entry above is now expired
    for i in range(40, 80):
        pure(f"snap-{i}")

    assert cache.cache_size() <= 50, "expired entries were never reclaimed"


def test_eviction_keeps_the_network_backed_entries_and_sheds_the_cheap_ones(monkeypatch):
    from app import cache

    monkeypatch.setattr(cache, "_MAX_ENTRIES", 20)
    fetches = {"n": 0}

    @cache.cached(ttl=60 * 60 * 12)          # stands in for a Yahoo history fetch
    def expensive(symbol):
        fetches["n"] += 1
        return symbol

    @cache.cached(ttl=30, key=lambda s: s)   # pure, recomputed cheaply
    def cheap(s):
        return s

    for i in range(10):
        expensive(f"T{i}")
    assert fetches["n"] == 10

    # Flood with live short-TTL entries; nothing has expired yet, so the store
    # must choose what to shed while everything is still valid.
    for i in range(200):
        cheap(f"snap-{i}")

    assert cache.cache_size() <= 20
    for i in range(10):
        expensive(f"T{i}")
    assert fetches["n"] == 10, (
        f"eviction dropped long-TTL entries and forced {fetches['n'] - 10} refetches"
    )


def test_clearing_one_function_does_not_wipe_a_longer_named_sibling():
    from app import cache

    @cache.cached(ttl=300)
    def api_returns():
        return "short"

    @cache.cached(ttl=300)
    def api_returns_summary():
        return "long"

    api_returns()
    api_returns_summary()
    assert cache.cache_size() == 2

    api_returns.cache_clear()

    remaining = [k for k in cache._store]
    assert remaining == ["api_returns_summary:():[]"], remaining
