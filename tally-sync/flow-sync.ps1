<#
  Flow Tally Sync  -  READ-ONLY
  ------------------------------------------------------------------
  Reads data from Tally Prime through its built-in XML server
  (Help > Settings > Connectivity, usually http://localhost:9000)
  and saves it as JSON files. Optionally uploads them to Supabase.

  It can ONLY send "Export" requests to Tally. Every request passes
  through Invoke-TallyExport, which refuses anything that could
  import, create, alter or delete data in Tally.

  Usage (on the computer/server where Tally Prime is running):
    powershell -ExecutionPolicy Bypass -File .\flow-sync.ps1 -Test   # check connection, save samples
    powershell -ExecutionPolicy Bypass -File .\flow-sync.ps1 -Once   # one sync, then stop
    powershell -ExecutionPolicy Bypass -File .\flow-sync.ps1         # keep syncing every 2 minutes
    add -Full to re-read every voucher (also happens once a day by itself)

  Works with Windows PowerShell 5.1 (built into Windows). Nothing to install.
#>
[CmdletBinding()]
param(
  [switch]$Test,
  [switch]$Once,
  [switch]$Full,
  [string]$Config = (Join-Path $PSScriptRoot 'flow-sync.config.json')
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$Script:Culture = [Globalization.CultureInfo]::InvariantCulture

# ---------------- settings ----------------
$defaults = [ordered]@{
  tallyUrl          = 'http://localhost:9000'
  company           = ''          # empty = the company currently open in Tally
  intervalSeconds   = 120         # vouchers (sales, orders, challans...) every 2 minutes
  mastersEveryMins  = 10          # parties, items, dues every 10 minutes
  fromDate          = '2024-04-01'# oldest voucher date to read
  outDir            = 'out'
  fullResyncHour    = 3           # re-read everything once a day at this hour (catches deleted entries)
  supabaseUrl       = ''          # filled in later, when the online database is set up
  supabaseKey       = ''
}
$cfg = [pscustomobject]$defaults
if (Test-Path $Config) {
  $user = Get-Content $Config -Raw | ConvertFrom-Json
  foreach ($p in $user.PSObject.Properties) { $cfg | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force }
}
$OutDir = if ([IO.Path]::IsPathRooted($cfg.outDir)) { $cfg.outDir } else { Join-Path $PSScriptRoot $cfg.outDir }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$LogFile = Join-Path $OutDir 'sync.log'

function Write-Log([string]$msg, [string]$level = 'INFO') {
  $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $level, $msg
  Write-Host $line
  Add-Content -Path $LogFile -Value $line -Encoding UTF8
  if ((Get-Item $LogFile).Length -gt 5MB) { Move-Item $LogFile "$LogFile.old" -Force }
}

# ---------------- the only door to Tally (read-only) ----------------
function Invoke-TallyExport([string]$xml) {
  # Hard safety rule: only exports. Anything that could change Tally is refused.
  $blocked = @('<TALLYREQUEST>\s*Import', 'IMPORTDATA', 'ACTION="(Create|Alter|Delete|Cancel)"', '<IMPORT', 'TALLYREQUEST>\s*Execute')
  foreach ($b in $blocked) { if ($xml -match $b) { throw "BLOCKED: this request would change Tally data. Flow Sync is read-only." } }
  if ($xml -notmatch '<TALLYREQUEST>\s*Export') { throw 'BLOCKED: only Export requests are allowed.' }

  $bytes = [Text.Encoding]::UTF8.GetBytes($xml)
  $resp = Invoke-WebRequest -Uri $cfg.tallyUrl -Method Post -Body $bytes -ContentType 'text/xml; charset=utf-8' -UseBasicParsing -TimeoutSec 180
  $raw = $resp.RawContentStream.ToArray()
  $text = if ($raw.Length -ge 2 -and $raw[0] -eq 0xFF -and $raw[1] -eq 0xFE) { [Text.Encoding]::Unicode.GetString($raw) } else { [Text.Encoding]::UTF8.GetString($raw) }
  # Tally sometimes sends characters that are not valid XML; remove them.
  $text = [regex]::Replace($text, '&#(?:[0-8]|1[124-9]|2\d|3[01]);', '')
  $text = [regex]::Replace($text, '[\x00-\x08\x0B\x0C\x0E-\x1F]', '')
  if ($text -match '<LINEERROR>(.*?)</LINEERROR>') { throw "Tally error: $($Matches[1])" }
  return [xml]$text
}

function Esc([string]$s) { [Security.SecurityElement]::Escape($s) }

function Get-StaticVars([string]$from = '', [string]$to = '') {
  $sv = '<SVEXPORTFORMAT>$$SysName:XML</SVEXPORTFORMAT>'
  if ($cfg.company) { $sv += "<SVCURRENTCOMPANY>$(Esc $cfg.company)</SVCURRENTCOMPANY>" }
  if ($from) { $sv += "<SVFROMDATE>$from</SVFROMDATE><SVTODATE>$to</SVTODATE>" }
  return "<STATICVARIABLES>$sv</STATICVARIABLES>"
}

function Get-Collection([string]$id, [string]$collectionTdl, [string]$from = '', [string]$to = '', [string]$extraTdl = '') {
  $xml = @"
<ENVELOPE><HEADER><VERSION>1</VERSION><TALLYREQUEST>Export</TALLYREQUEST><TYPE>Collection</TYPE><ID>$id</ID></HEADER>
<BODY><DESC>$(Get-StaticVars $from $to)<TDL><TDLMESSAGE>$collectionTdl$extraTdl</TDLMESSAGE></TDL></DESC></BODY></ENVELOPE>
"@
  return Invoke-TallyExport $xml
}

# ---------------- small parsers ----------------
function T($node, [string]$path) { if ($null -eq $node) { return '' }; $n = $node.SelectSingleNode($path); if ($n) { $n.InnerText.Trim() } else { '' } }
function Num([string]$s) {
  if (-not $s) { return 0 }
  $m = [regex]::Match(($s -replace ',', ''), '-?\d+(\.\d+)?')
  if ($m.Success) { return [double]::Parse($m.Value, $Script:Culture) } else { return 0 }
}
function Unit([string]$s) { $m = [regex]::Match($s, '[A-Za-z][A-Za-z.]*\s*$'); if ($m.Success) { $m.Value.Trim() } else { '' } }
function TDate([string]$s) {
  if (-not $s) { return '' }
  if ($s -match '^\d{8}$') { return '{0}-{1}-{2}' -f $s.Substring(0,4), $s.Substring(4,2), $s.Substring(6,2) }
  $d = [datetime]::MinValue
  if ([datetime]::TryParseExact($s.Trim(), [string[]]@('d-MMM-yy','d-MMM-yyyy','dd-MMM-yy','dd-MMM-yyyy'), $Script:Culture, 'None', [ref]$d)) { return $d.ToString('yyyy-MM-dd') }
  return $s
}
function TallyDate([datetime]$d) { $d.ToString('yyyyMMdd') }
function NameOf($node) { $a = $node.GetAttribute('NAME'); if ($a) { $a } else { T $node 'NAME' } }

# ---------------- what we read ----------------
function Read-Companies {
  $x = Get-Collection 'FlowCompanies' '<COLLECTION NAME="FlowCompanies"><TYPE>Company</TYPE><FETCH>NAME, STARTINGFROM, ENDINGAT</FETCH></COLLECTION>'
  @($x.SelectNodes('//COMPANY') | ForEach-Object { [ordered]@{ name = (NameOf $_); from = (TDate (T $_ 'STARTINGFROM')) } })
}

function Read-Parties([string]$groupVar, [string]$kind) {
  $fetch = 'NAME, PARENT, CLOSINGBALANCE, PARTYGSTIN, LEDGSTREGDETAILS.GSTIN, LEDGERPHONE, LEDGERMOBILE, EMAIL, ADDRESS, LEDSTATENAME, PINCODE, CREDITLIMIT, BILLCREDITPERIOD, LEDGERCONTACT'
  $tdl = "<COLLECTION NAME=`"Flow$kind`"><TYPE>Ledger</TYPE><CHILDOF>$groupVar</CHILDOF><BELONGSTO>Yes</BELONGSTO><FETCH>$fetch</FETCH></COLLECTION>"
  $x = Get-Collection "Flow$kind" $tdl
  @($x.SelectNodes('//LEDGER') | ForEach-Object {
    $bal = Num (T $_ 'CLOSINGBALANCE')
    $gstin = T $_ 'PARTYGSTIN'; if (-not $gstin) { $gstin = T $_ 'LEDGSTREGDETAILS.LIST/GSTIN' }
    [ordered]@{
      name = (NameOf $_); group = (T $_ 'PARENT'); kind = $kind
      balance = $bal                                   # Tally: debit is negative
      due = if ($kind -eq 'Debtors') { -$bal } else { $bal }   # positive = they owe us / we owe them
      gstin = $gstin; phone = (T $_ 'LEDGERPHONE'); mobile = (T $_ 'LEDGERMOBILE'); email = (T $_ 'EMAIL')
      contact = (T $_ 'LEDGERCONTACT')
      address = (@($_.SelectNodes('ADDRESS.LIST/ADDRESS') | ForEach-Object { $_.InnerText.Trim() }) -join ', ')
      state = (T $_ 'LEDSTATENAME'); pincode = (T $_ 'PINCODE')
      creditLimit = [math]::Abs((Num (T $_ 'CREDITLIMIT'))); creditDays = (Num (T $_ 'BILLCREDITPERIOD'))
    } })
}

function Read-Items {
  $fetch = 'NAME, PARENT, CATEGORY, BASEUNITS, CLOSINGBALANCE, CLOSINGRATE, CLOSINGVALUE, REORDERBASE, MINIMUMORDERBASE, GSTAPPLICABLE'
  $x = Get-Collection 'FlowItems' "<COLLECTION NAME=`"FlowItems`"><TYPE>StockItem</TYPE><FETCH>$fetch</FETCH></COLLECTION>"
  @($x.SelectNodes('//STOCKITEM') | ForEach-Object {
    $cb = T $_ 'CLOSINGBALANCE'
    [ordered]@{
      name = (NameOf $_); group = (T $_ 'PARENT'); category = (T $_ 'CATEGORY')
      unit = if (T $_ 'BASEUNITS') { T $_ 'BASEUNITS' } else { Unit $cb }
      qty = (Num $cb); rate = (Num (T $_ 'CLOSINGRATE')); value = [math]::Abs((Num (T $_ 'CLOSINGVALUE')))
      reorder = (Num (T $_ 'REORDERBASE')); minOrder = (Num (T $_ 'MINIMUMORDERBASE'))
    } })
}

function Read-Bills {
  $xml = @"
<ENVELOPE><HEADER><TALLYREQUEST>Export Data</TALLYREQUEST></HEADER><BODY><EXPORTDATA><REQUESTDESC>
<REPORTNAME>Bills Receivable</REPORTNAME>$(Get-StaticVars)</REQUESTDESC></EXPORTDATA></BODY></ENVELOPE>
"@
  $x = Invoke-TallyExport $xml
  $bills = @(); $cur = $null
  foreach ($n in $x.DocumentElement.ChildNodes) {
    switch ($n.Name) {
      'BILLFIXED'   { if ($cur) { $bills += $cur }; $cur = [ordered]@{ party = (T $n 'BILLPARTY'); ref = (T $n 'BILLREF'); date = (TDate (T $n 'BILLDATE')); amount = 0; dueDate = ''; overdueDays = 0 } }
      'BILLCL'      { if ($cur) { $cur.amount = [math]::Abs((Num $n.InnerText)) } }
      'BILLDUE'     { if ($cur) { $cur.dueDate = TDate $n.InnerText } }
      'BILLOVERDUE' { if ($cur) { $cur.overdueDays = Num $n.InnerText } }
    }
  }
  if ($cur) { $bills += $cur }
  return $bills
}

function Read-Vouchers([long]$afterAlterId, [datetime]$from) {
  $fetch = 'DATE, VOUCHERTYPENAME, VOUCHERNUMBER, REFERENCE, PARTYLEDGERNAME, AMOUNT, ALTERID, MASTERID, GUID, NARRATION, ISCANCELLED, ISOPTIONAL, ISDELETED, ' +
           'ALLINVENTORYENTRIES.STOCKITEMNAME, ALLINVENTORYENTRIES.ACTUALQTY, ALLINVENTORYENTRIES.BILLEDQTY, ALLINVENTORYENTRIES.RATE, ALLINVENTORYENTRIES.AMOUNT, ' +
           'ALLINVENTORYENTRIES.BATCHALLOCATIONS.GODOWNNAME, ALLINVENTORYENTRIES.BATCHALLOCATIONS.ORDERNO, ALLINVENTORYENTRIES.BATCHALLOCATIONS.ORDERDUEDATE, ' +
           'LEDGERENTRIES.LEDGERNAME, LEDGERENTRIES.AMOUNT'
  $tdl = "<COLLECTION NAME=`"FlowVouchers`"><TYPE>Voucher</TYPE><FETCH>$fetch</FETCH><FILTER>FlowChanged</FILTER></COLLECTION>"
  $flt = "<SYSTEM TYPE=`"Formulae`" NAME=`"FlowChanged`">`$AlterID &gt; $afterAlterId</SYSTEM>"
  $x = Get-Collection 'FlowVouchers' $tdl (TallyDate $from) (TallyDate (Get-Date).AddDays(1)) $flt
  @($x.SelectNodes('//VOUCHER') | ForEach-Object {
    $v = $_
    $invList = @($v.SelectNodes('ALLINVENTORYENTRIES.LIST')); if (-not $invList.Count) { $invList = @($v.SelectNodes('INVENTORYENTRIES.LIST')) }
    $items = @($invList | ForEach-Object {
      $q = T $_ 'ACTUALQTY'; if (-not $q) { $q = T $_ 'BILLEDQTY' }
      [ordered]@{
        item = (T $_ 'STOCKITEMNAME'); qty = [math]::Abs((Num $q)); billedQty = [math]::Abs((Num (T $_ 'BILLEDQTY'))); unit = (Unit $q)
        rate = (Num (T $_ 'RATE')); amount = [math]::Abs((Num (T $_ 'AMOUNT')))
        godown = (T $_ 'BATCHALLOCATIONS.LIST/GODOWNNAME'); orderNo = (T $_ 'BATCHALLOCATIONS.LIST/ORDERNO')
        orderDue = (TDate (T $_ 'BATCHALLOCATIONS.LIST/ORDERDUEDATE'))
      } })
    $amt = [math]::Abs((Num (T $v 'AMOUNT')))
    if (-not $amt) { $amt = 0; foreach ($it in $items) { $amt += [double]$it.amount } }
    [ordered]@{
      guid = (T $v 'GUID'); masterId = (Num (T $v 'MASTERID')); alterId = (Num (T $v 'ALTERID'))
      date = (TDate (T $v 'DATE')); type = (T $v 'VOUCHERTYPENAME'); number = (T $v 'VOUCHERNUMBER'); reference = (T $v 'REFERENCE')
      party = (T $v 'PARTYLEDGERNAME'); amount = $amt; narration = (T $v 'NARRATION')
      cancelled = ((T $v 'ISCANCELLED') -eq 'Yes'); optional = ((T $v 'ISOPTIONAL') -eq 'Yes')
      items = $items
    } })
}

# ---------------- saving ----------------
function Save-Json([string]$name, $data) {
  $path = Join-Path $OutDir "$name.json"
  $tmp = "$path.tmp"
  ($data | ConvertTo-Json -Depth 8 -Compress) | Set-Content -Path $tmp -Encoding UTF8
  Move-Item $tmp $path -Force
}
function Load-Json([string]$name) {
  $path = Join-Path $OutDir "$name.json"
  if (Test-Path $path) { return (Get-Content $path -Raw | ConvertFrom-Json) } else { return $null }
}

function Send-Supabase([string]$table, $rows, [string]$conflict) {
  if (-not $cfg.supabaseUrl -or -not $cfg.supabaseKey) { return }
  $uri = ($cfg.supabaseUrl.TrimEnd('/')) + "/rest/v1/$table" + $(if ($conflict) { "?on_conflict=$conflict" } else { '' })
  $headers = @{ apikey = $cfg.supabaseKey; Authorization = "Bearer $($cfg.supabaseKey)"; Prefer = 'resolution=merge-duplicates,return=minimal' }
  $all = @($rows)
  for ($i = 0; $i -lt $all.Count; $i += 500) {
    $chunk = $all[$i..([math]::Min($i + 499, $all.Count - 1))]
    $body = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json @($chunk) -Depth 8 -Compress))
    Invoke-WebRequest -Uri $uri -Method Post -Headers $headers -Body $body -ContentType 'application/json; charset=utf-8' -UseBasicParsing -TimeoutSec 120 | Out-Null
  }
}
function Send-Snapshot([string]$dataset, $data) {
  Send-Supabase 'tally_snapshot' @([ordered]@{ dataset = $dataset; data = $data; synced_at = (Get-Date).ToUniversalTime().ToString('o') }) 'dataset'
}

# ---------------- one sync cycle ----------------
$script:state = Load-Json 'state'
if (-not $script:state) { $script:state = [pscustomobject]@{ lastAlterId = 0; lastFull = ''; lastMasters = ''; lastSync = '' } }

function Sync-Masters {
  $debtors = Read-Parties '$$GroupSundryDebtors' 'Debtors'
  $creditors = Read-Parties '$$GroupSundryCreditors' 'Creditors'
  $items = Read-Items
  $bills = Read-Bills
  Save-Json 'parties' (@($debtors) + @($creditors)); Save-Json 'items' $items; Save-Json 'bills' $bills
  Send-Snapshot 'parties' (@($debtors) + @($creditors)); Send-Snapshot 'items' $items; Send-Snapshot 'bills' $bills
  $script:state.lastMasters = (Get-Date).ToString('o')
  Write-Log ("Masters: {0} customers, {1} suppliers, {2} items, {3} open bills" -f @($debtors).Count, @($creditors).Count, @($items).Count, @($bills).Count)
}

function Sync-Vouchers([bool]$full) {
  $from = [datetime]::ParseExact($cfg.fromDate, 'yyyy-MM-dd', $Script:Culture)
  $after = if ($full) { 0 } else { [long]$script:state.lastAlterId }
  $new = @(Read-Vouchers $after $from)
  $store = @{}
  if (-not $full) { $old = Load-Json 'vouchers'; if ($old) { foreach ($v in @($old)) { $store[[string]$v.guid] = $v } } }
  foreach ($v in $new) { $store[[string]$v.guid] = $v }
  $all = @($store.Values | Sort-Object { $_.date }, { $_.alterId })
  Save-Json 'vouchers' $all
  if ($new.Count) { Send-Supabase 'tally_vouchers' ($new | ForEach-Object { [ordered]@{ guid = $_.guid; alter_id = $_.alterId; vdate = $_.date; vtype = $_.type; data = $_ } }) 'guid' }
  $max = 0; foreach ($v in $all) { if ([double]$v.alterId -gt $max) { $max = [double]$v.alterId } }
  if ($max) { $script:state.lastAlterId = [long]$max }
  if ($full) { $script:state.lastFull = (Get-Date).ToString('o') }
  Write-Log ("Vouchers: {0} new/changed, {1} total{2}" -f $new.Count, $all.Count, $(if ($full) { ' (full re-read)' } else { '' }))
}

function Sync-Once([bool]$forceFull) {
  $now = Get-Date
  $needFull = $forceFull -or -not $script:state.lastFull -or (
    $now.Hour -eq [int]$cfg.fullResyncHour -and ([datetime]::Parse($script:state.lastFull)).Date -lt $now.Date)
  $needMasters = $needFull -or -not $script:state.lastMasters -or (($now - [datetime]::Parse($script:state.lastMasters)).TotalMinutes -ge [int]$cfg.mastersEveryMins)
  if ($needMasters) { Sync-Masters }
  Sync-Vouchers $needFull
  $script:state.lastSync = $now.ToString('o')
  Save-Json 'state' $script:state
  Save-Json 'status' ([ordered]@{ ok = $true; lastSync = $script:state.lastSync; tallyUrl = $cfg.tallyUrl; company = $cfg.company })
  Send-Snapshot 'status' ([ordered]@{ ok = $true; lastSync = $script:state.lastSync })
}

# ---------------- test mode ----------------
function Run-Test {
  Write-Host ''
  Write-Host '=== Flow Tally Sync: connection test (read-only) ===' -ForegroundColor Cyan
  $ok = $true
  try {
    $companies = Read-Companies
    Write-Host ("[PASS] Tally answered at {0}" -f $cfg.tallyUrl) -ForegroundColor Green
    if (@($companies).Count) { $companies | ForEach-Object { Write-Host ("       Company open: {0} (books from {1})" -f $_.name, $_.from) } }
    else { Write-Host '[WARN] No company is open in Tally. Open the company, then test again.' -ForegroundColor Yellow; $ok = $false }
  } catch {
    Write-Host ("[FAIL] Could not reach Tally at {0}: {1}" -f $cfg.tallyUrl, $_.Exception.Message) -ForegroundColor Red
    Write-Host '       In Tally Prime: Help (F1) > Settings > Connectivity > Client/Server configuration:' -ForegroundColor Yellow
    Write-Host '       "TallyPrime acts as" = Both (or Server), "Enable ODBC" = Yes, Port = 9000. Restart Tally.' -ForegroundColor Yellow
    return
  }
  $samples = Join-Path $OutDir 'samples'; New-Item -ItemType Directory -Force -Path $samples | Out-Null
  $checks = @(
    @{ n = 'Customers (Sundry Debtors)'; f = { Read-Parties '$$GroupSundryDebtors' 'Debtors' } },
    @{ n = 'Suppliers (Sundry Creditors)'; f = { Read-Parties '$$GroupSundryCreditors' 'Creditors' } },
    @{ n = 'Stock items'; f = { Read-Items } },
    @{ n = 'Bills receivable'; f = { Read-Bills } },
    @{ n = 'Vouchers, last 7 days'; f = { Read-Vouchers 0 ((Get-Date).AddDays(-7)) } }
  )
  foreach ($c in $checks) {
    try {
      $r = @(& $c.f)
      Write-Host ("[PASS] {0}: {1} found" -f $c.n, $r.Count) -ForegroundColor Green
      $file = Join-Path $samples (($c.n -replace '[^A-Za-z]+', '-').Trim('-').ToLower() + '.json')
      ($r | Select-Object -First 5 | ConvertTo-Json -Depth 8) | Set-Content -Path $file -Encoding UTF8
      if ($c.n -like 'Vouchers*') { $r | Group-Object { $_.type } | ForEach-Object { Write-Host ("       {0}: {1}" -f $_.Name, $_.Count) } }
    } catch { $ok = $false; Write-Host ("[FAIL] {0}: {1}" -f $c.n, $_.Exception.Message) -ForegroundColor Red }
  }
  Write-Host ''
  Write-Host ("Up to 5 examples of each were saved in: {0}" -f $samples)
  Write-Host 'Nothing was changed in Tally.' -ForegroundColor Cyan
  if ($ok) { Write-Host 'Test passed. You can now run without -Test.' -ForegroundColor Green }
}

# ---------------- main ----------------
if ($Test) { Run-Test; return }
Write-Log ("Flow Tally Sync started (read-only). Tally: {0}. Every {1}s." -f $cfg.tallyUrl, $cfg.intervalSeconds)
$firstFull = [bool]$Full
while ($true) {
  try { Sync-Once $firstFull; $firstFull = $false }
  catch {
    Write-Log $_.Exception.Message 'ERROR'
    try { Save-Json 'status' ([ordered]@{ ok = $false; error = $_.Exception.Message; at = (Get-Date).ToString('o'); lastSync = $script:state.lastSync }) } catch {}
  }
  if ($Once) { break }
  Start-Sleep -Seconds ([int]$cfg.intervalSeconds)
}
