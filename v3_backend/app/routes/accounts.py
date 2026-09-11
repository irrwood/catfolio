"""Account management APIs; demo requests never touch credentials or live data."""
from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field, StrictBool
from app.data_store import demo_mode, public_demo_mode
from app.brokers import accounts

router = APIRouter(prefix='/api/accounts', tags=['accounts'])


def writable():
    if demo_mode() or public_demo_mode():
        raise HTTPException(403, '演示模式下无法修改或同步真实账户。')


def run(fn, *args, **kwargs):
    writable()
    try:
        return fn(*args, **kwargs)
    except ValueError as exc:
        raise HTTPException(400, str(exc)) from None


class Connection(BaseModel):
    id: str | None = None
    name: str = Field(min_length=1, max_length=80)
    provider: str
    config: dict[str, str] = Field(default_factory=dict)
    replaces_account: str | None = None


class Update(BaseModel):
    name: str | None = Field(default=None, min_length=1, max_length=80)
    selected: StrictBool | None = None


class Preview(BaseModel):
    csv_text: str | None = Field(default=None, max_length=5 * 1024 * 1024)


class Confirmation(BaseModel):
    token: str = Field(min_length=1, max_length=100)


class LegacyScope(BaseModel):
    name: str
    selected: StrictBool


@router.get('')
def list_accounts():
    if demo_mode() or public_demo_mode():
        return {'accounts': [], 'legacy': [], 'demo': True}
    return accounts.account_state()


@router.post('/connection')
def save_connection(body: Connection):
    return run(accounts.save_connection, body.id, body.name, body.provider, body.config, body.replaces_account)


@router.post('/legacy-scope')
def legacy_scope(body: LegacyScope):
    run(accounts.update_legacy, body.name, body.selected)
    return {'ok': True}


@router.post('/{account_id}/preview')
def preview(account_id: str, body: Preview = Preview()):
    return run(accounts.preview, account_id, body.csv_text)


@router.post('/{account_id}/sync')
def sync(account_id: str, body: Confirmation):
    return run(accounts.commit, account_id, body.token)


@router.post('/{account_id}')
def update(account_id: str, body: Update):
    return run(accounts.update_account, account_id, body.name, body.selected)


@router.delete('/{account_id}')
def delete(account_id: str):
    run(accounts.delete_account, account_id)
    return {'ok': True}
