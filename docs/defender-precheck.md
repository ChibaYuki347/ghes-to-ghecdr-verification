# Azure Defender for Servers precheck for GHES on Azure

## 1. 概要

GHES Marketplace image (`GitHub:GitHub-Enterprise:GitHub-Enterprise:3.18.8`) は Azure VM extensions をサポートしません。Defender for Servers P2 が subscription scope で有効なまま GHES VM を作成すると、Azure Monitor Agent / MDE などの自動拡張機能配布が走り、GHES の custom `waagent` 制約により health check 失敗や VM 破損につながるため、デプロイ対象 VM 単位で Defender for Servers を Free に降格して保護対象から外します。

> ⚠️ **API 制約**: Defender pricing override は **Subscription** または **Per-VM (machine resource)** スコープのみサポートされます。Resource Group スコープのオーバーライドは存在しません。本ドキュメントは Per-VM オーバーライドを推奨アプローチとして記述します。

## 2. 事前確認コマンド

まず対象 subscription を明示します。

```bash
az account set --subscription "$AZURE_SUBSCRIPTION_ID"
```

Subscription scope の Defender for Servers 設定を確認します。

```bash
az security pricing show --name VirtualMachines
```

`jq` で `pricingTier` と `subPlan` だけを見る場合:

```bash
az security pricing show --name VirtualMachines \
  | jq '.properties | {pricingTier, subPlan}'
```

Interpretation:

- `pricingTier: "Standard"` かつ `subPlan: "P2"` の場合、Defender for Servers Plan 2 が subscription scope で有効です。
- `pricingTier: "Free"` の場合、Defender for Servers paid plan は無効です。
- 今回は P2 enabled が既知なので、GHES VM を**作成した直後**に Per-VM scope で `Free` を適用します。

## 3. 対処コマンド (Per-VM スコープで Free に降格)

> ⚠️ **重要**: Defender for Servers の pricing override は **Subscription スコープ** か **Per-VM (machine) スコープ** のみが API でサポートされます。Resource Group スコープのオーバーライドは存在しません ([MS Learn](https://learn.microsoft.com/azure/defender-for-cloud/tutorial-enable-servers-plan#enable-defender-for-servers-at-the-resource-level))。
>
> したがって本構成では **Bicep デプロイ完了後** に対象 VM へ個別に Free を適用します。`scripts/02-deploy.sh` がこの処理を post-deploy ステップとして自動実行します。

### 3.1 自動実行（推奨）

`./scripts/02-deploy.sh` 実行時、Bicep デプロイ完了後に以下が自動的に走ります:

```bash
# Per-VM REST API call (vm-ghestest-ghes, vm-ghestest-proxy 双方に適用)
az rest --method PUT \
  --uri "https://management.azure.com/subscriptions/<sub>/resourceGroups/rg-ghestest-jpe/providers/Microsoft.Compute/virtualMachines/<vm>/providers/Microsoft.Security/pricings/virtualMachines?api-version=2024-01-01" \
  --body '{"properties":{"pricingTier":"Free"}}'
```

### 3.2 手動実行（リカバリ用）

スクリプトが失敗した場合の手動コマンド:

```bash
SUB="$AZURE_SUBSCRIPTION_ID"
RG="${RG_NAME:-rg-ghestest-jpe}"

for VM in $(az vm list -g "$RG" --query "[].name" -o tsv); do
  VMID="/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Compute/virtualMachines/$VM"
  az rest --method PUT \
    --uri "https://management.azure.com${VMID}/providers/Microsoft.Security/pricings/virtualMachines?api-version=2024-01-01" \
    --body '{"properties":{"pricingTier":"Free"}}'
done
```

### 3.3 注意点（race condition）

- VM 作成直後〜数分間は Defender 拡張機能の自動 push が起こり得ます。Per-VM override 適用後、既に push 済みの拡張機能が残っている場合は手動で削除してください（§4 参照）。
- 完全な race-free を求める場合、subscription scope を一時的に Free にしてから VM を作成し、デプロイ後に Standard/P2 に戻す方法もありますが、他ワークロードへの影響に注意してください。

## 4. GHES VM デプロイ後の確認

GHES VM および Proxy VM に Defender 起源の VM extension が push されていないことを確認します。

```bash
az vm extension list -g "${RG_NAME:-rg-ghestest-jpe}" --vm-name vm-ghestest-ghes -o table
az vm extension list -g "${RG_NAME:-rg-ghestest-jpe}" --vm-name vm-ghestest-proxy -o table
```

Expected: empty / no rows. もし `MDE.Linux`, `AzureMonitorLinuxAgent`, `ConfigurationForLinux` などが表示された場合は GHES 非対応の可能性が高いため削除します:

```bash
az vm extension delete -g "${RG_NAME:-rg-ghestest-jpe}" --vm-name vm-ghestest-ghes --name <extension-name>
```

GHES の health check (`https://localhost:8443/setup`) が応答することを確認してから次に進んでください。

## 5. デプロイ後に元に戻す手順

GHES 検証・teardown 後、Per-VM の pricing override は VM 削除と同時に消滅するため明示的なクリーンアップは不要です。RG ごと削除する場合:

```bash
az group delete -n rg-ghestest-jpe --yes --no-wait
```

VM 単位で残しつつ pricing override だけ解除したい場合:

```bash
SUB="$AZURE_SUBSCRIPTION_ID"
RG="${RG_NAME:-rg-ghestest-jpe}"
VM=vm-ghestest-ghes

az rest --method DELETE \
  --uri "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Compute/virtualMachines/$VM/providers/Microsoft.Security/pricings/virtualMachines?api-version=2024-01-01"
```

## 6. Trusted Launch ポリシー回避

GHES image は Hyper-V Gen 1 のため、subscription scope の Azure Policy が `securityProfile.securityType: TrustedLaunch` を強制する場合、GHES VM deployment が失敗します。該当 policy assignment を特定し、`rg-ghestest-jpe` Resource Group scope または GHES VM scope に Azure Policy exemption を作成してください。Exemption は `Waiver` または組織ルールに応じた category、期限、チケット番号などの metadata を付け、GHES image が Trusted Launch 非対応であることを description に明記します。詳細な exemption structure は Microsoft Learn を参照してください。

## Sources

- Defender for Servers - Resource-level config (Per-VM): https://learn.microsoft.com/azure/defender-for-cloud/tutorial-enable-servers-plan#enable-defender-for-servers-at-the-resource-level
- Defender for Cloud Pricings REST API (Update Pricing on Resource): https://learn.microsoft.com/rest/api/defenderforcloud-composite/pricings/update?tabs=HTTP#update-pricing-on-resource-%28example-for-virtualmachines-plan%29
- Azure CLI `az security pricing`: https://learn.microsoft.com/cli/azure/security/pricing
- Azure Policy exemption structure: https://learn.microsoft.com/azure/governance/policy/concepts/exemption-structure
