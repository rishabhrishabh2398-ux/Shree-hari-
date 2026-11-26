# Flow Dashboard

Order, challan, stock and dues dashboard for a sanitaryware / CP fittings / geyser / building-products dealer that runs on Tally Prime.

**Status:** sample data only. Nothing is read from or written to Tally or WhatsApp yet.

## What's in it
- **Orders**: manual orders and orders read from WhatsApp messages, then New → On hold (credit) → Partly done → Awaiting invoice → Completed.
- **WhatsApp**: paste messages or upload a chat export (.txt). Parties and items are matched against Tally's lists.
- **Challans**: make a delivery challan from an order, print it, share it on WhatsApp, mark dispatched.
- **Purchase**: suggested POs per company (customer orders waiting + reorder level), with pending POs highlighted.
- **Stock / Parties / Accounts**: read-only views of Tally data.
- **Approvals**: anything that would change Tally waits for the owner.
- **Users & rules**: Owner, Office, Godown, Salesman permissions.

## Rules
1. Tally is the master for customers, items, stock, invoices and dues. They are only read.
2. Nothing is written to Tally without the owner's approval, and never without a backup first.
3. Stock only changes through Tally entries.

## Deploy
Static site: `index.html` at the root. Vercel: import this repo, Framework preset "Other", no build command.
