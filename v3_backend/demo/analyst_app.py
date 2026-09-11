"""Local-only entry point: uvicorn demo.analyst_app:app --host 127.0.0.1 --port 8791."""
from app.main import app
from app.routes.analyst_history import router
app.include_router(router)
