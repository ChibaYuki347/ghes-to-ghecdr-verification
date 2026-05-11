# GHES on Azure closed-network test environment

GHES 3.18.8 を Azure の閉域ネットワークに構築し、GHE.com (Data Residency) への移行検証を行うための operator's manual です。主な読者は、日本語で Azure / GitHub Enterprise を運用する infra engineer です。

## 1. プロジェクト概要 (Project Overview)

### 目的

このプロジェクトは **GitHub Enterprise Server (GHES) 3.18.8** を Azure に閉域構成で立ち上げ、将来的な **GHE.com (Data Residency)** への移行検証用の土台を作ることを目的としています。

### ライセンス遷移文脈

検証の背景には、GitHub Enterprise のライセンスを **Volume License** から **Metered Billing** へ移行する文脈があります。閉域 GHES 側から GHE.com テナントへ接続できること、GitHub Connect / migration 関連機能の前提条件を満たせることを確認します。

### 設計方針

- **完全閉域**: GHES VM には public IP を付与しません。
- **Proxy 経由のみ外部接続**: GHES の outbound は proxy subnet 上の **tinyproxy** (`:8888`) のみに制限します。
- **Deterministic egress IP**: Proxy VM の外向き通信は **NAT Gateway** 経由にし、送信元 IP を固定化します。
- **運用アクセス**: VM への管理アクセスは **Azure Bastion Standard** の tunnel / SSH 経由で行います。
- **GHES image constraints を尊重**: GHES VM には VM extensions や Trusted Launch を入れず、GitHub 公式 image の制約に合わせます。

### 関連ドキュメント

- **顧客向け移行ガイド**: [`docs/migration-guide.md`](docs/migration-guide.md) — GHES (Volume License) → GHE.com Data Residency (Metered Billing) への段階移行ガイド (Japanese)
- 事前調査: [`docs/research/migration-paths.md`](docs/research/migration-paths.md) — GHES→GHE.com Data Residency 移行パス調査
- アーキテクチャレビュー: [`docs/research/design-review.md`](docs/research/design-review.md) — AVM/WAF 観点の advisory
- GitHub Docs: [Installing GitHub Enterprise Server on Azure](https://docs.github.com/en/enterprise-server@3.15/admin/installing-your-enterprise-server/setting-up-a-github-enterprise-server-instance/installing-github-enterprise-server-on-azure)
- Defender 事前手順: [`docs/defender-precheck.md`](docs/defender-precheck.md)

## 2. アーキテクチャ図

```text
Azure subscription: <YOUR_SUBSCRIPTION_ID>
Resource Group: rg-ghestest-jpe (japaneast)

                         Internet / GHE.com
                               ^
                               |
                    +----------+----------+
                    | NAT Gateway         |
                    | pip-ghestest-nat    |
                    +----------+----------+
                               |
+------------------------------------------------------------------+
| VNet: vnet-ghestest (10.0.0.0/16)                                |
|                                                                  |
|  +---------------------------+     +---------------------------+ |
|  | AzureBastionSubnet        |     | ProxySubnet               | |
|  | 10.0.255.0/26             |     | 10.0.2.0/24               | |
|  |                           |     | NSG: nsg-ghestest-proxy   | |
|  | Bastion Standard          | SSH | VM: vm-ghestest-proxy     | |
|  | bas-ghestest              +---->| tinyproxy :8888           | |
|  | Public IP for Bastion     |     | outbound via NAT GW       | |
|  +-------------+-------------+     +-------------^-------------+ |
|                |                                 |               |
|                | tunnel 8443 / 122               | HTTP proxy    |
|                v                                 |               |
|  +---------------------------+                   |               |
|  | GhesSubnet                |                   |               |
|  | 10.0.1.0/24               +-------------------+               |
|  | NSG: nsg-ghestest-ghes    |                                   |
|  | VM: vm-ghestest-ghes      | no public IP / direct Internet     |
|  | GHES 3.18.8              | denied                             |
|  +---------------------------+                                   |
|                                                                  |
|  Private DNS Zone: ghestest.internal                             |
|    - ghes.ghestest.internal                                      |
|    - proxy.ghestest.internal                                     |
+------------------------------------------------------------------+
```

## 3. 前提条件 (Prerequisites)

- Azure CLI **2.60+**
  - 実行環境では **2.77** で確認済みです。
- `az bicep` (extension): **0.42.1+**
- 利用する Azure サブスクリプションに対する以下の権限
  - **Contributor**
  - **Security Admin**
- GHES ライセンスファイル (`.ghl`)
  - トライアルライセンスは <https://github.com/enterprise/trial> から取得可能です。
- 操作端末から Azure CLI で `az login` 済みであること
- (オプション) お好みのターミナル + ブラウザ

### 環境変数の設定

このリポジトリは subscription ID などをハードコードしません。`.env.example` を `.env` にコピーして自分の値を埋めてください。

```bash
cp .env.example .env
# vi .env  # AZURE_SUBSCRIPTION_ID=<your-sub-id> など
```

`scripts/02-deploy.sh` および `scripts/03-tunnel-ghes-mgmt.sh` は起動時に `.env` を自動で読み込みます。

## 4. デプロイ手順

### 1. SSH 鍵生成

```bash
./scripts/01-generate-ssh-key.sh
```

生成された公開鍵 (`~/.ssh/ghestest_id_ed25519.pub`) を `02-deploy.sh` が自動的に `GHES_SSH_PUBLIC_KEY` 環境変数として export し、`infra/main.bicepparam` の `readEnvironmentVariable()` 経由で渡します。鍵パスを変えたい場合は `.env` の `SSH_KEY_NAME` / `SSH_PUBLIC_KEY_PATH` を上書きしてください。

### 2. デプロイ実行

```bash
./scripts/02-deploy.sh
```

想定所要時間は **約 15 分**です。

- Bastion: 約 10 分
- VMs: 約 3 分
- その他 network / DNS / disk: 数分

`02-deploy.sh` は Defender for Servers の Per-VM 降格 (Free) をデプロイ完了直後に自動実行します。失敗時は [`docs/defender-precheck.md`](docs/defender-precheck.md) を確認してください。

### 3. 完了後 outputs を控える

デプロイ完了後、少なくとも以下の outputs を控えます。

- `resourceGroupName`
- `bastionName`
- `ghesVmName`
- `ghesVmId`
- `ghesPrivateIp`
- `ghesFqdn`
- `proxyFqdn`
- `tunnelCommand`

```bash
az deployment sub list --query "[?name.starts_with(@,'ghestest-')] | [0].properties.outputs"
```

## 5. 初期セットアップ

> ⚠️ **VPN クライアントが Windows で稼働している場合の重要事項**
>
> Microsoft Entra Global Secure Access、GlobalProtect、Cisco AnyConnect 等の VPN クライアントが Windows で動作している環境では、WSL2 NAT ネットワークが VPN によって干渉を受け、以下のような症状が発生します（Microsoft ガイド `Global Secure Access` でも Known Issue として明記）:
> - WSL から `az login` / `az network bastion tunnel` の実行失敗
> - WSL の `127.0.0.1` ループバックを VPN クライアントが hijack し SYN-SENT で固まる
> - WSL 内 listener が Windows ブラウザから到達不可
>
> **公式推奨ワークアラウンド**: **Windows PowerShell から直接 `az` を実行する**（後述）。WSL 側の DNS をバイパスする `.wslconfig` 設定 ([トラブルシューティング §10](#10-トラブルシューティング)) との併用も可能です。

### 1. ターミナル A: Management Console tunnel を起動

#### Linux / macOS / WSL (VPN なし)

```bash
./scripts/03-tunnel-ghes-mgmt.sh
```

#### Windows PowerShell (VPN あり / WSL ネットワーク不調時の推奨)

```powershell
# Azure CLI for Windows が必要: winget install Microsoft.AzureCLI
az login
.\scripts\03-tunnel-ghes-mgmt.ps1                 # Management Console: https://localhost:8443
.\scripts\03-tunnel-ghes-mgmt.ps1 -Mode web       # Web UI:              https://<host>:8444
.\scripts\03-tunnel-ghes-mgmt.ps1 -Mode ssh       # Git SSH:             ssh -p 2200
.\scripts\03-tunnel-ghes-mgmt.ps1 -Mode adminshell # GHES admin shell:   ssh -p 2222
```

既定では、ローカル `https://localhost:8443` が GHES Management Console (`:8443`) に tunnel されます。

### 2. ターミナル B: ブラウザで Management Console を開く

```text
https://localhost:8443
```

初回は自己署名証明書のため TLS certificate warning が出ます。テスト環境なので警告を無視して続行します。

### 3. Management Console で初期設定

Management Console 画面で以下を設定します。

1. **License upload**: `.ghl` ファイルをアップロード
2. **Management Console password**: 任意の強い password を設定
3. **Hostname / TLS / Subdomain Isolation**: 後述の **3.1** で設定
4. 設定保存
5. 自動再起動を待機
   - 目安: 約 5 〜 15 分

#### 3.1. 公開スタイル Hostname と TLS 証明書を設定する

GHES の `Hostname` 検証は VM 自身からの DNS 解決と loopback HTTPS 接続を要求します。閉域構成のまま公開スタイル FQDN（例: `ghes-lab.chiba-yuki.com`）を使う場合、Azure Private DNS Zone を VNet にリンクして VM 内部から名前解決できるようにします。クライアント側ブラウザは `hosts` ファイルで loopback マッピングします。

**Step A: Private DNS Zone と A レコードを作成**

```bash
# 既定: zone=chiba-yuki.com, label=ghes-lab, wildcard 含む
./scripts/05-setup-public-dns.sh

# カスタマイズ例:
ZONE=example.com LABEL=ghes INCLUDE_WILDCARD=false ./scripts/05-setup-public-dns.sh
```

スクリプトは idempotent です。zone / VNet link / A record (apex + wildcard) を upsert します。

**Step B: 自己署名 wildcard 証明書を生成（PoC / 検証目的）**

```bash
./scripts/04-generate-self-signed-cert.sh ghes-lab.chiba-yuki.com
# 出力: certs/ghes-lab.chiba-yuki.com.{crt,key}
```

本番運用では Let's Encrypt (DNS-01) や内部 CA で発行した正規証明書を使用してください。

**Step C: クライアント側ブラウザの名前解決**

WSL から Windows hosts file を管理者権限で編集する場合:

```bash
powershell.exe -Command "Start-Process notepad -ArgumentList 'C:\Windows\System32\drivers\etc\hosts' -Verb RunAs"
```

末尾に以下を追加して保存:

```
127.0.0.1 ghes-lab.chiba-yuki.com
```

**Step D: GHES Management Console で適用**

ブラウザの setup wizard / Management Console で:

| 項目 | 値（PoC） | 値（フル本番） |
|---|---|---|
| Hostname | `ghes-lab.chiba-yuki.com` | `ghes.<your-domain>` |
| TLS certificate | `certs/ghes-lab.chiba-yuki.com.crt` | wildcard SAN cert (CA-issued) |
| TLS key | `certs/ghes-lab.chiba-yuki.com.key` | 対応する private key |
| Subdomain isolation | OFF | **ON** (推奨) |
| Test domain settings | ✓ | ✓ |
| Save settings | クリック → reconfigure run 完了まで待機 | 同左 |

**Step E: Web UI へのアクセス用 tunnel を起動**

GHES の web UI は port 443 で待ち受けます。Bastion tunnel の `--web` モードで localhost:8444 にフォワードします。

```bash
./scripts/03-tunnel-ghes-mgmt.sh --web
# → ブラウザで https://ghes-lab.chiba-yuki.com:8444/
```

### 4. 再起動後にサインイン確認

再起動完了後、再度以下へアクセスして Management Console にサインインできることを確認します。

```text
https://localhost:8443
```

### 5. (オプション) admin 初期ユーザ作成

ユーザサインアップ画面を開き、admin 初期ユーザを作成します。

```text
https://localhost
```

HTTP/HTTPS 用の tunnel が必要な場合は、`03-tunnel-ghes-mgmt.sh` のオプションまたは `az network bastion tunnel` で `80` / `443` を forwarding してください。

## 6. GitHub Connect / GHE.com 移行検証

1. GHES の Management Console または admin UI で **Settings → GitHub Connect** を開きます。
2. GHE.com Data Residency tenant の URL を入力します。
3. Proxy 設定を入れます。
   - Path: **Settings → Privacy → HTTP proxy server**
   - Value: `http://10.0.2.4:8888`
   - `10.0.2.4` は proxy VM の Private IP 例です。実環境では `proxyFqdn` / NIC の private IP を確認してください。
4. 接続確認を実施します。

GHE.com にアクセスできれば、**閉域構成 + tinyproxy 経由 + NAT Gateway egress** が機能している証跡になります。詳細な移行検証手順は、事前調査レポートを参照してください。

## 7. 運用コマンド集

| 用途 | コマンド |
|---|---|
| GHES 管理コンソールへの tunnel | `./scripts/03-tunnel-ghes-mgmt.sh` |
| GHES Web UI 用 tunnel (port 443 → 8444) | `./scripts/03-tunnel-ghes-mgmt.sh --web` |
| GHES admin shell (port 122) | `./scripts/03-tunnel-ghes-mgmt.sh --admin-shell` (リモート 122 → ローカル 2222 にバインド。SSH は `ssh -p 2222 admin@localhost`) |
| 自己署名 wildcard 証明書生成 | `./scripts/04-generate-self-signed-cert.sh <fqdn>` |
| 公開スタイル Hostname の Private DNS 設定 | `./scripts/05-setup-public-dns.sh` (`ZONE=` / `LABEL=` で上書き可) |
| Proxy VM SSH | `az network bastion ssh --resource-group "${RG_NAME:-rg-ghestest-jpe}" --name <bastion> --target-resource-id <proxy_vm_id> --auth-type ssh-key --username ghadmin --ssh-key "${SSH_PRIVATE_KEY_PATH:-~/.ssh/ghestest_id_ed25519}"` |
| GHES VM extension 確認 (空であるべき) | `az vm extension list -g rg-ghestest-jpe --vm-name vm-ghestest-ghes -o table` |
| デプロイ済み outputs 取得 | `az deployment sub list --query "[?name.starts_with(@,'ghestest-')] \| [0].properties.outputs"` |

補足: proxy VM の resource ID が outputs に無い場合は、以下で取得できます。

```bash
az vm show -g rg-ghestest-jpe -n vm-ghestest-proxy --query id -o tsv
```

## 8. 後片付け (teardown)

```bash
RG_NAME="${RG_NAME:-rg-ghestest-jpe}"

# 1. RG ごと削除 (data disk も消える)
az group delete -n "${RG_NAME}" --yes --no-wait

# 2. Per-VM Defender override は VM 削除と同時に消滅するため明示クリーンアップ不要
#    (詳細は docs/defender-precheck.md §5)

# 3. ローカル SSH 鍵を削除 (任意)
# rm -f ~/.ssh/ghestest_id_ed25519 ~/.ssh/ghestest_id_ed25519.pub
```

`az group delete --no-wait` は非同期削除です。必要に応じて Azure Portal または `az group exists -n "${RG_NAME}"` で削除完了を確認してください。

## 9. コスト目安

| リソース | 月額目安 (USD, japaneast) |
|---|---:|
| Azure Bastion Standard | ~$140 + tunnel transfer |
| NAT Gateway | ~$32 + データ転送 |
| GHES VM (Standard_E4s_v5, 730h) | ~$220 |
| Proxy VM (Standard_B2s, 730h) | ~$30 |
| OS Disk (400GB Premium GHES + 30GB Premium Proxy) | ~$80 |
| Data Disk (200GB Premium_LRS) | ~$36 |
| Public IPs (Bastion + NAT GW) | ~$8 |
| **合計** | **~$546/月** (常時稼働時) |

⚠️ 24h テストで打ち切れば **~$18 程度**です。**使い終わったら必ず teardown** してください。

## 10. トラブルシューティング

| 症状 | 対処 |
|---|---|
| デプロイ失敗 `OperationNotAllowed: Defender for Servers...` | `02-deploy.sh` の Defender per-VM 降格が走っていない可能性があります。[`docs/defender-precheck.md`](docs/defender-precheck.md) §3.2 の手動コマンドで Free に降格してください。 |
| GHES VM が `Failed` 状態 | VM extension が自動展開された可能性があります。`az vm extension list` で確認し、存在する場合は削除して GHES を再起動してください。 |
| `https://localhost:8443` が応答なし | Bastion tunnel が確立しているか確認します。別端末から `curl -k https://localhost:8443` を実行してください。ポート競合の場合は `--port 18443` 等に変更します。 |
| GitHub Connect が GHE.com に到達できない | Proxy VM の tinyproxy が動作しているか確認します: `sudo systemctl status tinyproxy` (Bastion 経由 SSH で実行)。 |
| `installing-github-enterprise-server-on-azure` 公式手順との差分 | 公式手順は Public IP 前提・パスワードログイン前提です。本リポジトリは閉域 + 鍵認証に振っています。 |
| WSL から `az` 実行で Bastion tunnel が listen しない / `az login` がタイムアウト | **Microsoft 公式 Known Issue（VPN × WSL2）**。Microsoft Entra Global Secure Access / GlobalProtect / AnyConnect 等の VPN クライアントが Windows で動作していると、WSL2 NAT ネットワークが干渉を受けます。**公式推奨ワークアラウンドは Windows PowerShell から直接 `az` を実行すること**: `scripts/03-tunnel-ghes-mgmt.ps1` を使用してください。代替として `%USERPROFILE%\.wslconfig` に `[wsl2]` `dnsTunneling=false` を追加して `wsl --shutdown` でも改善します。 |
| WSL2 内に `loopback0` 仮想 IF 出現・Bastion CLI が SYN-SENT で固まる | 上記 Known Issue の派生症状。GSA は WSL 内に priority 1 routing rule を注入し 127.0.0.0/8 を hijack します。`03-tunnel-ghes-mgmt.sh` は起動時に bypass rule (`from 127.0.0.0/8 to 127.0.0.0/8 lookup local priority 0`) を自動投入します（sudo 必要）。Windows PowerShell に切り替えれば不要です。 |
| WSL から `az login` で `Failed to resolve 'login.microsoftonline.com'` | 同 VPN 干渉。`/etc/hosts` で `40.126.32.74 login.microsoftonline.com login.windows.net sts.windows.net` を強制マッピング、または `.wslconfig` の `dnsTunneling=false` を設定してください。 |
| `Defined port is currently unavailable` | Bastion CLI が出すエラーで、`LOCAL_PORT` (default 8443) が既に他のプロセスに使われているとき発生します。多くの場合、PC スリープや VPN 切替で残った前回の tunnel です。`scripts/03-tunnel-ghes-mgmt.sh` / `.ps1` の **port preflight** が占有プロセスを検出して PID と共に報告します。`--force` (bash) / `-Force` (ps) を付与すると Bastion 系プロセスのみ自動 kill して継続します。 |
| `https://localhost:8443` が `502/503/504` または `connection reset` を返す | GHES VM がデアロケート / 再起動中の可能性があります。`scripts/03-tunnel-ghes-mgmt.sh` / `.ps1` は起動時に **VM power state を自動チェック (preflight)** します。`--auto-start` (bash) / `-AutoStart` (ps) を付与すると停止中の VM を起動 → running 待機 → 90s warmup までスクリプトが面倒を見ます。 |

### VM Preflight 機能（v2 以降）

`03-tunnel-ghes-mgmt.{sh,ps1}` は tunnel を開く前に 2 段階の preflight を実行します。

**Preflight 1: GHES VM power state**

`az vm get-instance-view` で power state を取得し、状態に応じて挙動を分岐します。

| 状態 | デフォルト挙動 | `--auto-start` / `-AutoStart` 付与時 |
|---|---|---|
| `running` | そのまま tunnel 開始 | 同左 |
| `deallocated` / `stopped` | エラー終了 (exit 3) | `az vm start` → 最大 5 分待機 → 90 秒 GHES warmup → tunnel 開始 |
| `starting` | 最大 5 分待機 → 90 秒 warmup → tunnel | 同左 |
| 不明 / 取得失敗 | warning だけ出して継続 | 同左 |

**Preflight 2: ローカルポート占有チェック**

`LOCAL_PORT` を listen しているプロセスがいる場合、`Defined port is currently unavailable` で Bastion CLI が落ちる前に、占有プロセスの PID / プロセス名 / コマンドライン (Windows) を表示します。

| 占有プロセス | デフォルト挙動 | `--force` / `-Force` 付与時 |
|---|---|---|
| Bastion 系 (python3 / `az network bastion tunnel` を含むコマンド) | エラー終了 (exit 4) + PID と修復コマンドを案内 | 自動 kill (SIGTERM → SIGKILL) → tunnel 開始 |
| 上記以外 (Web サーバ等) | エラー終了 (exit 4)。`--force` でも kill しない | 同左（安全のため拒否） |

**スキップ方法（VM 状態チェックのみ）**: `--skip-preflight` / `-SkipPreflight` / `SKIP_PREFLIGHT=true`。Activity Log の確認や手動制御をしたい場合に有用。

**用途**:
- 「VM が知らないうちに止まっていた」現象（OS 再起動・自動メンテ・コスト削減で一時 deallocate していた等）からの自動復旧
- Bastion tunnel は VM が deallocated でも一見成功する（接続は確立するが GHES プロセスが応答しない 502 を返す）ため、事前チェックの効果が大きい
- VPN 切替 / PC スリープ後に「前回の tunnel が裏で生きている → ポート競合」を自動解決

### `.wslconfig` 推奨設定（VPN 干渉緩和）

Windows ホストの `%USERPROFILE%\.wslconfig` に以下を追加し、`wsl --shutdown` で WSL を再起動してください:

```ini
[wsl2]
dnsTunneling=false
networkingMode=mirrored
firewall=false
```

- `dnsTunneling=false`: WSL の DNS 解決を Windows VPN 経路から切り離す
- `networkingMode=mirrored`: Windows と WSL のネットワーク (loopback / 127.0.0.1) を共有
- `firewall=false`: Windows Defender Firewall の WSL 強制を無効化

> なお `networkingMode=mirrored` を有効にしても VPN 側で WSL traffic を hijack する設定が enforce されている場合、根本対処は **Windows PowerShell から直接 `az` を実行する** (`03-tunnel-ghes-mgmt.ps1`) です。

## 11. 関連ファイル

```text
ghes-to-ghecdr/
├── README.md                       # このファイル
├── infra/
│   ├── main.bicep
│   ├── main.bicepparam
│   ├── modules/
│   │   ├── network.bicep
│   │   ├── bastion.bicep
│   │   ├── proxy-vm.bicep
│   │   └── ghes-vm.bicep
│   └── cloud-init/proxy-init.yaml
├── scripts/
│   ├── 01-generate-ssh-key.sh
│   ├── 02-deploy.sh
│   ├── 03-tunnel-ghes-mgmt.sh      # Linux / macOS / WSL (VPN なし環境向け)
│   ├── 03-tunnel-ghes-mgmt.ps1     # Windows PowerShell (VPN あり環境向け、推奨)
│   ├── 04-generate-self-signed-cert.sh
│   └── 05-setup-public-dns.sh
├── docs/
│   └── defender-precheck.md
└── .github/agents/                 # awesome-copilot Custom Agents (Bicep 実装/計画レビュー用)
```

現時点で `scripts/*.sh` が未作成の場合でも、別タスクで作成される想定の operator entrypoints として記載しています。

## 12. 既知の制約 (out of scope)

- HA 構成 / レプリケーション / バックアップ自動化
  - snapshot は必要に応じて手動で取得します。
- カスタム TLS 証明書
  - デフォルトの自己署名証明書のままです。
- GHE.com 本契約 / EMU テナント
- GEI (GitHub Enterprise Importer) の実行
  - 環境構築完了後の別タスクです。
- App Insights / Log Analytics
  - advisory レビューでは推奨されていますが、本テストでは未配備です。
