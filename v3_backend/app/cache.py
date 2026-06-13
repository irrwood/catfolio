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

import threading
import time
from functools import wraps

_store: dict[str, tuple[float, object]] = {}
# Sync routes run in Starlette's threadpool, so _store can be touched by
# concurrent threads. Dict ops are atomic under the GIL, but the lock guards
# the read/expiry/write critical section. Function execution happens OUTSIDE
# the lock, so parallel cache misses still compute in parallel (a brief double
# compute on a miss is harmless and far cheaper than serializing all work).
_lock = threading.Lock()


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

            result = func(*args, **kwargs)
            with _lock:
                _store[cache_key] = (now + ttl, result)
            return result

        wrapper.cache_clear = lambda: _clear_prefix(func.__name__)
        return wrapper

    return decorator


def _clear_prefix(prefix: str) -> None:
    """Clear all cache entries whose key starts with a given prefix."""
    with _lock:
        to_delete = [k for k in _store if k.startswith(prefix)]
        for k in to_delete:
            del _store[k]


def clear_all() -> None:
    """Clear the entire cache. Call after any data refresh."""
    with _lock:
        _store.clear()


def cache_size() -> int:
    """Number of cached entries (for debugging)."""
    return len(_store)
