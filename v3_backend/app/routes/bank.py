"""Page and local-demo APIs for bank analytics."""

from fastapi import APIRouter, Request
from fastapi.responses import HTMLResponse, JSONResponse

from app.banking import (
    DEMO_EMAIL_OPPORTUNITIES,
    DEMO_TRANSACTIONS,
    demo_overview,
    detect_subscriptions,
    match_refunds,
)
from app.components import render_layout
from app.i18n import get_lang


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
      <span class="bank-local-badge"><span aria-hidden="true"></span>Demo · 本地分析</span>
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
        <button id="scanEmailBtn" class="bank-button bank-button-primary" type="button">扫描 Demo 邮件</button>
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
          <p>使用只读 OAuth 权限扫描退款线索。</p>
        </div>
        <button class="bank-dialog-close" value="cancel" aria-label="关闭">×</button>
      </header>
      <button class="bank-provider-option" type="button" data-mail-provider="Gmail">
        <span><strong>Gmail</strong><small>只读取匹配的订单、行程与退款邮件</small></span>
        <em>选择</em>
      </button>
      <button class="bank-provider-option" type="button" data-mail-provider="Outlook">
        <span><strong>Outlook</strong><small>只读 Microsoft Graph 邮件权限</small></span>
        <em>选择</em>
      </button>
      <p id="emailProviderNotice" class="bank-dialog-notice">Demo 不会读取本机或云端邮箱。正式连接需要用户单独授权。</p>
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
    return JSONResponse(demo_overview())


@router.post("/api/bank/scan-subscriptions")
def bank_scan_subscriptions_api():
    items = detect_subscriptions(DEMO_TRANSACTIONS)
    return JSONResponse({"ok": True, "source": "demo", "count": len(items), "items": items})


@router.post("/api/bank/scan-refunds")
def bank_scan_refunds_api():
    items = match_refunds(DEMO_TRANSACTIONS)
    return JSONResponse(
        {
            "ok": True,
            "source": "demo",
            "count": len(items),
            "recovered": round(sum(item["amount"] for item in items), 2),
            "items": items,
        }
    )


@router.post("/api/bank/scan-email")
def bank_scan_email_api():
    return JSONResponse(
        {
            "ok": True,
            "source": "demo",
            "count": len(DEMO_EMAIL_OPPORTUNITIES),
            "items": DEMO_EMAIL_OPPORTUNITIES,
        }
    )
