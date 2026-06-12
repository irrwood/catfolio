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

import time
from functools import wraps

_store: dict[str, tuple[float, object]] = {}


def cached(ttl: float = 300):
    """Decorator: cache function result for `ttl` seconds."""

    def decorator(func):
        @wraps(func)
        def wrapper(*args, **kwargs):
            # Build a cache key from function name + args + kwargs
            key_parts = [func.__name__]
            key_parts.append(str(args))
            key_parts.append(str(sorted(kwargs.items())))
            key = ":".join(key_parts)

            now = time.time()
            if key in _store:
                expiry, value = _store[key]
                if now < expiry:
                    return value

            result = func(*args, **kwargs)
            _store[key] = (now + ttl, result)
            return result

        wrapper.cache_clear = lambda: _clear_prefix(func.__name__)
        return wrapper

    return decorator


def _clear_prefix(prefix: str) -> None:
    """Clear all cache entries whose key starts with a given prefix."""
    to_delete = [k for k in _store if k.startswith(prefix)]
    for k in to_delete:
        del _store[k]


def clear_all() -> None:
    """Clear the entire cache. Call after any data refresh."""
    _store.clear()


def cache_size() -> int:
    """Number of cached entries (for debugging)."""
    return len(_store)
