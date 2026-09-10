"""Bank page, local-first analytics APIs, and the Python Plaid adapter routes."""

import json

from fastapi import APIRouter, BackgroundTasks, Request
from fastapi.responses import HTMLResponse, JSONResponse

from app.banking import (
    DEMO_EMAIL_OPPORTUNITIES,
)
from app.bank_crypto import TokenEncryptionError
from app.bank_service import get_bank_service
from app.components import render_layout
from app.data_store import demo_mode, public_demo_mode
from app.i18n import get_lang
from app.imap_mail_adapter import MailConfigurationError, MailConnectionError
from app.mail_service import MailSecretError, get_mail_service
from app.plaid_adapter import (
    PlaidApiError,
    PlaidConfigurationError,
    PlaidWebhookVerificationError,
)


router = APIRouter(tags=["bank"])


@router.get("/bank")
def bank_page(request: Request):
    content = """<main class="bank-page">
  <header class="bank-head">
    <div>
      <h1>银行</h1>
      <p>把现金账户、固定订阅、退款和可追回款项放在一起分析。</p>
    </div>
    <div class="bank-head-actions">
      <span id="bankConnectionBadge" class="bank-local-badge"><span aria-hidden="true"></span>Demo · 本地分析</span>
      <button id="bankSyncBtn" class="bank-button" type="button" hidden>同步交易</button>
      <button class="bank-button" type="button" data-open-dialog="bankConnectDialog">连接银行</button>
    </div>
  </header>

  <section class="bank-metrics" aria-label="银行概览">
    <article class="bank-metric">
      <span>账户总余额</span>
      <strong id="bankTotalBalance">—</strong>
      <small id="bankAccountCount">正在读取账户</small>
    </article>
    <article class="bank-metric">
      <span>本月净现金流</span>
      <strong id="bankNetCashFlow">—</strong>
      <small>收入减支出</small>
    </article>
    <article class="bank-metric">
      <span>每月固定订阅</span>
      <strong id="bankSubscriptionCost">—</strong>
      <small>点击下方按钮重新识别</small>
    </article>
    <article class="bank-metric">
      <span>已匹配退款</span>
      <strong id="bankRefundsRecovered">—</strong>
      <small>相同商家 · 相同金额</small>
    </article>
  </section>

  <section class="bank-overview">
    <div class="bank-cash-flow">
      <header class="bank-section-head">
        <div>
          <h2>现金流</h2>
          <p>最近 6 个月收入和支出</p>
        </div>
        <div class="bank-chart-legend" aria-label="现金流图例">
          <span><i class="income"></i>收入</span>
          <span><i class="spend"></i>支出</span>
        </div>
      </header>
      <div id="bankCashFlowChart" class="bank-cash-flow-chart" role="img" aria-label="最近六个月收入和支出柱状图"></div>
    </div>
    <aside class="bank-accounts" aria-labelledby="bankAccountsTitle">
      <header class="bank-section-head">
        <div>
          <h2 id="bankAccountsTitle">银行账户</h2>
          <p>只显示银行返回的可用余额</p>
        </div>
      </header>
      <div id="bankAccountList" class="bank-account-list"></div>
    </aside>
  </section>

  <section class="bank-detection">
    <header class="bank-section-head bank-detection-head">
      <div>
        <h2>智能识别</h2>
        <p>扫描只在当前工作区运行；确认前不会修改或提交任何内容。</p>
      </div>
      <div class="bank-scan-actions">
        <button id="scanSubscriptionsBtn" class="bank-button bank-button-primary" type="button">
          一键识别订阅
        </button>
        <button id="scanRefundsBtn" class="bank-button" type="button">
          一键识别退款
        </button>
      </div>
    </header>

    <div class="bank-detection-grid">
      <section class="bank-result-pane" aria-labelledby="subscriptionsTitle">
        <header class="bank-result-title">
          <div>
            <h3 id="subscriptionsTitle">固定订阅</h3>
            <p>按商家、金额和扣款周期识别</p>
          </div>
          <span id="subscriptionCount" class="bank-count">未扫描</span>
        </header>
        <div id="subscriptionList" class="bank-result-list">
          <div class="bank-empty">点击“一键识别订阅”开始扫描。</div>
        </div>
      </section>

      <section class="bank-result-pane" aria-labelledby="refundsTitle">
        <header class="bank-result-title">
          <div>
            <h3 id="refundsTitle">退款配对</h3>
            <p>消费与退款合并为一条记录</p>
          </div>
          <span id="refundCount" class="bank-count">未扫描</span>
        </header>
        <div id="refundList" class="bank-result-list">
          <div class="bank-empty">点击“一键识别退款”查找相同商家和金额。</div>
        </div>
      </section>
    </div>
  </section>

  <section class="bank-email">
    <header class="bank-section-head bank-email-head">
      <div>
        <h2>邮件退款机会</h2>
        <p>从行程取消、火车延误和航班延误邮件中寻找可能尚未申请的退款。</p>
      </div>
      <div class="bank-email-actions">
        <span class="bank-mail-status">邮箱未连接</span>
        <button class="bank-button" type="button" data-open-dialog="emailConnectDialog">连接邮箱</button>
        <button id="scanEmailBtn" class="bank-button bank-button-primary" type="button">扫描邮件</button>
      </div>
    </header>
    <div class="bank-email-privacy">
      <strong>隐私边界</strong>
      <span>只读取你主动授权的订单和行程邮件；显示证据后由你确认，绝不自动提交索赔。</span>
    </div>
    <div id="emailOpportunityList" class="bank-email-list">
      <div class="bank-empty">连接邮箱后扫描，或先用 Demo 邮件预览识别效果。</div>
    </div>
  </section>

  <dialog id="bankConnectDialog" class="bank-dialog">
    <form method="dialog">
      <header>
        <div>
          <h2>连接银行</h2>
          <p>选择受监管的数据连接服务商。</p>
        </div>
        <button class="bank-dialog-close" value="cancel" aria-label="关闭">×</button>
      </header>
      <button class="bank-provider-option is-recommended" type="button" data-provider="TrueLayer">
        <span><strong>TrueLayer</strong><small>英国账户和信用卡 · 推荐</small></span>
        <em>选择</em>
      </button>
      <button class="bank-provider-option" type="button" data-provider="Plaid">
        <span><strong>Plaid</strong><small>银行覆盖广，支持交易分类</small></span>
        <em>选择</em>
      </button>
      <p id="bankProviderNotice" class="bank-dialog-notice">Demo 不会发起真实授权。正式连接需要先配置服务商 Client ID、Secret 和回调地址。</p>
    </form>
  </dialog>

  <dialog id="emailConnectDialog" class="bank-dialog">
    <form method="dialog">
      <header>
        <div>
          <h2>连接邮箱</h2>
          <p>通过开源 imap-tools 直连邮箱；Catfolio 强制以只读方式打开收件箱。</p>
        </div>
        <button class="bank-dialog-close" value="cancel" aria-label="关闭">×</button>
      </header>
      <button class="bank-provider-option" type="button" data-mail-provider="gmail">
        <span><strong>Gmail</strong><small>应用专用密码或 OAuth2 · imap.gmail.com</small></span>
        <em>选择</em>
      </button>
      <button class="bank-provider-option" type="button" data-mail-provider="outlook">
        <span><strong>Outlook</strong><small>OAuth2 · outlook.office365.com</small></span>
        <em>选择</em>
      </button>
      <button class="bank-provider-option" type="button" data-mail-provider="imap">
        <span><strong>其他 IMAP</strong><small>支持应用专用密码或 OAuth2 的邮箱</small></span>
        <em>选择</em>
      </button>
      <div id="emailConnectFields" class="bank-mail-connect-fields" hidden>
        <label>
          <span>邮箱地址</span>
          <input id="mailEmail" class="bank-dialog-input" type="email" autocomplete="username" placeholder="name@example.com" />
        </label>
        <label>
          <span>认证方式</span>
          <select id="mailAuthType" class="bank-dialog-input">
            <option value="password">应用专用密码</option>
            <option value="oauth2">OAuth2 Access Token</option>
          </select>
        </label>
        <label id="mailHostField" hidden>
          <span>IMAP 服务器</span>
          <input id="mailHost" class="bank-dialog-input" type="text" inputmode="url" placeholder="imap.example.com" />
        </label>
        <label>
          <span id="mailCredentialLabel">应用专用密码</span>
          <input id="mailCredential" class="bank-dialog-input" type="password" autocomplete="current-password" />
        </label>
        <button id="mailConnectBtn" class="bank-button bank-button-primary" type="button">测试并连接</button>
      </div>
      <p id="emailProviderNotice" class="bank-dialog-notice">凭证只写入系统 Keychain；SQLite 仅保存邮箱地址、UID 游标和识别结果，不保存原始正文。</p>
    </form>
  </dialog>
</main>

<script src="/static/bank.js"></script>"""

    return HTMLResponse(
        render_layout(
            request,
            "银行",
            content,
            "/bank",
            get_lang(request),
            head_extra='<link rel="stylesheet" href="/static/bank.css" />',
        )
    )


@router.get("/api/bank/overview")
def bank_overview_api():
    return JSONResponse(get_bank_service().overview())


@router.post("/api/bank/scan-subscriptions")
def bank_scan_subscriptions_api():
    return JSONResponse(get_bank_service().scan_subscriptions())


@router.post("/api/bank/scan-refunds")
def bank_scan_refunds_api():
    return JSONResponse(get_bank_service().scan_refunds())


@router.post("/api/bank/scan-email")
def bank_scan_email_api():
    if demo_mode() or public_demo_mode():
        return JSONResponse(
            {
                "ok": True,
                "source": "demo",
                "count": len(DEMO_EMAIL_OPPORTUNITIES),
                "items": DEMO_EMAIL_OPPORTUNITIES,
            }
        )
    try:
        return JSONResponse(get_mail_service().sync_all())
    except Exception as exc:
        return _mail_error_response(exc)


def _mail_error_response(exc: Exception) -> JSONResponse:
    if isinstance(exc, PermissionError):
        return JSONResponse({"ok": False, "error": str(exc)}, status_code=403)
    if isinstance(exc, (ValueError, MailConfigurationError)):
        return JSONResponse({"ok": False, "error": str(exc)}, status_code=400)
    if isinstance(exc, MailConnectionError):
        return JSONResponse({"ok": False, "error": str(exc)}, status_code=502)
    if isinstance(exc, MailSecretError):
        return JSONResponse({"ok": False, "error": str(exc)}, status_code=500)
    return JSONResponse(
        {"ok": False, "error": "邮箱连接暂时不可用。"}, status_code=500
    )


@router.get("/api/mail/status")
def mail_status_api():
    if demo_mode() or public_demo_mode():
        return JSONResponse(
            {
                "ok": True,
                "connected": False,
                "source": "demo",
                "accounts": [],
            }
        )
    return JSONResponse({"ok": True, **get_mail_service().status()})


@router.post("/api/mail/connect")
async def mail_connect_api(request: Request):
    try:
        body = await request.json()
        result = get_mail_service().connect(
            provider=str(body.get("provider") or "imap"),
            email=str(body.get("email") or ""),
            username=str(body.get("username") or ""),
            credential=str(body.get("credential") or ""),
            auth_type=str(body.get("auth_type") or "password"),
            host=str(body.get("host") or ""),
            port=int(body.get("port") or 993),
        )
        return JSONResponse({"ok": True, **result})
    except Exception as exc:
        return _mail_error_response(exc)


@router.post("/api/mail/sync")
def mail_sync_api():
    try:
        return JSONResponse(get_mail_service().sync_all())
    except Exception as exc:
        return _mail_error_response(exc)


@router.delete("/api/mail/accounts/{account_id}")
def mail_remove_api(account_id: str):
    try:
        return JSONResponse(
            {"ok": True, "removed": get_mail_service().remove(account_id)}
        )
    except Exception as exc:
        return _mail_error_response(exc)


def _bank_error_response(exc: Exception) -> JSONResponse:
    if isinstance(exc, PermissionError):
        return JSONResponse({"ok": False, "error": str(exc)}, status_code=403)
    if isinstance(exc, PlaidConfigurationError):
        return JSONResponse(
            {
                "ok": False,
                "error": str(exc),
                "error_code": "PLAID_NOT_CONFIGURED",
            },
            status_code=400,
        )
    if isinstance(exc, (ValueError, KeyError)):
        return JSONResponse({"ok": False, "error": str(exc)}, status_code=400)
    if isinstance(exc, TokenEncryptionError):
        return JSONResponse(
            {"ok": False, "error": "本机 Keychain 无法加密银行连接。"},
            status_code=500,
        )
    if isinstance(exc, PlaidWebhookVerificationError):
        return JSONResponse(
            {"ok": False, "error": "Plaid Webhook 签名验证失败。"},
            status_code=401,
        )
    if isinstance(exc, PlaidApiError):
        return JSONResponse(
            {
                "ok": False,
                "error": str(exc),
                "error_code": exc.error_code,
            },
            status_code=exc.status if exc.status and 400 <= exc.status < 600 else 502,
        )
    return JSONResponse(
        {"ok": False, "error": "银行连接暂时不可用。"},
        status_code=500,
    )


@router.get("/api/bank/status")
def bank_status_api():
    service = get_bank_service()
    return JSONResponse(
        {
            "ok": True,
            "configured": service.plaid_configured(),
            "connected": service.repository.has_connections(),
            "storage": "local-sqlite",
            "token_storage": "aes-256-gcm+keychain",
        }
    )


@router.post("/api/bank/plaid/link-token")
def bank_plaid_link_token_api():
    try:
        result = get_bank_service().create_link_token()
        return JSONResponse({"ok": True, **result})
    except Exception as exc:
        return _bank_error_response(exc)


@router.post("/api/bank/plaid/exchange")
async def bank_plaid_exchange_api(request: Request):
    try:
        body = await request.json()
        result = get_bank_service().exchange_public_token(
            str(body.get("public_token") or ""),
            body.get("metadata") if isinstance(body.get("metadata"), dict) else {},
        )
        return JSONResponse({"ok": True, **result})
    except Exception as exc:
        return _bank_error_response(exc)


@router.post("/api/bank/plaid/sync")
def bank_plaid_sync_api():
    try:
        return JSONResponse(
            {"ok": True, "results": get_bank_service().sync_all()}
        )
    except Exception as exc:
        return _bank_error_response(exc)


@router.post("/api/bank/items/{item_id}/sync")
def bank_item_sync_api(item_id: str):
    try:
        return JSONResponse(
            {"ok": True, "result": get_bank_service().sync_item(item_id)}
        )
    except Exception as exc:
        return _bank_error_response(exc)


@router.post("/api/bank/items/{item_id}/refresh")
def bank_item_refresh_api(item_id: str):
    try:
        return JSONResponse(
            {"ok": True, "result": get_bank_service().refresh_item(item_id)}
        )
    except Exception as exc:
        return _bank_error_response(exc)


@router.delete("/api/bank/items/{item_id}")
def bank_item_delete_api(item_id: str):
    try:
        removed = get_bank_service().remove_item(item_id)
        return JSONResponse({"ok": removed})
    except Exception as exc:
        return _bank_error_response(exc)


@router.post("/api/bank/plaid/webhook")
async def bank_plaid_webhook_api(
    request: Request, background_tasks: BackgroundTasks
):
    """Record a provider notification; transaction data is still pulled locally."""
    try:
        raw_body = await request.body()
        body = json.loads(raw_body)
        service = get_bank_service()
        signed_jwt = request.headers.get("Plaid-Verification") or ""
        if not signed_jwt:
            raise PlaidWebhookVerificationError(
                "Missing Plaid-Verification header."
            )
        service.verify_webhook(signed_jwt, raw_body)
        result = service.handle_webhook(body)
        if result["should_sync"] and result["item_id"]:
            background_tasks.add_task(
                service.process_webhook_sync,
                result["event_id"],
                result["item_id"],
            )
        return JSONResponse({"ok": True})
    except Exception as exc:
        return _bank_error_response(exc)
