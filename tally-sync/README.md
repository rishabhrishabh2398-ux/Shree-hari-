# Flow Tally Sync (read-only)

A small PowerShell script that runs **on the same computer/server as Tally Prime**, reads data from Tally every 2 minutes, and (later) sends it to the Flow Dashboard's online database.

**It never changes anything in Tally.** Every request goes through one function (`Invoke-TallyExport`) that only allows Tally "Export" requests and refuses anything that could import, create, alter or delete. This was tested.

## What it reads
| Data | How often | From Tally |
|---|---|---|
| Customers: name, group, balance, GSTIN, phone, address, state, credit limit, credit days | every 10 min | Ledgers under Sundry Debtors |
| Suppliers (Hindware, Racold, UltraTech, Jaypee…) and what we owe | every 10 min | Ledgers under Sundry Creditors |
| Stock items: closing qty, unit, rate, value, reorder level | every 10 min | Stock Items |
| Open bills: party, bill no., date, amount, days overdue | every 10 min | Bills Receivable report |
| Vouchers: Sales Orders, Delivery Notes, Sales, Purchase Orders, Purchases, Receipts… with items, qty, godown, order no. | every 2 min, only new or changed ones | Vouchers (by AlterID) |

Once a day (3 am by default) it re-reads all vouchers, so entries deleted in Tally also disappear from the dashboard.

## Requirements
- Windows with PowerShell 5.1 (built into every Windows since 2016). **Nothing to install.**
- Tally Prime running with the company open.
- Tally's XML server turned on: **F1 Help → Settings → Connectivity → Client/Server configuration**:
  - TallyPrime acts as: **Both** (or Server)
  - Enable ODBC: **Yes**
  - Port: **9000**
  - Restart Tally after changing.
- Port 9000 stays **inside the server**. Do **not** open it to the internet. The script talks to `localhost` only.
- Later, for live upload: outgoing HTTPS (port 443) to `*.supabase.co`.

## Questions for the Tally cloud provider
1. Can we copy one folder (3 small files) onto our Tally server and run a PowerShell script there?
2. Can we enable Tally's Client/Server (XML/ODBC) on port 9000 for localhost?
3. Can the script keep running when nobody is logged in to the remote desktop (Task Scheduler), or only while our session is open?
4. Is outgoing HTTPS to supabase.co allowed?

## Setup (about 10 minutes)
1. Copy the `tally-sync` folder to the Tally server, for example `C:\FlowSync`.
2. Copy `flow-sync.config.example.json` to `flow-sync.config.json`. If more than one company is loaded in Tally, put the exact company name in `"company"`.
3. Open PowerShell in that folder and test (read-only):
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\flow-sync.ps1 -Test
   ```
   You should see `[PASS]` lines. Up to 5 examples of each kind of data are saved in `out\samples\`. Send those files to whoever is setting up the dashboard so the item and voucher names can be matched.
4. Run once:
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\flow-sync.ps1 -Once
   ```
   This writes `parties.json`, `items.json`, `bills.json`, `vouchers.json` and `status.json` into `out\`.
5. Keep it running every 2 minutes:
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\flow-sync.ps1
   ```
   Or let Windows start it automatically at logon (Task Scheduler):
   ```powershell
   schtasks /Create /TN "Flow Tally Sync" /SC ONLOGON /RL LIMITED /TR "powershell -WindowStyle Hidden -ExecutionPolicy Bypass -File C:\FlowSync\flow-sync.ps1"
   ```

## Settings (`flow-sync.config.json`)
| Setting | Default | Meaning |
|---|---|---|
| `tallyUrl` | `http://localhost:9000` | Where Tally's XML server listens |
| `company` | empty | Company name; empty = the one open in Tally |
| `intervalSeconds` | 120 | How often to check for new vouchers |
| `mastersEveryMins` | 10 | How often to re-read parties, items, bills |
| `fromDate` | 2024-04-01 | Oldest voucher date to read |
| `fullResyncHour` | 3 | Hour of the day for the full re-read |
| `supabaseUrl`, `supabaseKey` | empty | Filled in when the online database is set up. Keep the key secret, never put it in GitHub. |

## Files
- `flow-sync.ps1`: the script.
- `flow-sync.config.example.json`: settings template.
- `test/mock-tally.ps1`: a fake Tally used to test the script without real data.
- `out/`: created when it runs (data, log `sync.log`, `status.json`). Not uploaded to GitHub.

## Not covered yet
- Godown-wise stock (only total stock per item). Can be added after seeing the real Tally data.
- Tally Prime's Edit Log (who changed which entry). Needs checking against the real Tally Prime edition and version.
