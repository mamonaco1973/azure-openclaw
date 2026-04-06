#!/bin/bash
set -euo pipefail

# ================================================================================
# Azure Helper Scripts
# ================================================================================
#
# Installs pre-built Azure helper scripts into /usr/local/bin so the agent
# can run them directly without constructing complex commands inline.
#
# ================================================================================

echo "NOTE: [azure-tools] installing azure-cost-report"
cat > /usr/local/bin/azure-cost-report <<'EOF'
#!/bin/bash
# Azure Cost Report — month-to-date spend by service
# Usage: azure-cost-report [subscription-id]
# Cached for 60s due to Azure Cost Management API rate limits (429).

SUBSCRIPTION="${1:-$(az account show --query id -o tsv)}"
URL="https://management.azure.com/subscriptions/${SUBSCRIPTION}/providers/Microsoft.CostManagement/query?api-version=2023-11-01"
CACHE_FILE="/tmp/azure-cost-report.cache"

if [ -f "$CACHE_FILE" ]; then
  AGE=$(( $(date +%s) - $(stat -c %Y "$CACHE_FILE") ))
  if [ "$AGE" -lt 60 ]; then
    cat "$CACHE_FILE"
    exit 0
  fi
fi

cost_query() {
  az rest --method POST --url "$URL" --body "$1"
}

{
  echo "=== Month-to-Date Total ==="
  cost_query '{"type":"Usage","timeframe":"MonthToDate","dataset":{"granularity":"None","aggregation":{"totalCost":{"name":"PreTaxCost","function":"Sum"}}}}' \
    | jq -r '"Total: $\(.properties.rows[0][0] | . * 100 | round / 100) USD"'

  echo ""
  echo "=== Daily Breakdown (Last 7 Days) ==="
  START=$(date -u -d '7 days ago' '+%Y-%m-%dT00:00:00Z')
  END=$(date -u '+%Y-%m-%dT00:00:00Z')
  cost_query "{\"type\":\"Usage\",\"timeframe\":\"Custom\",\"timePeriod\":{\"from\":\"${START}\",\"to\":\"${END}\"},\"dataset\":{\"granularity\":\"Daily\",\"aggregation\":{\"totalCost\":{\"name\":\"PreTaxCost\",\"function\":\"Sum\"}}}}" \
    | jq -r '.properties.rows[] | "\(.[1]): $\(.[0] | . * 100 | round / 100) USD"'

  echo ""
  echo "=== Top Services This Month ==="
  cost_query '{"type":"Usage","timeframe":"MonthToDate","dataset":{"granularity":"None","aggregation":{"totalCost":{"name":"PreTaxCost","function":"Sum"}},"grouping":[{"type":"Dimension","name":"ServiceName"}]}}' \
    | jq -r '.properties.rows | sort_by(.[0]) | reverse[] | "\(.[1]): $\(.[0] | . * 100 | round / 100) USD"'
} | tee "$CACHE_FILE"
EOF
chmod +x /usr/local/bin/azure-cost-report

echo "NOTE: [azure-tools] installing send-cost-report"
cat > /usr/local/bin/send-cost-report <<'EOF'
#!/bin/bash
# Send Azure Cost Report as HTML email
# Usage: send-cost-report <email-address>

set -euo pipefail

TO="${1:?Usage: send-cost-report <email-address>}"
REPORT=$(azure-cost-report)
DATE=$(date '+%B %d, %Y')

# Parse sections
TOTAL=$(echo "$REPORT" | grep '^Total:' | head -1)

DAILY_ROWS=$(echo "$REPORT" | awk '/^=== Daily Breakdown/,/^$/' | grep -v '^===' | grep -v '^$' | while read -r line; do
  DAY=$(echo "$line" | cut -d: -f1)
  AMOUNT=$(echo "$line" | cut -d' ' -f2-)
  echo "<tr><td>${DAY}</td><td>${AMOUNT}</td></tr>"
done)

SERVICE_ROWS=$(echo "$REPORT" | awk '/^=== Top Services/,/^$/' | grep -v '^===' | grep -v '^$' | while read -r line; do
  SERVICE=$(echo "$line" | sed 's/: \$[0-9.]* USD//')
  AMOUNT=$(echo "$line" | grep -o '\$[0-9.]* USD')
  echo "<tr><td>${SERVICE}</td><td>${AMOUNT}</td></tr>"
done)

HTML=$(cat <<HTML
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<style>
  body { font-family: Arial, sans-serif; max-width: 700px; margin: 40px auto; color: #222; }
  h1 { color: #0078d4; }
  h2 { color: #444; border-bottom: 1px solid #ddd; padding-bottom: 6px; }
  .total { font-size: 2em; font-weight: bold; color: #0078d4; margin: 16px 0; }
  table { border-collapse: collapse; width: 100%; margin-bottom: 24px; }
  th { background: #0078d4; color: white; text-align: left; padding: 8px 12px; }
  td { padding: 7px 12px; border-bottom: 1px solid #eee; }
  tr:last-child td { border-bottom: none; }
</style>
</head>
<body>
<h1>Azure Cost Report</h1>
<p>${DATE}</p>

<h2>Month-to-Date Total</h2>
<div class="total">${TOTAL}</div>

<h2>Daily Breakdown (Last 7 Days)</h2>
<table>
  <tr><th>Date</th><th>Cost</th></tr>
  ${DAILY_ROWS}
</table>

<h2>Top Services This Month</h2>
<table>
  <tr><th>Service</th><th>Cost</th></tr>
  ${SERVICE_ROWS}
</table>
</body>
</html>
HTML
)

echo "$HTML" | acs-mail -s "Azure Cost Report — ${DATE}" -t "$TO"
echo "NOTE: Cost report sent to ${TO}"
EOF
chmod +x /usr/local/bin/send-cost-report

echo "NOTE: [azure-tools] done"
