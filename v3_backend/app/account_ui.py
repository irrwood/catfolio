"""Server-rendered account settings, using the shared settings primitives."""
from html import escape
import json
from app.account_i18n import EN
from app.brokers.accounts import account_state


def render_accounts(demo):
    if demo:
        body = '<p class="settings-notice">演示模式使用独立样例组合。关闭演示模式后可添加、管理和同步真实账户。</p>'
    else:
        state = account_state()
        rows = []
        for account in state['accounts']:
            checked = 'checked' if account['selected'] else ''
            subtitle = f"{account['positions']} 项持仓" if account['updated_at'] else '等待首次同步'
            rows.append(f'''<div class="account-row">
              <input type="checkbox" class="account-scope" data-account-id="{escape(account['id'])}" {checked} aria-label="计入 {escape(account['name'])}" />
              <button type="button" class="account-open" data-account-id="{escape(account['id'])}"><strong>{escape(account['name'])}</strong><span>{escape(account['provider'])} · {subtitle}</span></button>
              <span aria-hidden="true">›</span></div>''')
        for account in state['legacy']:
            checked = 'checked' if account['selected'] else ''
            rows.append(f'''<div class="account-row">
              <input type="checkbox" class="account-scope" data-legacy="{escape(account['name'])}" {checked} aria-label="计入 {escape(account['name'])}" />
              <div class="settings-row-copy"><strong>{escape(account['name'])}</strong><span>已有持仓 · 可关联独立同步连接</span></div>
              <button type="button" class="settings-button" data-connect-legacy="{escape(account['name'])}">连接账户</button></div>''')
        body = '<div id="accountList">' + (''.join(rows) or '<p class="settings-notice">还没有账户。添加券商连接，预览后即可同步持仓。</p>') + '</div>'
        body += '<div class="account-actions"><button type="button" class="settings-button" id="addAccount">＋ 添加账户</button><button type="button" class="settings-button" id="addCSVAccount">CSV 导入</button></div>'
    translations = json.dumps(EN, ensure_ascii=True).replace('<', '\u003c')
    return '<script type="application/json" id="accountTranslations">' + translations + '</script>' + '''<section class="settings-section" id="settings-accounts">
      <div class="settings-section-header"><h2>账户</h2><p>勾选计入组合的账户，点击账户查看连接和同步状态。</p></div>
      <div class="settings-group settings-group-padded">''' + body + '''</div>
      <div id="accountStatus" class="settings-action-status" role="status" aria-live="polite"></div>
    </section>
    <dialog id="accountDialog" class="account-dialog" aria-labelledby="accountDialogTitle">
      <header class="account-dialog-header"><div><h2 id="accountDialogTitle">添加账户</h2><p id="accountDialogSubtitle">配置连接后预览持仓</p></div><button type="button" class="settings-button" id="closeAccount" aria-label="关闭账户窗口">×</button></header>
      <form id="accountForm">
        <label>账户名称<input class="settings-input" name="name" required maxlength="80" autocomplete="off" placeholder="例如：长期投资" /></label>
        <label>券商<select class="settings-input" name="provider"><option value="trading212">Trading 212</option><option value="moomoo">Moomoo / Futu OpenD</option><option value="ibkr">Interactive Brokers</option><option value="csv">CSV 文件</option></select></label>
        <div id="accountConnectionFields"></div>
        <label id="accountLegacyLabel">关联已有持仓<select class="settings-input" name="replaces_account"><option value="">新账户</option></select></label>
        <p class="settings-notice" id="accountConnectionHint"></p>
        <div class="account-actions"><button class="settings-button" type="submit" id="saveAccount">保存连接</button><button class="settings-button" type="button" id="previewAccount">保存并预览持仓</button></div>
      </form>
      <section id="accountPreview" hidden aria-labelledby="accountPreviewTitle"><h3 id="accountPreviewTitle">确认同步</h3><p id="accountPreviewSummary"></p><div class="account-preview-table"><table class="data-table"><thead><tr><th>持仓</th><th>数量</th><th>成本均价</th><th>币种</th></tr></thead><tbody id="accountPreviewRows"></tbody></table></div><p class="settings-notice" id="accountSyncNotice">确认后只更新此账户。持仓数量为零时会清空此账户的当前持仓；已导入的历史记录保留。预览在 15 分钟后失效。</p><div class="account-actions"><button type="button" class="settings-button" id="confirmAccountSync">确认同步</button><button type="button" class="settings-button" id="cancelAccountPreview">返回修改</button></div></section>
      <div id="accountDialogStatus" role="status" aria-live="polite"></div>
      <footer class="account-actions"><button type="button" class="settings-button" id="deleteAccount" hidden>删除账户</button></footer>
    </dialog>'''
