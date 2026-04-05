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

SUBSCRIPTION="${1:-$(az account show --query id -o tsv)}"
TOKEN=$(az account get-access-token --resource https://management.azure.com --query accessToken -o tsv)
URL="https://management.azure.com/subscriptions/${SUBSCRIPTION}/providers/Microsoft.CostManagement/query?api-version=2023-11-01"

echo "=== Month-to-Date Total ==="
curl -s -X POST "$URL" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"type":"Usage","timeframe":"MonthToDate","dataset":{"granularity":"None","aggregation":{"totalCost":{"name":"PreTaxCost","function":"Sum"}}}}' \
  | jq -r '"Total: $\(.properties.rows[0][0] | . * 100 | round / 100) USD"'

echo ""
echo "=== Daily Breakdown (Last 7 Days) ==="
START=$(date -u -d '7 days ago' '+%Y-%m-%dT00:00:00Z')
END=$(date -u '+%Y-%m-%dT00:00:00Z')
curl -s -X POST "$URL" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"type\":\"Usage\",\"timePeriod\":{\"from\":\"${START}\",\"to\":\"${END}\"},\"dataset\":{\"granularity\":\"Daily\",\"aggregation\":{\"totalCost\":{\"name\":\"PreTaxCost\",\"function\":\"Sum\"}}}}" \
  | jq -r '.properties.rows[] | "\(.[1]): $\(.[0] | . * 100 | round / 100) USD"'

echo ""
echo "=== Top Services This Month ==="
curl -s -X POST "$URL" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"type":"Usage","timeframe":"MonthToDate","dataset":{"granularity":"None","aggregation":{"totalCost":{"name":"PreTaxCost","function":"Sum"}},"grouping":[{"type":"Dimension","name":"ServiceName"}]}}' \
  | jq -r '.properties.rows | sort_by(.[0]) | reverse[] | "\(.[1]): $\(.[0] | . * 100 | round / 100) USD"'
EOF
chmod +x /usr/local/bin/azure-cost-report

echo "NOTE: [azure-tools] done"
