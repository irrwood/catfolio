"""
Simple TTL in-memory cache for expensive computations.

Usage:
    from .cache import cached

    @cached(ttl=300)
    def expensive_function(...):
        ...

    # Clear all caches:
    from .cache import clear_all
    clear_all()
"""

import os
import threading
import time
from functools import wraps

_store: dict[str, tuple[float, object]] = {}
# An entry is only noticed as expired when its own key is read again, and the
# analytics caches are keyed by the snapshot's loaded_at timestamp — a fresh key
# every ~10s. Nothing else reclaims them: clear_all() runs on data refresh, which
# a browse-only session never triggers. So the store is swept on write once it
# grows past this budget. The live working set is well under 50 entries (one
# snapshot, its handful of analytics, and the 12h lab/api results), so the
# default leaves plenty of headroom before anything is dropped.
_MAX_ENTRIES = int(os.environ.get("CATFOLIO_CACHE_MAX_ENTRIES", "512"))
# Sync routes run in Starlette's threadpool, so _store can be touched by
# concurrent threads. Dict ops are atomic under the GIL, but the lock guards
# the read/expiry/write critical section. Function execution happens OUTSIDE
# the lock, so parallel cache misses still compute in parallel (a brief double
# compute on a miss is harmless and far cheaper than serializing all work).
_lock = threading.Lock()
_inflight: dict[str, threading.Event] = {}


def cached(ttl: float = 300, key=None):
    """Decorator: cache function result for `ttl` seconds.

    Pass `key=lambda *a, **kw: ...` to derive the cache key from the arguments —
    use this when an arg is large/unhashable (e.g. the snapshot dict) so the key
    stays small instead of stringifying the whole object.
    """

    def decorator(func):
        @wraps(func)
        def wrapper(*args, **kwargs):
            if key is not None:
                cache_key = f"{func.__name__}:{key(*args, **kwargs)}"
            else:
                cache_key = ":".join([func.__name__, str(args), str(sorted(kwargs.items()))])

            now = time.time()
            with _lock:
                hit = _store.get(cache_key)
                if hit is not None and now < hit[0]:
                    return hit[1]

            # Coalesce concurrent misses. A page can request several related
            # views together, and those views often share expensive analytics.
            with _lock:
                event = _inflight.get(cache_key)
                if event is None:
                    event = threading.Event()
                    _inflight[cache_key] = event
                    owner = True
                else:
                    owner = False

            if not owner:
                event.wait()
                with _lock:
                    hit = _store.get(cache_key)
                    if hit is not None and time.time() < hit[0]:
                        return hit[1]
                return wrapper(*args, **kwargs)

            try:
                result = func(*args, **kwargs)
                with _lock:
                    now = time.time()
                    _store[cache_key] = (now + ttl, result)
                    _evict_locked(now)
                return result
            finally:
                with _lock:
                    _inflight.pop(cache_key, None)
                    event.set()

        wrapper.cache_clear = lambda: _clear_prefix(func.__name__)
        return wrapper

    return decorator


def _evict_locked(now: float) -> None:
    """Reclaim space once the store is over budget. Caller must hold `_lock`.

    Expired entries go first; in normal operation that is the whole job, since
    what accumulates is the 30s snapshot-keyed analytics.

    If everything is still live, the entries closest to expiring are shed — not
    the oldest-inserted. Insertion order would evict exactly the wrong things:
    the 12h lab/api results are written once, early, and are the only ones whose
    recomputation costs a network fetch, whereas a short TTL marks a value the
    caller already expects to recompute shortly and that is pure CPU to rebuild.
    """
    if len(_store) <= _MAX_ENTRIES:
        return
    for key in [key for key, (expires, _) in _store.items() if expires <= now]:
        del _store[key]
    if len(_store) <= _MAX_ENTRIES:
        return
    doomed = sorted(_store, key=lambda k: _store[k][0])[: len(_store) - _MAX_ENTRIES]
    for key in doomed:
        del _store[key]


def _clear_prefix(prefix: str) -> None:
    """Clear every cache entry belonging to one function.

    Keys are ``f"{func.__name__}:{...}"``, so the separator is part of the match:
    clearing `api_returns` must not also wipe a future `api_returns_summary`.
    """
    owned = f"{prefix}:"
    with _lock:
        to_delete = [k for k in _store if k.startswith(owned)]
        for k in to_delete:
            del _store[k]


def clear_all() -> None:
    """Clear the entire cache. Call after any data refresh."""
    with _lock:
        _store.clear()


def cache_size() -> int:
    """Number of cached entries (for debugging)."""
    return len(_store)
