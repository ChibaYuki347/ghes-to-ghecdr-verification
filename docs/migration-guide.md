# GitHub Enterprise Server → GitHub Enterprise Cloud (Data Residency) 移行ガイド

**対象読者**: 現在 GitHub Enterprise Server (GHES) を Volume License で運用し、GitHub Enterprise Cloud with Data Residency (`SUBDOMAIN.ghe.com`) + Metered Billing へ段階的に移行を計画している組織の運用責任者・SRE・セキュリティ担当者。

**前提条件**:
- 現行 GHES は **3.4.1 以上**（GEI 対応の最小バージョン）
- 閉域ネットワーク内に GHES が設置されており、外部通信は HTTP プロキシ経由
- 移行先として **GHE.com の専用サブドメイン**（例: `octocorp.ghe.com`）を採用
- 認証は **Enterprise Managed Users (EMU)** + IdP (OIDC / SAML) 連携

> ⚠️ 本ガイドは情報を整理した参考資料です。実際の移行プロジェクトでは必ず最新の公式ドキュメントを再確認し、トライアル環境での検証を踏まえてから本番移行を実施してください。

---

## 1. 用語集

| 略称 | 正式名 | 補足 |
|---|---|---|
| **GHES** | GitHub Enterprise Server | オンプレ / IaaS で運用する自己ホスト型 |
| **GHEC** | GitHub Enterprise Cloud | GitHub.com 上のエンタープライズ機能 |
| **GHE.com (DR)** | GitHub Enterprise Cloud with Data Residency | 専用サブドメイン `<TENANT>.ghe.com` で提供されるリージョン分離版 GHEC |
| **EMU** | Enterprise Managed Users | 企業 IdP が user account の生成・認証・無効化を管理 |
| **GEI** | GitHub Enterprise Importer | repo / org 単位のマイグレーションツール (CLI / API) |
| **ELM** | Enterprise Live Migrations | repo 移行中も読み書き継続可能な新ツール (GHES 3.17.15+ / 3.18.9+ / 3.19.6+ / 3.20.2+) |
| **GitHub Connect** | — | GHES と GHEC tenant を双方向接続し、License sync / Code search / Dependabot 等を共有 |
| **Metered Billing** | — | License を事前購入せず、アクティブユーザー数で月次課金（GHE.com 標準） |
| **Volume License** | — | 事前購入したシート数で運用（既存 GHES 顧客の標準） |

---

## 2. 移行ゴールと全体像

### 2.1 現状 (As-Is)

```
[社内 IdP] ──SAML/OIDC──┐
                          ▼
                  [GHES (closed network)]
                          │
                  [HTTP Proxy] ──→ Internet (限定的)
                          │
                  Volume License: 事前購入シート数
```

### 2.2 目標 (To-Be)

```
[社内 IdP] ──OIDC/SAML──┐
                          ▼
                  [GHE.com Data Residency]
                  https://<TENANT>.ghe.com
                          │
                  Metered Billing: アクティブユーザー従量課金
```

### 2.3 アーキテクチャ比較

| 項目 | GHES (As-Is) | GHE.com DR (To-Be) |
|---|---|---|
| ホスティング | 自社 / IaaS | GitHub managed |
| データ所在地 | 自社管理 | EU / US / AU / **Japan** から選択 |
| アップグレード | 顧客実施 (3 ヶ月毎の四半期リリース) | GitHub 自動 |
| Bring-Your-Own runner | サポート (self-hosted) | サポート + Azure private networking で region 限定可 |
| 認証 | SAML / LDAP / Built-in | **EMU 必須** (OIDC または SAML) |
| 課金 | Volume License (事前シート購入) | Metered Billing (Azure Subscription または Credit Card) |
| Copilot 最新機能 | リリースサイクル待ち | GitHub.com と同等の速度 |
| ダウンタイム | パッチ / アップグレードで定期発生 | ほぼゼロ |

---

## 3. 事前準備チェックリスト

### 3.1 ライセンス・契約面

| 項目 | 説明 |
|---|---|
| ☐ GHE.com DR の契約手続き | Microsoft 担当 SE または GitHub Sales 経由で **GitHub Enterprise plan** を発注。Metered Billing の課金経路 (Azure Subscription 連携 または Credit Card) を確定 |
| ☐ リージョン選択 | 日本リージョン (`japaneast`/`japanwest`) を含む 4 リージョンから選択。**初期化後の変更不可** |
| ☐ Volume License の残期間整理 | 移行期間中は GHES と GHEC を並行運用する必要があるため、Volume License を残しつつ GHE.com Metered を契約する期間が発生 |
| ☐ サブドメイン命名規約 | `<TENANT>.ghe.com` の `<TENANT>` を確定（変更困難） |

### 3.2 アイデンティティ面

| 項目 | 説明 |
|---|---|
| ☐ IdP の選定 | Microsoft Entra ID / Okta / その他 OIDC 対応 IdP |
| ☐ EMU の SCIM / SSO 設計 | プロビジョニング属性のマッピング (username / email / displayName) |
| ☐ ユーザー名マッピング戦略 | GHES の username と EMU の `_short_code` 付き username の対応関係 (`octocat_corp` 等) |
| ☐ Setup user の権限分離 | 初回 admin (root) は IdP 経由ではないため、復旧用としてのみ使用 |

### 3.3 ネットワーク面

| 項目 | 説明 |
|---|---|
| ☐ GHES → GHE.com 通信経路の確保 | GitHub Connect / GEI / ELM すべて HTTPS 443 outbound が必須 |
| ☐ プロキシ allow-list | `*.<TENANT>.ghe.com`, `auth.ghe.com`, `*.githubusercontent.com`, `*.blob.core.windows.net` |
| ☐ クライアント側 hostname | エンドユーザーのワークステーションも上記 hostname に到達できる必要あり |
| ☐ SSH 鍵 fingerprint の周知 | `gh api /meta --hostname <TENANT>.ghe.com` で取得し、ユーザーへ展開 |

---

## 4. 閉域 GHES + GitHub Connect の通信要件

### 4.1 接続経路

```
[GHES (10.0.1.4)]
   │
   │ HTTPS:443
   ▼
[HTTP Forward Proxy (10.0.2.x)]
   │
   │ HTTPS:443
   ▼
[Internet / GHE.com]
```

GHES から見ると **アウトバウンドはすべて HTTP プロキシ経由**。Proxy で以下の hostname を allow-list 化する。

### 4.2 GitHub Connect 用 outbound allow-list

GHES → GHE.com Connect の場合:

| Hostname | 用途 | プロトコル |
|---|---|---|
| `<TENANT>.ghe.com` | Web UI / API root | HTTPS 443 |
| `api.<TENANT>.ghe.com` | REST / GraphQL API | HTTPS 443 |
| `uploads.<TENANT>.ghe.com` | LFS / migration archive upload | HTTPS 443 |
| `github.com` | GHES standard connect (GitHub.com 接続を維持する場合) | HTTPS 443 |
| `api.github.com` | 〃 | HTTPS 443 |
| `uploads.github.com` | 〃 | HTTPS 443 |
| `github.com/enterprises/oauth_callback` | **Azure Subscription 連携時のみ一時的に必須** (§4.2.1 参照) | HTTPS 443 |

> ⚠️ GHES が **GitHub Connect で GHE.com に向ける場合**、デフォルトで GitHub.com への接続も期待されるため、両方の hostname を allow-list する。GHE.com 専用化する場合は `ghe-config app.github.github-connect-ghe-com-enabled true` を設定する（後述）。

#### 4.2.1 Azure Subscription 連携時の OAuth callback URL フォールバック ⚠️

Metered Billing の課金経路として **Azure Subscription** を `<TENANT>.ghe.com` の Enterprise に連携 / 更新する際、OAuth 認可フローは下記のように **public github.com を経由** します:

```
[Client browser]
     │
     │ ① 連携開始
     ▼
<TENANT>.ghe.com (Enterprise → Settings → Billing → Connect Azure subscription)
     │
     │ ② Azure サインインへ
     ▼
login.microsoftonline.com (Azure AD 認証)
     │
     │ ③ OAuth callback (★ ここで public github.com を経由する)
     ▼
https://github.com/enterprises/oauth_callback?code=...   ←【egress allow 必須】
     │
     │ ④ 課金 binding 完了後、tenant へ戻る
     ▼
<TENANT>.ghe.com
```

このため、**Azure Subscription を連携する瞬間および更新する瞬間に限り**、egress proxy / firewall で以下の URL を **クエリパラメータを含めて** 許可する必要があります:

| URL | 用途 | タイミング |
|---|---|---|
| `https://github.com/enterprises/oauth_callback` | Azure subscription 連携 OAuth callback | **連携時 / 更新時のみ**、subscription ID が persist された後は閉じてよい |

**実運用での設計指針**:

- **永続的 allow** (推奨): 規約上問題なければ `github.com` 配下を恒久的に open にしておく。連携作業の都度 firewall 変更を申請するより運用ミスが少ない
- **時限的 allow**: コンプライアンス要件が厳しく `github.com` を全閉している場合、**連携 / 更新作業の窓口時間だけ** `https://github.com/enterprises/oauth_callback` (+ クエリ全て) を許可するチェンジを入れて作業する
- **クエリパラメータの扱い**: OAuth code は `?code=...&state=...` 形式で渡されるため、proxy/firewall ルールは **path 完全一致 + クエリ任意** で許可する。HTTP URL pattern を厳格にマッチングする WAF/CASB を使っている場合、想定外にブロックされて UI 上「Azure に連携できません」と出る原因になる

**典型的な失敗ケース**:

- proxy では `github.com` を許可しているが、**WAF / CASB が `/enterprises/oauth_callback` を「未知のエンドポイント」として block** → Azure 認可後 GHE.com 画面に戻れず、Billing 画面で「Azure subscription not connected」のまま
- `<TENANT>.ghe.com` だけを allow-list して `github.com` を全閉 → OAuth callback が proxy で 403 → 同上

> 📌 出典: [Network details for GHE.com – OAuth callback URL for connecting an Azure subscription for billing](https://docs.github.com/en/enterprise-cloud@latest/admin/data-residency/network-details-for-ghecom#oauth-callback-url-for-connecting-an-azure-subscription-for-billing)

### 4.3 GHES Management Console のプロキシ設定

GHES 管理コンソール (`https://<ghes-host>:8443`) の **Privacy → HTTP proxy server** に以下を設定:

```
HTTP proxy: http://<proxy-vm>:8888
HTTPS proxy: http://<proxy-vm>:8888
No proxy: *.<internal-domain>, localhost
```

設定後 `ghe-config-apply` で適用。

### 4.4 Inbound 通信は不要

GHES → GHE.com への一方向接続のみで GitHub Connect は動作する。GHE.com 側からの inbound webhook は **不要**。

---

## 5. GitHub Connect の設定手順

GitHub Connect により以下が共有可能になる:

| 機能 | GHES → GHEC | GHES → GHE.com |
|---|---|---|
| License Sync (Active User の課金統合) | ✅ | ✅ |
| Server Statistics | ✅ | ❌ |
| Unified Search (GitHub.com の OSS を GHES から検索) | ✅ | ❌ |
| Unified Contributions | ✅ | ❌ |
| Dependabot updates / advisory database | ✅ | ✅ |
| GitHub Actions from GitHub.com Marketplace | ✅ | ❌ (GHE.com の場合は限定) |

> 💡 **本セクションは実機検証済み** — 本リポジトリで構築した Azure 上の閉域 GHES 3.18.8 から `<TENANT>.ghe.com` への接続を実際に成立させた結果を反映しています。最後の `### 5.6 実機検証で観測された挙動と注意点` で具体的な落とし穴を共有しています。

### 5.1 前提条件と outbound 通信要件

GitHub Connect (GHE.com 向け) を確立する前に、以下の条件を満たす必要があります:

| 項目 | 要件 | 備考 |
|---|---|---|
| GHES バージョン | **下表 (5.1.1) 参照** | Metered Billing / GHAS の販売可否は GHES バージョン依存 |
| GHE.com tenant の billing | **Invoiced** (請求書払い) が公式要件 | Credit Card / Free Trial 上の tenant では `Enable GitHub Connect` 後の handshake が完了しない可能性あり。Azure Marketplace 経由の MCA / Azure Subscription 連携も「invoiced」と見なされる |
| GHES 側に enterprise が作成済み | ✅ | 初期 setup 時に enterprise account を作成 |
| GHE.com tenant 側で **Site admin** ロール | ✅ | 接続承認のために必要 |
| outbound HTTP proxy で以下の FQDN を許可 | 下表参照 | GHES と proxy VM の両方から到達できること |

#### 5.1.1 GHES バージョン要件 (License Sync / GHAS Metered 販売)

GitHub Connect 自体は GHES 3.12 で GA ですが、**Metered Billing 経由での GHAS / 機能販売には別途バージョン要件があり**、Sales 側からの正式案内では下記が最新の閾値です（docs 上の表記は GA 履歴ベースで古い場合があります）:

| 販売モデル | 必要 GHES バージョン | 備考 |
|---|---|---|
| GitHub Advanced Security **bundle** を Metered で販売 | **GHES 3.14 以上** | GHAS をひとまとめの bundle SKU として Metered で販売する場合 |
| GitHub Advanced Security **split SKU** (Code Security / Secret Protection 個別) を Metered で販売 | **GHES 3.17 以上** | 2024 後半以降の split SKU 体系 (Code Security / Secret Protection を別 SKU で販売) を使う場合 |
| いずれの場合も共通 | 上記に加えて **GHES instance 自体が GHE.com に "entered" している** こと | = §5.2〜5.5 の GitHub Connect handshake が完了し、GHE.com 側 Enterprise の「Connected servers」一覧に当該 GHES が登録されている状態 |

> ⚠️ **公式 docs (`docs.github.com`) には GitHub Connect 自体の最低バージョンとして 3.12 が記載** されているが、**Metered Billing 経由で GHAS を販売する**には上記により高いバージョンが必要。営業段階でクロージング前にバージョン要件を必ず確認すること。本リポジトリの lab は **3.18.8** で構築しており、いずれの販売モデルでも要件を満たす。

**proxy で許可必須の FQDN (GHE.com 接続時):**

| FQDN | 用途 |
|---|---|
| `<TENANT>.ghe.com` | tenant の Web UI / OAuth |
| `api.<TENANT>.ghe.com` | REST API |
| `uploads.<TENANT>.ghe.com` | LFS / リリース成果物 |
| `objects-origin.<TENANT>.ghe.com` | git objects 取得 (Connect 後の OAuth callback も含む) |
| `auth.ghe.com` | OIDC 認証 |
| `github.com` | OAuth App 経由のフォールバック |
| `*.actions.githubusercontent.com` | Actions runner 連携 (使う場合のみ) |

検証コマンド (GHES admin shell からも実行可能):

```bash
# proxy 経由で各 FQDN へ到達確認 (302 or 401 ならば OK)
for host in <TENANT>.ghe.com api.<TENANT>.ghe.com uploads.<TENANT>.ghe.com auth.ghe.com github.com; do
  echo -n "$host: "; curl -sS -o /dev/null -w "%{http_code}\n" \
    -x http://<PROXY_PRIVATE_IP>:8888 https://$host/
done
```

### 5.2 GHES Management Console で HTTP proxy を設定

GitHub Connect の通信は GHES プロセス本体から発生するため、Mgmt Console (`:8443`) の **HTTP proxy** 設定が必須です（NSG 経由の OS レベル proxy だけでは不十分）。

1. `https://<ghes-host>:8443/setup/settings` を開く
2. **Privacy** タブ
3. **HTTP proxy server** に `http://<PROXY_PRIVATE_IP>:8888` を入力
4. **Save settings** → reconfigure が走り 5〜10 分かかる
5. 反映後、admin shell で `ghe-config core.http-proxy` の値が persist されていることを確認

### 5.3 GHE.com 専用接続を有効化 (admin shell)

```bash
ssh -p 122 admin@<ghes-host>

# GHE.com 接続を有効化
ghe-config app.github.github-connect-ghe-com-enabled true
ghe-config app.github.github-connect-ghe-com-subdomain "<TENANT>"

# 反映
ghe-config-apply
```

> ⚠️ `<TENANT>` は GHE.com の **subdomain そのもの**（例: tenant の URL が `https://octocorp.ghe.com` なら `octocorp`）。GHES 側の enterprise slug と一致しない場合がある（実機検証では GHES 側 `yuki-chiba-dr-inc` / GHE.com subdomain `yuki-chiba-drinc` のように slugify 規則が異なった）。

`ghe-config-apply` は約 5 分かかります（Phase 1〜4 で 4 段階のシステム検証）。

### 5.4 GUI で接続承認

1. GHES の右上アバター → **Enterprise settings**
2. URL は `https://<ghes-host>/enterprises/<ENTERPRISE_SLUG>/settings/dotcom_connection` （`<ENTERPRISE_SLUG>` は GHES 側で表示名から slugify されたもの）
3. **Enable GitHub Connect** をクリック → GHE.com にリダイレクト
4. GHE.com 側で IdP 認証 → OAuth callback
5. tenant 側に存在する enterprise account を選択 → **Connect** をクリック
6. 機能ごとの toggle（License sync / Dependabot / 等）を選択して保存

### 5.5 接続後の確認

**GHES 側の admin shell** から:

```bash
# enabled / subdomain の確認のみ (OAuth トークン等は Rails DB に保存され ghe-config には現れない)
ghe-config --get-regexp 'github-connect'
# → app.github.github-connect-ghe-com-enabled true
# → app.github.github-connect-ghe-com-subdomain <TENANT>

# システム全体の健全性
ghe-config-check
ghe-cluster-status -v
```

**GHE.com tenant 側** (UI) で確認:

1. `https://<TENANT>.ghe.com` にログイン
2. tenant の Enterprise settings → **GitHub Connect** タブ
3. **N SERVER CONNECTED** と表示され、`HOSTNAME` 欄に GHES の FQDN が出ていれば成立

License Sync の動作:

- GHE.com 側で **Settings → Billing → Active Users** に GHES の active user 数が反映される（数時間〜1 日のラグあり）
- これにより **Volume License + Metered Billing の重複課金を回避** できる

### 5.6 実機検証で観測された挙動と注意点

本リポジトリの Azure GHES (`ghes-lab.chiba-yuki.com`) から GHE.com tenant への Connect を実際に確立した際に観測された挙動を整理しています。

#### (1) Enterprise slug の表記揺れ — handshake 自体には影響しないが URL 直打ちで罠

| 場所 | 例 |
|---|---|
| GHES の enterprise display name | `yuki-chiba-dr.inc`（ドット入り） |
| GHES の URL 上の slug | `yuki-chiba-dr-inc`（ドット→ハイフン） |
| GHE.com の subdomain | `yuki-chiba-drinc`（ドット削除） |

**示唆**: `ghe-config app.github.github-connect-ghe-com-subdomain` には **GHE.com の subdomain そのまま**を渡すこと。enterprise slug ではない。

#### (2) handshake は 2 段階 — haproxy log に出る順序

GHES の `/var/log/haproxy.log` に以下のように 2 つの POST が記録される:

```
POST /enterprises/<slug>/settings/dotcom_connection                 → 302 (Enable GitHub Connect 押下)
POST /enterprises/<slug>/settings/dotcom_connection/resume_dotcom_connection → 302 (OAuth callback 受信)
```

両方が 302 を返していれば handshake は成功している。

#### (3) ⚠️ ブラウザ Console の `form-action` CSP エラーは **本物のブロッカー** — Chrome では handshake が完走しない

> **重大**: 本リポジトリの当初検証で「擬陽性」と誤判定し公開ガイドへも記載しましたが、**追加検証で本物のブロッカーであることが判明** したため記述を訂正しています。

OAuth callback ページ (`https://<TENANT>.ghe.com/auth/oidc/callback`) は最後に下記の form を自動 submit する:

```html
<form action="https://<TENANT>.ghe.com/enterprises/<TENANT>/enterprise_installations?state=...&token=..." method="post">
```

このページの CSP には:

```
form-action 'self' ghe.com copilot-workspace.githubnext.com objects-origin.<TENANT>.ghe.com;
```

**Chrome の `form-action` CSP は redirect chain 全体に対して評価される** ため、`enterprise_installations` POST → 302 → GHES (`<ghes-host>/admin/dotcom_connection/change_complete?...`) という最終 hop で allow-list 外と判定されブロックされる。Console にも下記の通り出る:

```
Sending form data to '<URL>' violates the following Content Security Policy directive: 
"form-action 'self' ghe.com copilot-workspace.githubnext.com objects-origin.<TENANT>.ghe.com".
The request has been blocked.
```

実機での観測症状:
- GHES 側「Enable GitHub Connect」を Chrome から実行 → OIDC 認証画面 → 「Signed in with <TENANT>」画面で停止
- callback (`/admin/dotcom_connection/change_complete`) が production.log に記録されず ＝ GHES 側はそもそも callback を受け取っていない
- GHE.com 側に **orphan な `enterprise_installation` レコードのみ** 作成され、UI 上は `N SERVER CONNECTED` と紛らわしく表示される（実態は未接続）
- GHES の resque ジョブ `EnterpriseAdvisoryDatabaseSyncJob` などが毎時実行されるたび `"Connection settings missing, skipping sync with github.com"` を resqued.log に出力

**回避策**: handshake は **Microsoft Edge / Firefox から実行** する。両者で redirect chain における CSP `form-action` 評価が緩く、callback が GHES に正常着地することを確認済み。Chrome を使い続けたい場合は [Disable Content-Security-Policy 拡張](https://chromewebstore.google.com/detail/disable-content-security/ieelmcmcagommplceebfedjlakkhpden) で **回避可能だが推奨しない**（別の通信もブロック解除されるため一時的にのみ）。

#### (4) handshake の URL フロー — 「5 分タイマー」と orphan record の扱い

GHES 側「Enable GitHub Connect」をクリックすると以下のフローが走る:

```
GHES UI                                                       GHE.com
  │ POST /enterprises/<GHES_SLUG>/settings/dotcom_connection
  ├──────────────────────────────────────────────────────────────►
  │                                              GHE.com 側で
  │                                              enterprise_installation
  │                                              record 作成 (timer 5 min)
  │ 302 → https://<TENANT>.ghe.com/enterprise_installations/new
  │◄──────────────────────────────────────────────────────────────
  │
  │ (browser navigate)
  │──────────────────────────────────────────────────────────────►
  │                                              IdP/OIDC 認証
  │                                              認可 form 表示
  │                                              form auto-submit:
  │                                              POST /enterprise_installations
  │                                              → 302 → /admin/dotcom_connection/
  │                                                       change_complete
  │ GET /admin/dotcom_connection/change_complete?state=...
  │◄──────────────────────────────────────────────────────────────
  │ (ここで GHES 側に Connect record 作成 = 完了)
  │
  │ 302 → /enterprises/<GHES_SLUG>/settings/dotcom_connection
  ↓
  (toggle 画面に切り替わる)
```

**5 分タイマー**: GHE.com 側で `enterprise_installation` レコードが作成されてから **5 分以内** に callback (`change_complete`) が着信しないと expire し、UI が下記表示に変わる:

```
GitHub Connect is not enabled yet
You have not completed the setup process on the <TENANT>.ghe.com side. 
Please do so within 5 minutes from now. After this time, you will have to reinitiate the setup process.

[Complete your GitHub Connect setup]
```

**orphan record の削除**: CSP エラーで callback が届かなかった場合、GHE.com 側にだけレコードが残る。再 handshake を試みると GHE.com 側「Select an enterprise」画面で:

```
A connection for <GHES_HOSTNAME> already exists.
Please disconnect the existing instance and try again. 
If the instance no longer exists, you can remove it from known installations.
```

と表示される。「**remove it from known installations**」リンクから orphan を削除してから再試行する。

#### (5) `ghe-config` には接続成立後も認証情報が現れない

接続が確立しても、`ghe-config --get-regexp 'github-connect'` には以下の **2 行のみ** しか出ない:

```
app.github.github-connect-ghe-com-enabled true
app.github.github-connect-ghe-com-subdomain <TENANT>
```

GitHub App credentials / installation token は Rails DB（MySQL）に保存される設計のため。**接続状態の最終確認は必ず以下のいずれかで行う** こと:

- GHES UI: `/enterprises/<GHES_SLUG>/settings/dotcom_connection` ページに **機能ごとの toggle 一覧** （Server statistics / License sync / Advisory database / Dependabot 等）が表示されれば成立
- GHE.com UI: `1 SERVER CONNECTED` 表示**だけでは不十分**（orphan record でも同じ表示）。下記の resqued.log と合わせて判定する
- GHES admin shell: `sudo tail /var/log/github/resqued.log | grep -i "Connection settings missing"` が出続けていれば未接続、`Starting Advisory Database sync with github.com` の後に skip メッセージが出なくなれば接続完了

#### (6) 接続完了後、各機能の toggle を ON にする必要がある

接続成立 ≠ License sync 自動開始。GHES の `/enterprises/<GHES_SLUG>/settings/dotcom_connection` に表示される各 toggle (Server statistics / License sync / Advisory database 更新 / Dependabot updates 等) を **個別に ON** にして初めてその機能の sync ジョブが GitHub.com / GHE.com 側へ outbound を行う。

#### (7) sync スケジュール — 即時反映ではない

| ジョブ | 動作間隔 | 用途 |
|---|---|---|
| `EnterpriseAdvisoryDatabaseSyncJob` | 1 時間ごと | 脆弱性 advisory DB の更新 |
| Server usage / License sync | **24 時間ごと**（GHES 仕様）| GHE.com の Billing → Active Users に反映 |

= **GHE.com 側 GitHub Connect 画面に「Server usage never synced」と出ていても、enable 直後〜24h 以内なら正常**。次節 (5.7) のトラブルシューティングで「24h 経過後も synced されない」場合の切り分け手順を記載。

#### (8) Member count は別途追加が必要

接続直後は GHE.com 側 GitHub Connect 画面で `0 members` と表示される。これは normal で、GHES の users が GHE.com 上の Members に紐づけられるのは **License sync 連携を ON にして数時間〜1 日経過後** となる。次節 (Section 6) の移行戦略で User mapping 設計を進めること。

### 5.7 トラブルシューティング: "Server usage never synced" が出続ける場合

GHE.com の GitHub Connect 画面に下記が表示され続ける症状:

```
ghes-lab.chiba-yuki.com - GitHub Connect server usage never synced
```

切り分け順序:

1. **接続完了から 24 時間経過しているか？** ← 経過していないなら正常。待つ
2. **GHES UI 側で接続状態が正しいか？** — `/enterprises/<GHES_SLUG>/settings/dotcom_connection` で feature toggle 一覧が表示されているか
   - もし「Enable GitHub Connect」ボタンや「Complete your setup」が出ているなら **GHES 側の handshake 未完了**。§5.6 (3)(4) を参照して再 handshake
3. **GHES resqued.log で skip メッセージが出ていないか?**
   ```bash
   sudo tail -200 /var/log/github/resqued.log | grep -iE 'Connection settings missing|sync with github.com'
   ```
   - `Connection settings missing, skipping sync with github.com` が続いている → 接続未完了。再 handshake 必要
4. **対象機能 (Server statistics / License usage) の toggle が ON か？** — GHES 設定画面で確認
5. **outbound proxy が GHE.com / api.github.com に通っているか？** — §5.1 のコマンドで確認

---

## 6. 移行戦略の選択

| 戦略 | 概要 | 適するケース | リスク |
|---|---|---|---|
| **ビッグバン** | 短期間で全 org / repo を一括移行 | 50 repo 未満の小規模、または週末メンテで完結可能 | 失敗時の影響範囲が大 / 並行運用期間なし |
| **フェーズ移行** | org 単位 / チーム単位で数週間〜数ヶ月かけて段階移行 | 数百 repo の中〜大規模、複数チーム | スケジュール調整負荷 / 期間中の重複ライセンス費 |
| **並行運用** | 重要 repo のみ早期移行、GHES は read-only で長期保持 | GHES に古い repo が大量にある、監査要件 | 二重運用コスト |

**推奨**: フェーズ移行 + GitHub Connect 併用。

---

## 7. 移行ツールの選定

### 7.1 GEI vs ELM 比較

| 項目 | GEI | ELM |
|---|---|---|
| 対応バージョン | GHES 3.4.1+ | GHES 3.17.15+ / 3.18.9+ / 3.19.6+ / 3.20.2+ |
| 移行単位 | repo / org | **repo のみ** |
| 移行中の repo 書き込み | **不可** (読取のみ) | **可** (live) |
| Monorepo / 巨大 repo 対応 | 制限あり (max 40 GiB / archive、3.13+ public preview) | **強い** (live 同期) |
| Concurrent migrations | 制限緩い | 同一 GHES から 10 / 同一 destination 20 |
| Org 設定移行 | repo migration のみ (org 設定は手動) | repo のみ (org 設定は手動) |
| 完成度 | GA | Public Preview (2026 年時点) |
| 移行先 | GitHub.com / GHE.com | **GHE.com 専用** |

**判断の目安**:
- 小〜中規模 repo (< 20 GiB) で短時間ダウンタイム許容 → **GEI**
- 巨大 monorepo / 開発を止められない → **ELM**

### 7.2 移行されるデータ

| データ | 移行される | 備考 |
|---|---|---|
| Git history (commits, branches, tags) | ✅ | ALL |
| Pull requests / Issues / Milestones | ✅ | |
| Wiki | ✅ | |
| Branch protections | ✅ | 一部ルールは除外 |
| Webhooks | ✅ | **再有効化が必要** |
| Releases | ✅ | |
| Attachments | ✅ | |
| GitHub Actions workflows (定義 YAML) | ✅ | secrets / runners は ❌ |
| User 履歴 (author / commenter) | ✅ | mannequin → real user の reattribution が必要 |
| **Code scanning results** | ❌ | 再スキャン |
| **Dependabot alerts** | ❌ | 再生成 |
| **Packages (Container / npm / Maven)** | ❌ | 別途移行 |
| **Git LFS objects** | ❌ | 別途移行 (LFS migration ツール) |
| **Actions secrets / variables / runners** | ❌ | 再設定 |
| **GitHub Apps** | ❌ | 再インストール |
| **Projects (new)** | ❌ | 手動移行 |
| **Audit log** | ❌ | export して保管 |

---

## 8. ハンズオン手順: GEI による repository 移行

### 8.1 前提

- `gh` CLI (v2.40+) をローカル PC または踏み台にインストール済み
- GHES 側に **migrator role** を持つ user の **classic PAT** (`repo`, `read:org`, `read:packages`, `delete_repo`, `workflow`, `admin:org`, `read:org`)
- GHE.com 側にも同等の PAT
- GHES からアクセス可能な Blob Storage (Azure Blob または S3) — 移行アーカイブの中継先

### 8.2 GEI 拡張のインストール

```bash
gh extension install github/gh-gei
gh gei --version
```

### 8.3 接続テスト (dry-run)

```bash
export GH_PAT=<GHE.com PAT>           # 移行先
export GH_SOURCE_PAT=<GHES PAT>       # 移行元

gh gei generate-script \
  --github-source-org <SOURCE_ORG> \
  --github-target-org <TARGET_ORG_ON_GHECOM> \
  --ghes-api-url https://<GHES_HOST>/api/v3 \
  --target-api-url https://api.<TENANT>.ghe.com \
  --output migrate.sh
```

出力された `migrate.sh` を確認し、blob storage の URL や repo リストを精査。

### 8.4 単一 repo の trial run

```bash
gh gei migrate-repo \
  --github-source-org <SOURCE_ORG> \
  --source-repo <REPO> \
  --github-target-org <TARGET_ORG> \
  --target-repo <REPO>-trial \
  --ghes-api-url https://<GHES_HOST>/api/v3 \
  --target-api-url https://api.<TENANT>.ghe.com \
  --azure-storage-connection-string "<AZURE_STORAGE_CONN_STR>"
```

### 8.5 本番移行

trial で問題なければ `-trial` を外して再実行。**移行中は source repo を locked にする**:

GHES の admin shell で:
```bash
ghe-migrator add <REPO> --lock
```

### 8.6 移行後タスク

- mannequin → real user の **reattribution** (`gh gei reclaim-mannequin` または GUI)
- webhook 再有効化
- secrets / runners / GitHub Apps の再設定
- branch protection の差分確認

---

## 9. ハンズオン手順: ELM による live 移行

### 9.1 前提

- GHES が **3.17.15 / 3.18.9 / 3.19.6 / 3.20.2 以上**
- GHES 管理者 SSH access
- 移行先が **GHE.com (DR)** であること（GitHub.com は不可）

### 9.2 ELM CLI の有効化

GHES admin shell で:

```bash
ssh -p 122 admin@<GHES_HOST>

# ELM の利用可否確認
elm --version
```

### 9.3 migration 作成

```bash
elm create \
  --source-repo <SOURCE_ORG>/<REPO> \
  --destination-org <TARGET_ORG_ON_GHECOM> \
  --destination-repo <REPO> \
  --source-pat <GHES_PAT> \
  --destination-pat <GHECOM_PAT>
```

### 9.4 フェーズ

1. **Creation**: 上記コマンドで migration が作成される
2. **Preflight checks**: network / PAT / repo 設定の検証
3. **Backfill**: 初期 crawl。完了まで repo サイズ次第（数十分〜数時間）。**この間も書き込み可能**
4. **Cutover**: `elm cutover <MIGRATION_ID>` で source lock + 差分転送 → 切替（数分のダウンタイム）
5. **Completion**: 完了確認
6. **Follow-up**: org 設定 / team / secrets / 等を destination で再構成

### 9.5 ステータス確認

```bash
elm list                    # 進行中の migration 一覧
elm show <MIGRATION_ID>     # 詳細ステータス
elm logs <MIGRATION_ID>     # ログ
```

---

## 10. ライセンス切替: Volume License → Metered Billing

### 10.1 タイムライン例（4 ヶ月）

```
Month 1: GHE.com 契約・EMU 設定・GitHub Connect 有効化
         → Volume License 継続 / Metered Billing も並行課金開始
Month 2: Pilot org (1〜2 個) を GEI で移行・運用検証
Month 3: 残り org の段階移行 (ELM 中心)
Month 4: GHES read-only 化 / Volume License 失効 / Metered Billing のみ
```

### 10.2 課金重複の最小化

- **GitHub Connect の License Sync** を有効にすると、GHES と GHEC で同一ユーザーが二重課金されない（Active User 単位で集約）
- 移行完了 org から順次 GHES 側で **org を archive** することで、GHES 側の active user が減少 → Volume License 必要数も減少
- Volume License は年次更新が多いので、**契約満了タイミングに合わせて移行スケジュールを逆算する**

### 10.3 Metered Billing の活用

GHE.com Metered Billing では:
- **Active User** = 過去 30 日でログイン or API call があったユーザー
- 月次 invoice (Azure Subscription 連携 or Credit Card)
- **Cost Center** 機能で部門別 chargeback が可能

### 10.4 Azure Subscription 連携の egress 要件 (再掲)

Azure Subscription を Metered Billing の課金経路として連携する場合、OAuth 認可フローが **public `github.com` を経由** します。閉域構成のまま連携を実施する際は、**§4.2.1** で記載した **`https://github.com/enterprises/oauth_callback` を含む allow-list の一時開放**が必要です。

連携作業フロー（実運用）:

1. 連携作業の **作業窓口時間** を設定し、その間だけ proxy / firewall で `github.com/enterprises/oauth_callback?*` を許可
2. `<TENANT>.ghe.com` Enterprise → Settings → Billing → **Connect Azure subscription** を実行
3. Azure サインイン → 対象 Subscription を選択 → callback で `<TENANT>.ghe.com` に戻ることを確認
4. Subscription ID が GHE.com Billing 画面に表示されたら連携成功
5. 連携完了後は allow-list を元に戻してよい（次回 **Subscription を変更 / 更新する際は再度 allow-list を開く**）

> ⚠️ **GHAS の Metered 販売モデル別 GHES バージョン要件** は §5.1.1 を参照。GHAS bundle は GHES 3.14+、split SKU (Code Security / Secret Protection 個別) は GHES 3.17+ が必要で、いずれも GHES instance 自体が GHE.com 側に "entered" している（= §5 の Connect handshake 完了）ことが前提となります。

---

## 11. Cutover と GHES Decommission

### 11.1 Cutover チェックリスト

- ☐ すべての org / repo の移行完了
- ☐ user reattribution 完了
- ☐ CI/CD pipeline (Actions / 外部 CI) の URL 切替
- ☐ Dependabot / Code scanning の再有効化
- ☐ Webhook 再有効化
- ☐ Branch protection の差分確認
- ☐ クライアント側 git remote の `git remote set-url`
- ☐ IDE / GUI ツールの再認証

### 11.2 GHES の Decommission

1. GHES を **maintenance mode** に
2. 全 repo に「移行完了済み」の README banner を追加（推奨: archive 化）
3. データ backup を 1 年以上保持（監査要件次第）
4. GitHub Connect を disable
5. License を terminate（または保有を継続して read-only 環境として保持）
6. インフラ削除（Azure RG 削除 等）

---

## 12. トラブルシューティング

### 12.1 GitHub Connect 接続失敗

| 症状 | 原因 / 対処 |
|---|---|
| "Could not connect to GitHub" | プロキシ allow-list 不足。`ghe-config app.http.proxy` で確認 |
| GHE.com 側に GitHub App が作成されない | enterprise owner 権限不足、または GHE.com 側で **OAuth App access** が制限されている |
| License Sync 反映遅延 | 通常 数時間〜24h。`ghe-license-statistics` で送信状況確認 |

### 12.2 GEI 移行失敗

| 症状 | 原因 / 対処 |
|---|---|
| `Archive size exceeds limit` | GHES バージョンに応じた archive size limit を超過 (3.13+ で 40 GiB)。LFS や Actions artifact を別途移行 |
| `Authentication failed` | PAT の scope 不足、または有効期限切れ |
| `Blob storage upload timeout` | GHES → Blob Storage の経路を確認、proxy で `*.blob.core.windows.net` を allow |
| mannequin が大量に残る | `gh gei reclaim-mannequin --csv mannequins.csv` で一括 reattribution |

### 12.3 ELM 移行失敗

| 症状 | 原因 / 対処 |
|---|---|
| `Preflight check failed: network` | GHES → GHE.com への HTTPS 接続不可。`curl -v https://<TENANT>.ghe.com` で疎通確認 |
| Backfill phase で stuck | webhook event の遅延。`elm logs` で詳細確認 |
| Cutover で差分転送が長い | 開発を一時停止してから cutover を実行 |

---

## 13. 移行後のセキュリティ・ガバナンス再構築

| 項目 | アクション |
|---|---|
| **IP Allow List** | GHE.com Enterprise settings で IP allow list を設定 |
| **OIDC Provider 設定** | EMU の SCIM/SSO を IdP 側で本番化 |
| **Audit Log Streaming** | GHE.com → Azure Event Hub / Splunk 等への audit log 流出設定 |
| **Required Workflows / Rulesets** | enterprise レベルで policy 適用 |
| **Secret Scanning Push Protection** | enterprise default on |
| **Dependabot / Code Scanning** | 各 repo で再有効化 (Default setup 推奨) |
| **GitHub Advanced Security (GHAS)** | seat 割り当て確認 |

---

## Appendix A. 本リポジトリの lab 構成との対応

本リポジトリ ([ChibaYuki347/ghes-to-ghecdr-verification](https://github.com/ChibaYuki347/ghes-to-ghecdr-verification)) で構築している lab 環境は、上記移行ガイドの **As-Is (現状) の縮小版**を Azure 上に再現したものです。

| 本ガイド上の概念 | lab での実装 |
|---|---|
| 閉域 GHES | `vm-ghestest-ghes` (No public IP / VNet 内部のみ) |
| Forward Proxy | `vm-ghestest-proxy` (tinyproxy 8888 + NAT GW) |
| 公開スタイル hostname | `ghes-lab.chiba-yuki.com` (Azure Private DNS Zone) |
| TLS cert | GHES 自動生成 self-signed (SAN: apex + wildcard) |
| 管理者 access | Azure Bastion + native client tunnel (`scripts/03-tunnel-ghes-mgmt.sh`) |
| GHE.com DR tenant | `yuki-chiba-drinc.ghe.com` (Japan region) |

lab で検証できるシナリオ:
- ✅ 閉域 GHES の初期構築・TLS 設定
- ✅ proxy 経由の outbound 通信
- ✅ **GitHub Connect (GHES → GHE.com) の有効化** — 本リポジトリで実機検証済（Section 5.6 参照）
- ⬜ GEI で test repo を GHE.com に移行（要動作確認）
- ⬜ License Sync の動作確認（ユーザー側 reflect まで数時間〜1 日）

---

## Appendix B. 参考リンク（GitHub 公式）

- [About GitHub Enterprise Cloud with data residency](https://docs.github.com/en/enterprise-cloud@latest/admin/data-residency/about-github-enterprise-cloud-with-data-residency)
- [Network details for GHE.com](https://docs.github.com/en/enterprise-cloud@latest/admin/data-residency/network-details-for-ghecom)
- [About GitHub Enterprise Importer](https://docs.github.com/en/migrations/using-github-enterprise-importer/understanding-github-enterprise-importer/about-github-enterprise-importer)
- [Migrating repositories from GitHub Enterprise Server to GitHub Enterprise Cloud](https://docs.github.com/en/migrations/using-github-enterprise-importer/migrating-between-github-products/migrating-repositories-from-github-enterprise-server-to-github-enterprise-cloud)
- [About Enterprise Live Migrations](https://docs.github.com/en/migrations/elm/about-live-migrations)
- [Enabling GitHub Connect for GHE.com](https://docs.github.com/en/enterprise-server@3.18/admin/configuring-settings/configuring-github-connect/enabling-github-connect-for-ghecom)
- [Managing GitHub Connect](https://docs.github.com/en/enterprise-server@3.18/admin/configuration/configuring-github-connect/managing-github-connect)
- [About migrations between GitHub products](https://docs.github.com/en/migrations/using-github-enterprise-importer/migrating-between-github-products/about-migrations-between-github-products)
