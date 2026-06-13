# SOA03-05DAY — X-Ray + CloudWatch でマイクロサービスを監視・実測検証

AWS Skill Builder ラボ「Monitoring Micro-Service Architectures with AWS X-Ray and Amazon CloudWatch」を題材に、ラボが省略している**運用観点**を Terraform 最小構成で実測検証する。

## 検証する想定（仮説）

| ID | 想定 | 実測する数値 |
|----|------|------|
| A | X-Ray 既定サンプリング（1 req/秒 + 5%）で、全リクエストは記録されない | 送信数 vs 記録トレース数 |
| B | X-Ray デーモンのバッファ溢れはセグメントを**静かにドロップ**する | ドロップ/spillover 数（or 沈黙の失敗の確認） |
| C | トレースのフォルト(5xx)を CloudWatch アラーム化できる | フォルト注入 → ALARM までの秒数 |
| D | `dynamic_naming='*'` は偽装 Host でサービスマップのノード名を汚染する | 汚染ノード数 / 固定naming で再現せず |

## 構成

```
            (SSM Session Manager / send-command)
                        │  curl localhost
                        ▼
   ┌──────────────────────────────────────────┐
   │  EC2 t3.micro (AL2023, default VPC)        │
   │  ┌────────────┐   UDP:2000  ┌───────────┐ │
   │  │ Flask app  │ ──────────▶ │ X-Ray     │ │──▶ X-Ray / CloudWatch
   │  │ :8080      │  segments   │ daemon    │ │   (トレース / サービスマップ)
   │  │ (xray-sdk) │             └───────────┘ │
   │  └────────────┘                            │
   │   patch_all() -> boto3 STS = 下流ノード     │
   └──────────────────────────────────────────┘
```

- **インバウンドなし**（egress のみ）。負荷・偽装 Host は全て SSM 経由で `localhost` に投げる＝インスタンスを公開しない。
- IAM: `AmazonSSMManagedInstanceCore` + `AWSXRayDaemonWriteAccess`（後者は PutTraceSegments に加え SDK の中央サンプリング `GetSampling*` も含む）。
- 安全策: `shutdown -h +1440`、IMDSv2 必須、root EBS 暗号化 + `delete_on_termination`。

## 使い方

```bash
terraform init
terraform plan
terraform apply          # 課金開始。AWSアカウントに t3.micro 1台
# ... 検証（下記 Runbook）...
terraform destroy        # 必ず実行
```

変数（任意）:
- `alarm_email` … 設定するとアラーム通知メールを購読（確認は手動）。既定は購読なしで状態履歴から実測。
- `instance_type` … 既定 `t3.micro`。

## 検証 Runbook

`IID` はインスタンス ID（`terraform output -raw instance_id`）。SSM でインスタンス内に `curl localhost` を打ち込み、X-Ray/CloudWatch API で結果を読む。

### 共通: SSM でコマンド実行するヘルパ
```bash
run() {  # run "<shell>" -> prints stdout
  CID=$(aws ssm send-command --instance-ids "$IID" \
    --document-name AWS-RunShellScript \
    --parameters commands="[\"$1\"]" \
    --query Command.CommandId --output text)
  sleep 6
  aws ssm get-command-invocation --command-id "$CID" --instance-id "$IID" \
    --query StandardOutputContent --output text
}
```

### A: サンプリング
```bash
T0=$(date -u +%Y-%m-%dT%H:%M:%S)
run 'seq 600 | xargs -P20 -I{} curl -s -o /dev/null localhost:8080/'
sleep 40
T1=$(date -u +%Y-%m-%dT%H:%M:%S)
aws xray get-trace-summaries --start-time "$T0" --end-time "$T1" \
  --query 'length(TraceSummaries)'   # 記録トレース数 << 600 を期待
```

### B: デーモンドロップ（100%サンプリングで負荷）
```bash
# 100%サンプリングルールを作成（reservoir 高め）
aws xray create-sampling-rule --sampling-rule \
  'RuleName=all,Priority=1,FixedRate=1.0,ReservoirSize=2000,ServiceName=*,ServiceType=*,Host=*,HTTPMethod=*,URLPath=*,ResourceARN=*,Version=1'
run 'for i in $(seq 1 5000); do curl -s -o /dev/null localhost:8080/health & done; wait'
run 'grep -iE "drop|full|spill|reject" /var/log/xray/xray.log | tail -20'
run 'tail -5 /var/log/xray/xray.log'   # Successfully sent batch... の確認
# 後始末
aws xray delete-sampling-rule --rule-name all
```

### C: フォルトアラーム
```bash
aws cloudwatch list-metrics --namespace AWS/X-Ray   # 実在メトリクス確認
run 'for i in $(seq 1 60); do curl -s -o /dev/null localhost:8080/fault; sleep 1; done'
# ALARM 遷移を監視
for i in $(seq 1 30); do
  aws cloudwatch describe-alarms --alarm-names "$(terraform output -raw alarm_name)" \
    --query 'MetricAlarms[0].StateValue' --output text; sleep 20; done
aws cloudwatch describe-alarm-history --alarm-name "$(terraform output -raw alarm_name)" \
  --history-item-type StateUpdate --query 'AlarmHistoryItems[].[Timestamp,HistorySummary]' --output text
```

### D: dynamic_naming のノード名汚染
```bash
GRP=$(terraform output -raw xray_group_name)
T0=$(date -u -d '-10 min' +%Y-%m-%dT%H:%M:%S); T1=$(date -u +%Y-%m-%dT%H:%M:%S)
aws xray get-service-graph --start-time "$T0" --end-time "$T1" \
  --query 'Services[].Name'   # baseline
run 'for h in spoofed-203-0-113-7.test admin.internal.test x.attacker.test; do curl -s -o /dev/null -H "Host: $h" localhost:8080/; done'
sleep 40
aws xray get-service-graph --start-time "$T0" --end-time "$(date -u +%Y-%m-%dT%H:%M:%S)" \
  --query 'Services[].Name'   # 偽装 Host 名がノードとして出現
```

> 偽装 Host は予約レンジ風の名前のみ。Host ヘッダを差し替えるだけで宛先は常に `localhost`、実ホストへは到達しない。

## ハマりどころ

（検証後に実測値とともに追記）

## クリーンアップ確認

```bash
terraform destroy
aws xray get-groups --query "Groups[?GroupName=='$(terraform output -raw xray_group_name 2>/dev/null)']"  # 空
aws ec2 describe-instances --filters "Name=tag:Name,Values=soa05-xray-app" \
  --query 'Reservations[].Instances[].State.Name'   # terminated のみ
# B で作った sampling-rule を消し忘れないこと
aws xray get-sampling-rules --query "SamplingRuleRecords[?SamplingRule.RuleName=='all']"  # 空
```
