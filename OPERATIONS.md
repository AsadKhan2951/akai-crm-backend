# AKAI CRM Operations Runbook

This runbook is for AKAI CRM Administrators and the person responsible for production operations. It assumes that the application is running against the intended Supabase project and that the operator is signed in with the required database permission. **RLS is the security boundary; do not bypass it with the service-role key during a user request.**

## Before production use

Keep staging and production Supabase projects separate. Configure environment variables in the hosting dashboard, not in Git or chat. Required values include the database URLs, public Supabase URL/key, and the server-only privileged database key. Configure `NEXT_PUBLIC_APP_URL`, `CRON_SECRET`, provider credentials, and optional Sentry/VAPID/Claude values only where the relevant feature is approved. Run migrations against staging first, complete the staging acceptance checklist, take the approved production backup, and then apply the same migration chain to production.

## Add a user

Open **Admin → Users** and choose **Add user**. Enter the person’s full name, email, phone in Pakistani format, portal, role, manager if applicable, and preferred language. Review the role before saving the pending invite. The current restored application records a pending invite; actual Supabase Auth invite delivery requires the approved Auth provisioning/system-job integration. Never create a shared account or send a password in chat. After the Auth invite integration is enabled, the user must set their own password through the Supabase reset flow.

Verify the new account by signing in as that user in staging. Confirm that the first portal is correct, Urdu switches the full layout to RTL, and the user cannot open another portal or see another agent’s records.

## Create a custom role

Open **Admin → Settings → Roles → Create role**. Give the role a clear name, choose the smallest suitable data scope, select only the permissions required for the job, and review the effective-permission preview. The database privilege boundary prevents an operator from granting a permission they do not already hold. Do not use a broad Administrator role as a shortcut. Assign the role to a staging test user and verify both an allowed action and a denied action before production assignment.

## Reset a password

Use the Supabase Auth password-reset workflow from the configured public application URL. Do not edit password fields directly in the business `users` table and do not ask an operator to disclose a password. If a user is compromised, deactivate the business account first, revoke active sessions through the approved Auth administration process, then issue a reset link. Record the operational action in the audit trail.

## Add a product

Open **Admin → Catalogue → Products → Add product**. Enter the SKU, English and Urdu names, descriptions, independent Category, Brand and optional Collection associations, stock metadata, and image. Product cost is visible only to users with `product.view_cost`. Use the approved image upload route; it validates file bytes, enforces the size/type limit, and strips image metadata. Save the product only after reviewing the preview. Add its selling price through a DRAFT versioned price list, never by editing a historical order price or directly changing the active cache.

## Run a bulk price update

Create or clone a DRAFT price list under **Admin → Catalogue → Price lists**. Filter by Category and Brand, review the current price, new price, change amount, percentage, and margin if permitted, or import the approved CSV template and inspect the preview diff. Apply the change only after a second person reviews the diff. Every money operation remains PostgreSQL numeric and transaction-backed. Do not edit `Product.pricePKR` directly.

## Activate a price list

Confirm the effective date/time in Asia/Karachi, approval state, affected-product count, and announcement draft. If approval is required, use the explicit approval action. Scheduled activation is executed by the protected cron route. After activation, verify the active list, the denormalised product cache, a historical order’s unchanged unit price, and any cart price-change notice. If activation appears wrong, stop further checkout activity and follow the rollback/change-control procedure; never rewrite historical order or quote prices.

## Create a banner

Open **Admin → Catalogue → Promotional banners**. Add English and Urdu copy, approved artwork, CTA, link target, audience, start/end window in Asia/Karachi, and display order. A product/category/brand/collection link must be valid for the target vendor through the same visibility resolver. Preview both locales, then use the explicit **Activate banner** action. The database enforces the maximum active-banner limit. Deactivate rather than deleting evidence when investigating a campaign.

## Restrict a vendor’s catalogue

Open **Admin → Catalogue → Visibility**. Select the Vendor or VendorGroup, choose the independent product, Brand, Category, or Category-by-Brand scope, and review the SQL-backed visible-product count. Apply the smallest rule needed. Test the result using the controlled preview and, in staging, a real restricted vendor: browse, search, direct product URL, cart, quote, banner link, AI search, and PDF must all agree. Never implement a restriction by hiding cards in the browser.

## Record a payment

Open **Admin → Customers**, select the customer, then use the Ledger tab and **Record payment** only if the role has `ledger.record_payment`. Enter the exact Decimal amount, reference, and description. Confirm the customer and amount before saving. Do not use JavaScript float arithmetic or manually edit a derived balance. The transaction and audit entry are authoritative.

## Verify a cash deposit

Open **Admin → Recovery** and select the pending cash deposit. Compare the receipt/collection total, handover details, photo/evidence where present, and the agent’s cash-in-hand total. Use the explicit **Verify deposit** action once. Verification changes the customer balance exactly once through the ledger function; repeat verification must be rejected. A cheque does not change the balance until it is explicitly cleared. A bounced cheque creates a separate reversal and keeps the original linkage.

## Approve an order

Open **Admin → Approvals**, review the vendor, customer, visible line items, immutable unit prices, total, selected payment method, credit status, and stock/approval warnings. Use **Approve order** or **Reject order** with an actionable reason. Never approve an order based only on a notification preview. Historical order-line prices must not change after a price-list activation.

## Price a quote

Open **Sales → Quotes** or the permitted Admin quote queue. Load the requested visible products, enter quoted prices and validity in one transaction, review the margin only if authorized, and use **Publish quote**. The Vendor must explicitly accept; acceptance creates or links the Order through the transactional workflow. A price-list change must not silently change an open quote before its validity date.

## Check failed messages

Open **Admin → Communications → Failed messages**. Review channel, recipient, provider error, attempts, and last-attempt time. Confirm unsubscribe and approved-template requirements before retrying. Use **Retry message** only after correcting the cause. A user action must never wait for external delivery. If the provider is unavailable, the CRM workflow remains usable and the MessageLog remains visible.

## If the WhatsApp webhook stops receiving

First check the Admin Communications failed/inbound view and the hosting logs without exposing message content. Confirm the production callback URL is still the configured HTTPS URL, the Meta verify token and app secret are present in hosting settings, and the webhook subscription is active in Meta. Send a controlled staging test and confirm signature verification, inbound MessageLog creation, duplicate-event rejection, and delivery/read status updates. Check that the cron/worker is healthy and that the database deduplication ledger is not blocked. Do not disable signature verification and do not replay unsigned payloads. If Meta is degraded, record the incident, keep outbound messages queued, and use the approved manual contact process.

## Rollback and incident handling

Do not edit an applied migration. Stop the deployment, preserve logs and audit records, and revert the application to the last known-good deployment through the hosting provider. Database rollback must follow an approved backup/change plan; use a new corrective migration rather than rewriting history. For money, stock, access, or security incidents, restrict further writes, record the incident owner and time in Asia/Karachi, and validate the resulting ledger/audit state before reopening the workflow.

## Daily checks

The operations owner should verify uptime, failed cron jobs, failed messages, pending deposits, unusual access-risk alerts, backup completion, and Sentry errors. Daily backup verification means checking that the provider reports a successful backup and periodically completing a restore drill in an isolated project. Never restore production data into staging without an approved data-handling plan.

## Current handover limitations

The restored workspace still lacks Git metadata and three historically committed artifacts: migration `0006_versioned_price_lists`, migration `0009_vendor_portal_workflows`, and `app/api/vendor/catalogue-pdf/route.ts`. Hosted Supabase Auth/RLS/Storage UAT, real provider delivery, custom domain, backup restore drill, and production seed remain deployment prerequisites. These are not silently treated as complete by this runbook.
