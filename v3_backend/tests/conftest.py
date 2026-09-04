from pathlib import Path
import sys

APP_ROOT = Path(__file__).resolve().parents[1]
if str(APP_ROOT) not in sys.path:
    sys.path.insert(0, str(APP_ROOT))


def app_route_paths(app) -> set[str]:
    """Return all registered route paths, flattening FastAPI >=0.141 lazy
    ``_IncludedRouter`` wrappers introduced when ``include_router`` became lazy."""
    paths: set[str] = set()
    stack = list(app.routes)
    while stack:
        route = stack.pop()
        if hasattr(route, "path"):
            paths.add(route.path)
        elif type(route).__name__ == "_IncludedRouter":
            stack.append(route.original_router)
            try:
                stack.extend(route.effective_candidates())
            except TypeError:
                pass  # not a lazy router variant
    return paths
