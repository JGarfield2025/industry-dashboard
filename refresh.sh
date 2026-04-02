#!/bin/bash
# Daily refresh script for CuraLinc Industry Dashboard
# Pulls Zoho CRM account data by industry, rebuilds password-protected dashboard, pushes to GitHub
set -euo pipefail

REPO_DIR="/Users/jessicagarfield/industry-dashboard"
LOG_FILE="$REPO_DIR/refresh.log"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"; }

log "Starting industry dashboard refresh..."

# Step 1: Use Claude to pull data from Zoho CRM and save to temp files
claude -p "Pull account data from Zoho CRM and save it. Use ONLY the tool mcp__zoho-crm__ZohoCRM_executeCOQLQuery for queries.

TASK 1 - Pull detailed accounts for top 5 industries. For EACH of these industries, call mcp__claude_ai_Zoho_CRM__executeCOQLQuery with this COQL query:
  SELECT Account_Name, Industry, Billing_State, Account_Type, Marquee_Account_Type, Number_of_Employees_2, Eligible_Count, Products, Lead_Source, Effective_Date, Contract_Renewal_Date, Owner FROM Accounts WHERE Industry = '<INDUSTRY>' LIMIT 2000

Industries: Healthcare, Manufacturing/Distribution, Education, Professional Services, Technology

If any query returns more_records=true in the info object, paginate with OFFSET 2000, 4000, etc until done.

TASK 2 - Pull ALL industry counts. Call mcp__claude_ai_Zoho_CRM__executeCOQLQuery with:
  SELECT Industry FROM Accounts WHERE Industry is not null LIMIT 2000
Paginate through ALL offsets until more_records=false.

AFTER PULLING ALL DATA, write a Python script to /tmp/build_industry_json.py that:
1. Reads all the raw result files saved by tool calls (check the tool-results directories)
2. For detailed records: normalizes each into {Account_Name, Industry, Billing_State, Account_Type, Marquee_Account_Type, Number_of_Employees (from Number_of_Employees_2), Eligible_Count, Products, Lead_Source, Effective_Date, Contract_Renewal_Date, Owner (extract name from Owner object)}
3. Saves the combined detailed records array to /tmp/industry_data.json
4. Counts all industries from TASK 2 results and saves to /tmp/industry_counts.json
5. Prints the total record counts

Then run: python3 /tmp/build_industry_json.py

Do NOT ask questions. Work autonomously." --allowedTools "Bash,Read,Write,Edit,Glob,Grep,mcp__claude_ai_Zoho_CRM__executeCOQLQuery" 2>&1 | tee -a "$LOG_FILE"

if [ ! -f /tmp/industry_data.json ]; then
  log "ERROR: industry_data.json was not created"
  exit 1
fi

log "Data pull complete. Rebuilding dashboard..."

# Step 2: Rebuild the dashboard HTML locally with Python (no Claude needed)
python3 << 'PYEOF'
import json, re

data = json.load(open('/tmp/industry_data.json'))
total = len(data)

html = open('/Users/jessicagarfield/industry-dashboard/index.html').read()

# Replace the data payload using string find/replace to avoid regex escape issues
marker_start = 'const RAW_DATA = '
start_idx = html.index(marker_start)
# Find the matching semicolon after the array
bracket_start = html.index('[', start_idx)
depth = 0
end_idx = bracket_start
for i, ch in enumerate(html[bracket_start:], bracket_start):
    if ch == '[': depth += 1
    elif ch == ']': depth -= 1
    if depth == 0:
        end_idx = i + 1
        break
# Find the semicolon after the closing bracket
semi_idx = html.index(';', end_idx)

json_str = json.dumps(data, separators=(',',':'))
html = html[:bracket_start] + json_str + html[semi_idx:]

# Update the subtitle count
html = re.sub(
    r'\d[\d,]+ Accounts from Zoho CRM',
    f'{total:,} Accounts from Zoho CRM',
    html
)

open('/Users/jessicagarfield/industry-dashboard/index.html', 'w').write(html)
print(f"Dashboard rebuilt with {total:,} records")
PYEOF

if [ $? -ne 0 ]; then
  log "ERROR: Failed to rebuild dashboard HTML"
  exit 1
fi

log "Dashboard rebuilt. Pushing to GitHub..."

# Step 3: Commit and push
cd "$REPO_DIR"
git add index.html
git commit -m "Daily refresh: $(date +%Y-%m-%d)"
git push origin main

log "Industry dashboard refresh completed successfully"
