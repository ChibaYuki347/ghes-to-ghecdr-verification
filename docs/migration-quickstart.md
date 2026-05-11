# GHES → GHE.com Metered Billing 移行 クイックスタート

> このドキュメントは **「Volume License GHES から GHE.com Data Residency + Metered Billing への移行で、現場担当者が必ず通る最低限のステップ」だけ** を 1 枚にまとめたものです。背景・落とし穴・代替案などの詳細は同ディレクトリの [`migration-guide.md`](./migration-guide.md) に集約されています。
>
> **使い方**: 各 Phase のチェックボックスを上から順に潰してください。困ったら右端の「詳細」リンク先（migration-guide.md の該当節）を読んでください。

---

## 0. 全体像

```
Phase 0:  契約・前提確認
            │
            ▼
Phase 1:  GHE.com tenant 立ち上げ + IdP 連携
            │
            ▼
Phase 2:  Egress 開通 + GitHub Connect 確立 ← ★ ここが最大の山
            │
            ▼
Phase 3:  Pilot org / repo の GEI 移行
            │
            ▼
Phase 4:  本番 org / repo の移行（GEI または ELM）
            │
            ▼
Phase 5:  Azure Subscription 連携で Metered Billing 課金開始
            │
            ▼
Phase 6:  GHES Decommission
```

各 Phase の所要時間は組織規模・社内承認プロセス次第ですが、**Phase 2 までを 2 週間以内に終わらせる**と全体が遅延しません。

---

## Phase 0 — 契約・前提確認

| ☐ | やること | 詳細 |
|---|---|---|
| ☐ | **GHES バージョン確認**: 現行 GHES のバージョンが下記の販売モデル要件を満たすか | [§5.1.1](./migration-guide.md#ghas-version-requirements) |
| ☐ | → GHAS bundle を Metered で売る → **GHES 3.14 以上** | 同上 |
| ☐ | → GHAS split SKU (Code Security / Secret Protection 個別) を Metered で売る → **GHES 3.17 以上** | 同上 |
| ☐ | バージョン不足ならまず **GHES をアップグレード**（移行プロジェクト開始前に） | [GHES upgrade docs](https://docs.github.com/en/enterprise-server/admin/all-releases) |
| ☐ | **GHE.com Data Residency** を Sales / Microsoft 経由で発注。Region (Japan / EU / US / AU) と Subdomain (`<TENANT>.ghe.com`) を確定。**どちらも後から変更困難** | [§3.1](./migration-guide.md#phase0-billing) |
| ☐ | **Billing 種別を確認**: GitHub Connect (License Sync) は **Invoiced** (= 請求書払い / Azure Marketplace MCA / Azure Subscription 連携) を前提として動作確認されています。**Credit Card / Free Trial の tenant では handshake が完了しない可能性** があるため、契約段階で Sales に「移行プロジェクトで GitHub Connect を使うため Invoiced ステータスにしたい」と明示してください | [§10](./migration-guide.md#license-switch) |
| ☐ | **IdP** を確定: Microsoft Entra ID（OIDC）推奨。Okta / 他 SAML IdP も可 | [§3.2](./migration-guide.md#phase0-idp) |

> 💡 ここを飛ばすと Phase 1〜2 で「契約が落ちてない」「IdP 設計してない」「Credit Card tenant で Connect が通らない」で 1〜2 週間止まります。

---

## Phase 1 — GHE.com tenant 立ち上げ + IdP 連携

| ☐ | やること | 詳細 |
|---|---|---|
| ☐ | Sales 提供の **setup URL** から tenant 初期化 → Region / Subdomain を確定 | [§3.1](./migration-guide.md#phase0-billing) |
| ☐ | **Setup user** (recovery 用 root) で初回ログイン | 公式 docs |
| ☐ | **IdP と OIDC / SAML 連携** を設定 → EMU プロビジョニング開始 | [§3.2](./migration-guide.md#phase0-idp) |
| ☐ | テストユーザー 1 名で OIDC ログイン成功を確認 | — |
| ☐ | **Phase 2 で GitHub Connect を承認するユーザーが GHE.com tenant 側で Enterprise owner / Site admin ロールを持っている** ことを確認（権限不足だと handshake 中に止まる） | [§5.1](./migration-guide.md#enable-ghe-com-connect) |

> ⚠️ **EMU の username には `_short_code` (例: `octocat_corp`) が必ず付く**。GHES 側 username との対応表を作っておくと Phase 3〜4 の reattribution が楽。

---

## Phase 2 — Egress 開通 + GitHub Connect 確立 ★最重要★

### 2.1 Firewall / Proxy で許可する FQDN

下記を **GHES と proxy VM の両方から到達可能** にします:

| FQDN / URL | 用途 | 詳細 |
|---|---|---|
| `<TENANT>.ghe.com` | tenant apex (Web UI / OAuth) | [§4.2](./migration-guide.md#egress-allow-list) |
| `api.<TENANT>.ghe.com` | REST / GraphQL API | 〃 |
| `uploads.<TENANT>.ghe.com` | LFS / migration archive upload | 〃 |
| `objects-origin.<TENANT>.ghe.com` | git objects / Connect 後の OAuth callback | 〃 |
| `auth.ghe.com` | OIDC 認証 | 〃 |
| `*.githubusercontent.com` | 各種 asset | 〃 |
| `*.blob.core.windows.net` | LFS / migration archive | 〃 |
| `github.com`, `api.github.com`, `uploads.github.com` | GitHub Connect handshake / GEI | 〃 |
| `github.com/enterprises/oauth_callback`（クエリ込み）| **Azure Subscription 連携の瞬間だけ必須** | [§4.2.1](./migration-guide.md#azure-oauth-callback) |

> ⚠️ `*.<TENANT>.ghe.com` の wildcard だけで済ませず、上記のように **apex (`<TENANT>.ghe.com`) と `objects-origin.<TENANT>.ghe.com` を必ず明示** してください。WAF/CASB によっては wildcard が apex を含まないことがあり、Connect handshake で詰まる原因になります。

### 2.2 GHES Management Console で HTTP proxy 設定

1. `https://<ghes-host>:8443/setup/settings` → **Privacy** タブ
2. **HTTP proxy server** に `http://<PROXY_PRIVATE_IP>:8888` を入力 → Save (reconfigure 5〜10 分)

詳細: [§5.2](./migration-guide.md#ghes-proxy-config)

### 2.3 GitHub Connect handshake（最低限のコマンド）

**変数の意味（必ず確認）**:
- `<TENANT>` = **GHE.com のサブドメイン**（例: `octocorp` → `octocorp.ghe.com`）
- `<SLUG>` = **GHES の Enterprise URL slug**（例: `octo-corp`）
- **両者は一致しないことがある** ので、GHES Mgmt Console の Enterprise 設定で slug を確認してから設定してください

```bash
# admin shell へ
# (本リポジトリの Azure lab で動かす場合は scripts/03-tunnel-ghes-mgmt.sh --admin-shell で
#  Bastion 経由のトンネルを開いてから localhost:2222 へ ssh)
ssh -p 122 admin@<ghes-host>

# GHE.com 接続を有効化
ghe-config app.github.github-connect-ghe-com-enabled true
ghe-config app.github.github-connect-ghe-com-subdomain "<TENANT>"   # GHE.com 側 subdomain
ghe-config-apply   # 約 5 分
```

その後、GHES の Web UI から:

1. **`https://<ghes-host>/enterprises/<SLUG>/settings/dotcom_connection`** を開く（`<SLUG>` は GHES 側 slug）
2. **「Enable GitHub Connect」** をクリック
3. **必ず Microsoft Edge または Firefox で実施**（Chrome は CSP `form-action` で callback がブロックされる）
4. **GHE.com 側 tenant を選択 → 承認 → GHES に戻ってくる、までを 5 分以内に完了させる**（5 分超過すると GHE.com 側のリクエストレコードが expire し、orphan record が残って再 handshake できなくなる）
5. GHES 側に **機能 toggle 一覧**（License sync / Advisory database / Dependabot updates 等）が表示されれば成立
6. **必要な toggle を個別に ON** にする（接続成立だけでは sync は開始されない。**まず `License sync` を ON にすること**）

詳細・トラブルシュート: [§5.3〜§5.7](./migration-guide.md#enable-ghe-com-connect)

> ⚠️ **handshake が「1 SERVER CONNECTED」と GHE.com 側に出ても、GHES 側に toggle 一覧が出ていなければ失敗（orphan record のみ作成された状態）**。「Complete your setup」ボタンや「Enable GitHub Connect」ボタンが GHES 側に出続ける場合は [§5.6 (3) CSP blocker](./migration-guide.md#csp-blocker) / [§5.6 (4) handshake flow](./migration-guide.md#handshake-flow) を読んで再 handshake してください。

### 2.4 接続成立の確認

- GHES UI に **feature toggle 一覧** が表示されていること
- GHES admin shell:
  ```bash
  sudo tail -50 /var/log/github/resqued.log | grep -i "Connection settings missing"
  ```
  → 何も出力されなければ OK（出る場合は未接続）
- GHE.com 側 GitHub Connect 画面の `Server usage` は **24 時間後** に sync されるので、当日中の `never synced` 表示は正常

---

## Phase 3 — Pilot org / repo を GEI で trial 移行

| ☐ | やること | 詳細 |
|---|---|---|
| ☐ | ローカル PC に `gh` CLI (v2.40+) + `gh extension install github/gh-gei` | [§8.2](./migration-guide.md#gei-install) |
| ☐ | GHES 側に migrator role + classic PAT 発行（`repo, read:org, ...`） | [§8.1](./migration-guide.md#gei-prereq) |
| ☐ | GHE.com 側にも同等の PAT 発行 | 〃 |
| ☐ | Azure Blob（または S3）を archive 中継先として準備 | 〃 |
| ☐ | **Pilot org の small repo 1〜2 個** を trial 移行 (`gh gei migrate-repo`) | [§8.4](./migration-guide.md#gei-trial) |
| ☐ | **mannequin reattribution** をテスト (`gh gei reclaim-mannequin`) | [§8.6](./migration-guide.md#gei-post-migration) |
| ☐ | pilot user 数名で日常作業（push / PR / review）が問題ないか確認 | — |

> 💡 **GEI で移行されるもの / されないもの**（[§7.2](./migration-guide.md#data-migrated)）:
> - ✅ Git history / PR / Issue / Wiki / Releases / Webhooks（**ただし webhook は再有効化が必要**）
> - ✅ Branch protections（一部除外あり）
> - ❌ **Actions secrets / variables / runners / GitHub Apps / Packages / LFS objects / Code scanning results / Dependabot alerts** — **これらは別途再設定・再生成・別ツール移行が必要**

---

## Phase 4 — 本番 org / repo の移行

| ☐ | やること | 詳細 |
|---|---|---|
| ☐ | 移行戦略を確定（推奨: **フェーズ移行 + GitHub Connect 併用**） | [§6](./migration-guide.md#migration-strategy) |
| ☐ | org 単位で順次 GEI 移行（巨大 repo は **ELM** に切り替え） | [§7.1](./migration-guide.md#gei-vs-elm) |
| ☐ | 移行完了 org は GHES 側で **archive または read-only** に | [§10.2](./migration-guide.md#cost-deduplication) |
| ☐ | 各 org の **cutover checklist** を回す（webhook 再有効化 / secrets / runners / GitHub Apps 再設定 / branch protection 差分確認 / git remote 切替） | [§11.1](./migration-guide.md#cutover-checklist) |

---

## Phase 5 — Azure Subscription 連携で Metered Billing 課金開始

> ⚠️ Azure Subscription 連携の OAuth は **public `github.com`** を経由するため、**tenant 専用 egress** だけ開けていた組織は必ずここで詰まります。事前に WAF / CASB のルールも確認してください。

| ☐ | やること | 詳細 |
|---|---|---|
| ☐ | **作業窓口時間** を設定し、その間だけ `github.com/enterprises/oauth_callback?*` を proxy / firewall で許可 | [§4.2.1](./migration-guide.md#azure-oauth-callback) |
| ☐ | `<TENANT>.ghe.com` → Enterprise → Settings → Billing → **Connect Azure subscription** | [§10.4](./migration-guide.md#azure-billing-egress) |
| ☐ | Azure サインイン → 対象 Subscription を選択 | 〃 |
| ☐ | callback で `<TENANT>.ghe.com` に戻り、**Subscription ID が表示される** ことを確認 | 〃 |
| ☐ | 連携完了後、allow-list を元に戻してよい（Subscription 変更時に再度開放） | 〃 |
| ☐ | **GHAS Metered** を有効化（販売モデルに応じた GHES バージョン要件を再確認） | [§5.1.1](./migration-guide.md#ghas-version-requirements) |

---

## Phase 6 — GHES Decommission

| ☐ | やること | 詳細 |
|---|---|---|
| ☐ | GHES を **maintenance mode** に | [§11.2](./migration-guide.md#ghes-decommission) |
| ☐ | データ backup を **監査期間分保持**（推奨 1 年〜） | 〃 |
| ☐ | GitHub Connect を **disable** | 〃 |
| ☐ | Volume License を terminate（または read-only 環境として保持） | 〃 |
| ☐ | Azure RG / インフラを削除 | 〃 |

---

## 困ったときは

| 症状 | 詳細ガイド参照先 |
|---|---|
| Chrome で Connect handshake が「Signed in with <TENANT>」画面で止まる / Console に CSP `form-action` エラー | [§5.6 (3) CSP blocker](./migration-guide.md#csp-blocker) |
| GHE.com 側「A connection for ... already exists」が出て再 handshake できない | [§5.6 (4) handshake flow](./migration-guide.md#handshake-flow) |
| GHE.com 側「Server usage never synced」が 24 時間経っても消えない | [§5.7](./migration-guide.md#server-usage-never-synced) |
| Azure Subscription 連携で「subscription not connected」のまま戻らない | [§4.2.1](./migration-guide.md#azure-oauth-callback) の典型失敗ケース |
| GEI で `Archive size exceeds limit` | [§12.2](./migration-guide.md#gei-troubleshoot) |
| GEI vs ELM をどう選ぶか | [§7.1](./migration-guide.md#gei-vs-elm) |
| 移行戦略（ビッグバン / フェーズ / 並行）の選択 | [§6](./migration-guide.md#migration-strategy) |

---

## 関連ドキュメント

- 📘 [`migration-guide.md`](./migration-guide.md) — 全体詳細ガイド（このドキュメントの親）
- 🔧 [`defender-precheck.md`](./defender-precheck.md) — Azure 上に GHES lab を立てる際の事前チェック
- 🌐 [`research/`](./research/) — Connect / GEI / ELM の公式ドキュメント抜粋・調査メモ
- 🏗️ [`../scripts/`](../scripts/) — 本リポジトリで用意した Azure GHES 検証環境構築スクリプト群（`03-tunnel-ghes-mgmt.sh` で admin shell トンネルを開く実装含む）
