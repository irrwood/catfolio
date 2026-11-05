"""Render bilingual, static support and privacy pages. No tracking or forms."""
from html import escape
from pathlib import Path

ROOT = Path(__file__).resolve().parent
CONTACT = "irrwood@gmail.com"

def render_page(name, locale, title, lead, content):
    zh = locale == 'zh-CN'
    suffix = '-zh' if zh else ''
    home = '/zh' if zh else '/'
    switch = f'/{name}' if zh else f'/{name}-zh'
    contact = f'<a href="mailto:{CONTACT}">{CONTACT}</a>'
    html = f'''<!doctype html>
<html lang="{locale}"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>{title} — Catfolio</title><meta name="description" content="{escape(lead, quote=True)}">
<meta property="og:image" content="https://catfolio.app/assets/social-preview-v2.jpg">
<meta property="og:image:alt" content="Catfolio, a multi-broker portfolio tracker. App preview on Mac, iPad, and iPhone.">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta property="og:image:type" content="image/jpeg">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:image" content="https://catfolio.app/assets/social-preview-v2.jpg">
<meta name="twitter:image:alt" content="Catfolio, a multi-broker portfolio tracker. App preview on Mac, iPad, and iPhone.">
<link rel="icon" href="/assets/cat.svg" type="image/svg+xml"><link rel="stylesheet" href="/style.css"><link rel="stylesheet" href="/legal.css">
<link rel="alternate" hreflang="en" href="/{name}"><link rel="alternate" hreflang="zh-CN" href="/{name}-zh"></head><body>
<a class="skip" href="#main">{'跳转到内容' if zh else 'Skip to content'}</a>
<header class="header wrap legal-header"><a class="brand" href="{home}"><img src="/assets/cat.svg" width="36" height="36" alt="">catfolio.</a><nav aria-label="{'主导航' if zh else 'Main navigation'}"><a href="/support{suffix}">{'支持' if zh else 'Support'}</a><a href="/privacy{suffix}">{'隐私政策' if zh else 'Privacy'}</a><a href="{switch}" lang="{'en' if zh else 'zh-CN'}">{'English' if zh else '简体中文'}</a></nav></header>
<main id="main" class="wrap document"><p class="eyebrow">CATFOLIO</p><h1>{title}</h1><p class="lead">{lead}</p>
{content.replace('CONTACT_LINK', contact)}
</main><footer class="wrap"><a class="brand" href="{home}">catfolio.</a><p>© 2026 Catfolio</p><a href="/support{suffix}">{'支持' if zh else 'Support'}</a><a href="/privacy{suffix}">{'隐私政策' if zh else 'Privacy Policy'}</a></footer></body></html>'''
    (ROOT / f'{name}{suffix}.html').write_text(html)

def render():
    render_page('support', 'en', 'Support', 'A little help, whenever you need it.', '''
<div class="note"><p>Contact Ian Zhao at CONTACT_LINK for help with Catfolio, feedback or privacy requests. Please write in English or Simplified Chinese.</p></div>
<h2>Early-bird experience</h2><p>Welcome to Catfolio's first App Store release. During this launch phase, the app's currently available features are free to use. Your feedback helps improve the experience. This offer does not promise permanent free access or include future paid features. Third-party market-data and AI accounts, subscriptions and usage fees are separate.</p>
<h2>Getting started</h2><ol><li>On first launch, you can choose “Set up later” on the market-data and AI setup screen. Configure providers later from Account → Settings → Providers.</li><li>From Account, use the + button to add a supported broker connection or import a compatible CSV file. Connections are read-only; supported accounts and data depend on the provider.</li><li>To explore without connecting a brokerage account, open Account → Select investors, choose “Test data” (the fictional demo portfolio), and enable “Pelosi mode” on the Account page. Demo figures are fictional and separate from your personal records.</li></ol>
<h2>Quotes or returns look different</h2><p>Check the selected account, display currency, date range and data timestamps. Refresh the portfolio and review Account → Settings → Data source status. Quotes, extended-hours coverage, foreign-exchange rates and imported transaction histories can differ by source. Compare important amounts with your broker's official records.</p>
<h2>AI and provider connections</h2><p>Some features need your own provider account or API key. Check the key, permissions, credits and service availability in the provider's official dashboard. Remote AI receives your request and relevant context. Its output may be wrong; verify important claims and sources. Removing a key in Catfolio does not cancel a provider subscription.</p>
<h2>Report a problem</h2><p>Email CONTACT_LINK with your Catfolio version, iOS version, device model, the steps you took and what you expected to happen. A screenshot with personal information removed can help. Never send passwords, API keys, access tokens, account numbers or an unredacted financial statement.</p>
<h2>Manage your data</h2><p>See our <a href="/privacy#choices">privacy choices</a> for local records, AI conversations, credentials and connected services. Keep a backup before resetting data.</p>
<h2>About Catfolio</h2><p>Catfolio is a portfolio tracking and research tool. It does not place trades or transfer funds. Data and AI output are not investment or tax advice. Live features require internet access; third-party services may be delayed or unavailable.</p>
''')
    render_page('support', 'zh-CN', '支持与帮助', '遇到问题，欢迎告诉我们。', '''
<div class="note"><p>如需使用帮助、提交反馈或提出隐私请求，请联系 Ian Zhao：CONTACT_LINK。支持简体中文与英文。</p></div>
<h2>早鸟体验说明</h2><p>欢迎使用 Catfolio 的第一个 App Store 版本。首发阶段，当前已提供的功能免费开放，欢迎反馈，帮助我们持续改进体验。早鸟体验不代表永久免费，也不包含未来可能推出的付费功能。第三方行情、AI 等服务的账号、订阅和使用费用由相应服务商另行收取。</p>
<h2>开始使用</h2><ol><li>首次打开时，可以在“配置行情与 AI”页面选择“稍后设置”，之后到“账户 → 设置 → 服务商”按需配置。</li><li>在“账户”页点击右上角 +，添加受支持的券商连接或导入兼容的 CSV 文件。连接为只读，支持的账户与数据范围取决于服务商。</li><li>想先体验界面，可以到“账户 → 选择人物”选择“测试数据”（完全虚构的演示组合），再开启账户页的“佩洛西模式”开关。演示数据与个人真实记录分开，不代表真实投资表现。</li></ol>
<h2>行情或收益与预期不同</h2><p>请先核对所选账户、显示货币、时间范围和数据时间，刷新组合，并查看“账户 → 设置 → 数据源状态”。不同来源的行情、盘前盘后覆盖、汇率与导入交易记录可能不同。重要金额请以券商的正式记录为准。</p>
<h2>AI 或服务商连接问题</h2><p>部分功能需要你自己的服务商账号或 API Key。请在服务商官方控制台核对密钥、权限、额度和服务状态。远程 AI 会接收问题和相关上下文，输出可能出错，请核对重要结论及来源。在 Catfolio 移除密钥不会取消第三方订阅。</p>
<h2>提交问题反馈</h2><p>请向 CONTACT_LINK 发送 Catfolio 版本、iOS 版本、设备型号、操作步骤以及预期结果。可附上已遮挡个人信息的截图。请勿发送密码、API Key、访问令牌、账户号码或未脱敏的金融账单。</p>
<h2>管理数据</h2><p>有关本地记录、AI 对话、凭据和服务商数据，请查看<a href="/privacy-zh#choices">隐私选择</a>。重置前请保留需要的备份。</p>
<h2>关于 Catfolio</h2><p>Catfolio 用于组合跟踪与研究，不提供下单或转账。数据与 AI 内容不构成投资或税务建议。联网功能需要网络，第三方数据和服务可能延迟或暂时不可用。</p>
''')
    render_page('privacy', 'en', 'Privacy Policy', 'How Catfolio handles your information, and the choices you have.', '''
<p class="updated">Effective and last updated: 13 October 2026</p>
<p>This policy covers the Catfolio iOS app and this support website. Catfolio is published by Qian Zhao. For privacy questions or requests, contact Ian Zhao at CONTACT_LINK.</p>
<h2>1. Your portfolio on your device</h2><p>Holdings, transactions, balances, cost records, imported CSV data and calculated returns are stored and processed locally by the app. CSV parsing takes place on your device. Catfolio does not require a Catfolio account or upload your entire ledger to a Catfolio portfolio server. Local AI conversations and generated reports may also be saved on your device.</p>
<h2>2. Connections you choose</h2><p>When you connect a broker or an account-connection provider, that service processes the authorization, account identifiers and financial records needed to provide the connection. Examples supported by the app include Trading 212, Moomoo, IBKR and SnapTrade. The app retrieves authorized records to build your local portfolio. Credentials and access tokens are stored in the device's Keychain and used with the relevant service. These connections do not enable Catfolio to place orders or transfer money.</p>
<p>Market-data, company-information, news, logo and exchange-rate requests send the relevant symbols, search terms and normal network information, such as an IP address, to their sources. These include services such as Yahoo Finance, Massive, Financial Modeling Prep, Nasdaq, SEC EDGAR and Brandfetch, depending on the feature. Service availability and provider settings determine which sources are contacted.</p>
<h2>3. Optional AI</h2><p>When you choose a remote AI service, Catfolio sends your question, relevant conversation history and the portfolio or research context needed for the requested analysis to that service. Context can include securities, portfolio weights, amounts or other financial details relevant to the feature. Providers may include OpenAI, OpenRouter, DeepSeek or Cloudflare, according to your configuration. Requests may be associated with your provider account or API credentials. The provider's own privacy policy, retention and processing terms apply; Catfolio cannot promise that a remote provider never retains requests or uses them for its own permitted purposes.</p>
<p>On-device model features run on a supported device, but retrieving source material may still require network requests. You can use portfolio tracking without configuring a remote AI service. Avoid including unnecessary personal or sensitive information in prompts.</p>
<h2>4. iCloud, exports and backups</h2><p>If you enable iCloud preference sync, selected preferences are sent to Apple's iCloud. This preference sync excludes portfolio ledgers and broker credentials. Device backups, files you export and copies you place in iCloud Drive or another storage service are separate and governed by your device and storage settings. Shared or exported files leave the app only when you choose that action.</p>
<h2>5. Support and website information</h2><p>If you email us, we receive your email address, message and any attachments you choose to send. We use them to answer your request and investigate the problem. We keep support correspondence for as long as needed to resolve the request and meet applicable obligations; you can request deletion. Please send only information necessary for support.</p>
<p>This website is hosted by Vercel. Hosting and delivery may process network and request information, including IP addresses, requested URLs and browser information, for delivery, security and operational logs. This website does not add advertising trackers or a marketing analytics SDK.</p>
<h2>6. Use, sharing and security</h2><p>Catfolio does not sell your personal information or use it for cross-app advertising tracking. Information is used to provide the features you request, maintain service security and answer support requests. Selected third-party providers process data under their own policies and may operate in other countries. Information may also be disclosed where required by law.</p>
<p>The app uses iOS file protection for local portfolio data, Keychain for credentials and HTTPS for network services. No storage or transmission method can be guaranteed completely secure. Protect your device and provider accounts, and revoke credentials you no longer use.</p>
<h2 id="choices">7. Your choices and deletion</h2><ul><li>Review or remove a local account from its account detail page. Use Account → Settings → Reset local portfolio data when you intend to reset your personal ledger; review the confirmation and retain any backup you need.</li><li>Manage saved AI conversations from the AI conversation list. Deleting a local conversation does not delete a provider's copy.</li><li>Remove saved API keys in Settings → Providers. Disconnect linked accounts and revoke permissions in the provider's dashboard when appropriate. Local removal does not cancel a third-party subscription or delete the provider's records.</li><li>Turn off preference sync in the app's iCloud settings. Manage existing iCloud data, device backups and exported files through Apple's or your storage provider's controls.</li><li>For support correspondence or data you have sent directly to us, contact CONTACT_LINK to request access, correction or deletion. Requests about records held by a broker or AI provider should also be directed to that provider.</li></ul>
<h2>8. Children and updates</h2><p>Catfolio is not designed specifically for children. If you believe a child has sent us personal information, contact us so we can investigate and handle it appropriately. We update this policy when our data practices change; the date above identifies the current version. Material changes will be communicated through an appropriate app or website notice.</p>
''')
    render_page('privacy', 'zh-CN', '隐私政策', '了解 Catfolio 如何处理信息，以及你可以作出的选择。', '''
<p class="updated">生效及最近更新日期：2026 年 10 月 13 日</p>
<p>本政策适用于 Catfolio iOS App 和本支持网站。Catfolio 由 Qian Zhao 发布。如有隐私问题或请求，请联系 Ian Zhao：CONTACT_LINK。</p>
<h2>1. 设备上的组合账本</h2><p>App 在本地保存并处理持仓、交易、余额、成本、导入的 CSV 数据及计算后的收益。CSV 在设备本机解析。Catfolio 不要求注册 Catfolio 账号，也不会将完整账本上传到 Catfolio 的组合服务器。本地 AI 对话和生成的报告也可能保存在设备上。</p>
<h2>2. 你选择的联网服务</h2><p>连接券商或账户连接服务时，相应服务商会处理完成授权与连接所需的账户标识及金融记录。App 支持的例子包括 Trading 212、Moomoo、IBKR 和 SnapTrade。App 读取已授权的记录并建立本地组合。凭据和访问令牌保存在设备 Keychain，向相应服务使用。这些连接不允许 Catfolio 下单或转账。</p>
<p>行情、公司资料、新闻、Logo 和汇率请求会向相应来源发送证券代码、搜索词和 IP 地址等正常网络请求信息。根据功能，来源可能包括 Yahoo Finance、Massive、Financial Modeling Prep、Nasdaq、SEC EDGAR 和 Brandfetch。实际联系哪些来源取决于功能、服务可用性与配置。</p>
<h2>3. 可选的 AI 服务</h2><p>当你选择远程 AI 服务时，Catfolio 会向该服务发送问题、相关对话历史，以及完成所请求分析所需的组合或研究上下文。根据具体功能，上下文可能包括证券、持仓权重、金额或其他相关金融信息。可配置的服务包括 OpenAI、OpenRouter、DeepSeek 或 Cloudflare 等。请求可能与服务商账号或 API 凭据关联。服务商自己的隐私政策、保存期限及处理条款适用；Catfolio 无法承诺远程服务商不保留请求，或不将其用于服务商条款允许的用途。</p>
<p>设备端模型在受支持的设备上运行，但获取来源资料仍可能需要联网。你可以不配置远程 AI 而使用组合跟踪。请避免在问题中包含不必要的个人或敏感信息。</p>
<h2>4. iCloud、导出和备份</h2><p>开启 iCloud 偏好同步后，选定的偏好设置会发送到 Apple iCloud。此项偏好同步不包含组合账本与券商凭据。设备备份、导出文件，以及你自行放入 iCloud Drive 或其他存储服务的副本属于不同机制，取决于设备与存储设置。分享或导出文件由你主动发起。</p>
<h2>5. 支持联系与网站信息</h2><p>通过邮件联系我们时，我们会收到你提供的邮箱地址、消息及附件，用于答复请求和排查问题。支持通信在解决请求及履行适用义务所需的期间内保留，你可以请求删除。请仅提供支持所必需的信息。</p>
<p>本网站由 Vercel 托管。托管和网络分发可能为页面交付、安全与运行日志处理 IP 地址、请求网址及浏览器信息等网络请求数据。本网站没有额外加入广告追踪器或营销分析 SDK。</p>
<h2>6. 使用、共享与安全</h2><p>Catfolio 不出售你的个人信息，也不将其用于跨 App 广告追踪。信息用于提供你请求的功能、维护服务安全和处理支持请求。你选择的第三方服务商按各自政策处理数据，并可能在其他国家或地区运营。法律要求时，也可能需要披露相关信息。</p>
<p>App 使用 iOS 文件保护保存本地组合数据，使用 Keychain 保存凭据，通过 HTTPS 访问网络服务。任何存储或传输方式均无法保证绝对安全。请保护设备和服务商账号，及时撤销不再使用的凭据。</p>
<h2 id="choices">7. 你的选择与删除方式</h2><ul><li>在账户详情页查看或移除本地账户。如需重置个人账本，使用“账户 → 设置 → 重置本机组合数据”，阅读确认内容并保留需要的备份。</li><li>在 AI 对话列表管理已保存的对话。删除本地对话不会删除服务商保存的副本。</li><li>在“设置 → 服务商”移除 API Key。必要时在服务商控制台断开账户、撤销授权。移除本地信息不会取消第三方订阅或删除服务商记录。</li><li>在 App 的 iCloud 设置中关闭偏好同步。已存在的 iCloud 数据、设备备份和导出文件需要通过 Apple 或所用存储服务的功能管理。</li><li>对于支持通信或你直接发送给我们的信息，可以通过 CONTACT_LINK 请求访问、更正或删除。券商和 AI 服务商保存的记录也需要向相应服务商提出请求。</li></ul>
<h2>8. 儿童与政策更新</h2><p>Catfolio 并非专为儿童设计。如你认为儿童已向我们提供个人信息，请联系我们，以便调查并妥善处理。数据处理方式变化时，我们会更新本政策；页首日期表示当前版本。重大变化会通过适当的 App 或网站通知告知。</p>
''')

if __name__ == '__main__':
    render()
