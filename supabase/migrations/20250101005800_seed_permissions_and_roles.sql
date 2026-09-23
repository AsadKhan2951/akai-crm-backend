-- AKAI CRM permission catalogue and preset roles (system seed, idempotent).
-- Converted from prisma/seed.ts into SQL so `supabase db push` installs it without Prisma.
-- Runs without a JWT, so the role/permission guard triggers treat it as a system change.
-- No customers, products or other business records are created.

insert into public.permissions (id, key, module, label_en, label_ur, description, is_sensitive, display_order) values
  ('product_view', 'product.view', 'CATALOGUE', 'View', 'اجازت: product.view', 'Permission for product.view.', false, 0),
  ('product_create', 'product.create', 'CATALOGUE', 'Create', 'اجازت: product.create', 'Permission for product.create.', false, 1),
  ('product_update', 'product.update', 'CATALOGUE', 'Update', 'اجازت: product.update', 'Permission for product.update.', false, 2),
  ('product_delete', 'product.delete', 'CATALOGUE', 'Delete', 'اجازت: product.delete', 'Permission for product.delete.', false, 3),
  ('product_bulk_import', 'product.bulk_import', 'CATALOGUE', 'Bulk Import', 'اجازت: product.bulk_import', 'Permission for product.bulk_import.', false, 4),
  ('product_view_cost', 'product.view_cost', 'CATALOGUE', 'View Cost', 'اجازت: product.view_cost', 'Permission for product.view_cost.', true, 5),
  ('product_manage_images', 'product.manage_images', 'CATALOGUE', 'Manage Images', 'اجازت: product.manage_images', 'Permission for product.manage_images.', false, 6),
  ('category_view', 'category.view', 'CATALOGUE', 'View', 'اجازت: category.view', 'Permission for category.view.', false, 7),
  ('category_create', 'category.create', 'CATALOGUE', 'Create', 'اجازت: category.create', 'Permission for category.create.', false, 8),
  ('category_update', 'category.update', 'CATALOGUE', 'Update', 'اجازت: category.update', 'Permission for category.update.', false, 9),
  ('category_delete', 'category.delete', 'CATALOGUE', 'Delete', 'اجازت: category.delete', 'Permission for category.delete.', false, 10),
  ('brand_view', 'brand.view', 'CATALOGUE', 'View', 'اجازت: brand.view', 'Permission for brand.view.', false, 11),
  ('brand_create', 'brand.create', 'CATALOGUE', 'Create', 'اجازت: brand.create', 'Permission for brand.create.', false, 12),
  ('brand_update', 'brand.update', 'CATALOGUE', 'Update', 'اجازت: brand.update', 'Permission for brand.update.', false, 13),
  ('brand_delete', 'brand.delete', 'CATALOGUE', 'Delete', 'اجازت: brand.delete', 'Permission for brand.delete.', false, 14),
  ('collection_view', 'collection.view', 'CATALOGUE', 'View', 'اجازت: collection.view', 'Permission for collection.view.', false, 15),
  ('collection_manage', 'collection.manage', 'CATALOGUE', 'Manage', 'اجازت: collection.manage', 'Permission for collection.manage.', false, 16),
  ('pricelist_view', 'pricelist.view', 'CATALOGUE', 'View', 'اجازت: pricelist.view', 'Permission for pricelist.view.', false, 17),
  ('pricelist_create', 'pricelist.create', 'CATALOGUE', 'Create', 'اجازت: pricelist.create', 'Permission for pricelist.create.', false, 18),
  ('pricelist_activate', 'pricelist.activate', 'CATALOGUE', 'Activate', 'اجازت: pricelist.activate', 'Permission for pricelist.activate.', true, 19),
  ('customer_view', 'customer.view', 'CUSTOMERS', 'View', 'اجازت: customer.view', 'Permission for customer.view.', false, 100),
  ('customer_create', 'customer.create', 'CUSTOMERS', 'Create', 'اجازت: customer.create', 'Permission for customer.create.', false, 101),
  ('customer_update', 'customer.update', 'CUSTOMERS', 'Update', 'اجازت: customer.update', 'Permission for customer.update.', false, 102),
  ('customer_delete', 'customer.delete', 'CUSTOMERS', 'Delete', 'اجازت: customer.delete', 'Permission for customer.delete.', false, 103),
  ('customer_reassign_agent', 'customer.reassign_agent', 'CUSTOMERS', 'Reassign Agent', 'اجازت: customer.reassign_agent', 'Permission for customer.reassign_agent.', false, 104),
  ('customer_export', 'customer.export', 'CUSTOMERS', 'Export', 'اجازت: customer.export', 'Permission for customer.export.', true, 105),
  ('customer_enrich', 'customer.enrich', 'CUSTOMERS', 'Enrich', 'اجازت: customer.enrich', 'Permission for customer.enrich.', false, 106),
  ('vendorgroup_manage', 'vendorgroup.manage', 'CUSTOMERS', 'Manage', 'اجازت: vendorgroup.manage', 'Permission for vendorgroup.manage.', false, 107),
  ('catalogvisibility_manage', 'catalogvisibility.manage', 'CUSTOMERS', 'Manage', 'اجازت: catalogvisibility.manage', 'Permission for catalogvisibility.manage.', false, 108),
  ('vendoraccount_create', 'vendoraccount.create', 'CUSTOMERS', 'Create', 'اجازت: vendoraccount.create', 'Permission for vendoraccount.create.', false, 109),
  ('vendoraccount_deactivate', 'vendoraccount.deactivate', 'CUSTOMERS', 'Deactivate', 'اجازت: vendoraccount.deactivate', 'Permission for vendoraccount.deactivate.', false, 110),
  ('lead_view', 'lead.view', 'PIPELINE', 'View', 'اجازت: lead.view', 'Permission for lead.view.', false, 200),
  ('lead_create', 'lead.create', 'PIPELINE', 'Create', 'اجازت: lead.create', 'Permission for lead.create.', false, 201),
  ('lead_update', 'lead.update', 'PIPELINE', 'Update', 'اجازت: lead.update', 'Permission for lead.update.', false, 202),
  ('lead_delete', 'lead.delete', 'PIPELINE', 'Delete', 'اجازت: lead.delete', 'Permission for lead.delete.', false, 203),
  ('lead_import', 'lead.import', 'PIPELINE', 'Import', 'اجازت: lead.import', 'Permission for lead.import.', false, 204),
  ('lead_reassign', 'lead.reassign', 'PIPELINE', 'Reassign', 'اجازت: lead.reassign', 'Permission for lead.reassign.', false, 205),
  ('activity_view', 'activity.view', 'PIPELINE', 'View', 'اجازت: activity.view', 'Permission for activity.view.', false, 206),
  ('activity_create', 'activity.create', 'PIPELINE', 'Create', 'اجازت: activity.create', 'Permission for activity.create.', false, 207),
  ('activity_delete', 'activity.delete', 'PIPELINE', 'Delete', 'اجازت: activity.delete', 'Permission for activity.delete.', false, 208),
  ('followup_view', 'followup.view', 'PIPELINE', 'View', 'اجازت: followup.view', 'Permission for followup.view.', false, 209),
  ('followup_manage', 'followup.manage', 'PIPELINE', 'Manage', 'اجازت: followup.manage', 'Permission for followup.manage.', false, 210),
  ('beat_view', 'beat.view', 'PIPELINE', 'View', 'اجازت: beat.view', 'Permission for beat.view.', false, 211),
  ('beat_manage', 'beat.manage', 'PIPELINE', 'Manage', 'اجازت: beat.manage', 'Permission for beat.manage.', false, 212),
  ('beat_visit', 'beat.visit', 'PIPELINE', 'Visit', 'اجازت: beat.visit', 'Permission for beat.visit.', false, 213),
  ('order_view', 'order.view', 'ORDERS AND QUOTES', 'View', 'اجازت: order.view', 'Permission for order.view.', false, 300),
  ('order_create', 'order.create', 'ORDERS AND QUOTES', 'Create', 'اجازت: order.create', 'Permission for order.create.', false, 301),
  ('order_update_status', 'order.update_status', 'ORDERS AND QUOTES', 'Update Status', 'اجازت: order.update_status', 'Permission for order.update_status.', false, 302),
  ('order_approve', 'order.approve', 'ORDERS AND QUOTES', 'Approve', 'اجازت: order.approve', 'Permission for order.approve.', false, 303),
  ('order_cancel', 'order.cancel', 'ORDERS AND QUOTES', 'Cancel', 'اجازت: order.cancel', 'Permission for order.cancel.', false, 304),
  ('order_export', 'order.export', 'ORDERS AND QUOTES', 'Export', 'اجازت: order.export', 'Permission for order.export.', false, 305),
  ('quote_view', 'quote.view', 'ORDERS AND QUOTES', 'View', 'اجازت: quote.view', 'Permission for quote.view.', false, 306),
  ('quote_create', 'quote.create', 'ORDERS AND QUOTES', 'Create', 'اجازت: quote.create', 'Permission for quote.create.', false, 307),
  ('quote_price', 'quote.price', 'ORDERS AND QUOTES', 'Price', 'اجازت: quote.price', 'Permission for quote.price.', false, 308),
  ('quote_cancel', 'quote.cancel', 'ORDERS AND QUOTES', 'Cancel', 'اجازت: quote.cancel', 'Permission for quote.cancel.', false, 309),
  ('ledger_view', 'ledger.view', 'FINANCE', 'View', 'اجازت: ledger.view', 'Permission for ledger.view.', false, 400),
  ('ledger_record_payment', 'ledger.record_payment', 'FINANCE', 'Record Payment', 'اجازت: ledger.record_payment', 'Permission for ledger.record_payment.', false, 401),
  ('ledger_adjust', 'ledger.adjust', 'FINANCE', 'Adjust', 'اجازت: ledger.adjust', 'Permission for ledger.adjust.', true, 402),
  ('collection_record', 'collection.record', 'FINANCE', 'Record', 'اجازت: collection.record', 'Permission for collection.record.', false, 403),
  ('collection_deposit', 'collection.deposit', 'FINANCE', 'Deposit', 'اجازت: collection.deposit', 'Permission for collection.deposit.', false, 404),
  ('collection_verify_deposit', 'collection.verify_deposit', 'FINANCE', 'Verify Deposit', 'اجازت: collection.verify_deposit', 'Permission for collection.verify_deposit.', false, 405),
  ('collection_cancel', 'collection.cancel', 'FINANCE', 'Cancel', 'اجازت: collection.cancel', 'Permission for collection.cancel.', true, 406),
  ('collection_reminder', 'collection.reminder', 'FINANCE', 'Reminder', 'اجازت: collection.reminder', 'Permission for collection.reminder.', false, 407),
  ('recoverytarget_manage', 'recoverytarget.manage', 'FINANCE', 'Manage', 'اجازت: recoverytarget.manage', 'Permission for recoverytarget.manage.', false, 408),
  ('creditlimit_manage', 'creditlimit.manage', 'FINANCE', 'Manage', 'اجازت: creditlimit.manage', 'Permission for creditlimit.manage.', false, 409),
  ('financials_view_revenue', 'financials.view_revenue', 'FINANCE', 'View Revenue', 'اجازت: financials.view_revenue', 'Permission for financials.view_revenue.', false, 410),
  ('financials_view_margin', 'financials.view_margin', 'FINANCE', 'View Margin', 'اجازت: financials.view_margin', 'Permission for financials.view_margin.', true, 411),
  ('banner_view', 'banner.view', 'PROMOTIONS AND LOYALTY', 'View', 'اجازت: banner.view', 'Permission for banner.view.', false, 500),
  ('banner_manage', 'banner.manage', 'PROMOTIONS AND LOYALTY', 'Manage', 'اجازت: banner.manage', 'Permission for banner.manage.', false, 501),
  ('scheme_view', 'scheme.view', 'PROMOTIONS AND LOYALTY', 'View', 'اجازت: scheme.view', 'Permission for scheme.view.', false, 502),
  ('scheme_create', 'scheme.create', 'PROMOTIONS AND LOYALTY', 'Create', 'اجازت: scheme.create', 'Permission for scheme.create.', false, 503),
  ('scheme_activate', 'scheme.activate', 'PROMOTIONS AND LOYALTY', 'Activate', 'اجازت: scheme.activate', 'Permission for scheme.activate.', false, 504),
  ('scheme_analytics', 'scheme.analytics', 'PROMOTIONS AND LOYALTY', 'Analytics', 'اجازت: scheme.analytics', 'Permission for scheme.analytics.', false, 505),
  ('reward_manage', 'reward.manage', 'PROMOTIONS AND LOYALTY', 'Manage', 'اجازت: reward.manage', 'Permission for reward.manage.', false, 506),
  ('loyalty_view', 'loyalty.view', 'PROMOTIONS AND LOYALTY', 'View', 'اجازت: loyalty.view', 'Permission for loyalty.view.', false, 507),
  ('redemption_request', 'redemption.request', 'PROMOTIONS AND LOYALTY', 'Request', 'اجازت: redemption.request', 'Permission for redemption.request.', false, 508),
  ('redemption_approve', 'redemption.approve', 'PROMOTIONS AND LOYALTY', 'Approve', 'اجازت: redemption.approve', 'Permission for redemption.approve.', false, 509),
  ('loyalty_adjust', 'loyalty.adjust', 'PROMOTIONS AND LOYALTY', 'Adjust', 'اجازت: loyalty.adjust', 'Permission for loyalty.adjust.', true, 510),
  ('delivery_view', 'delivery.view', 'DELIVERY', 'View', 'اجازت: delivery.view', 'Permission for delivery.view.', false, 600),
  ('delivery_create_run', 'delivery.create_run', 'DELIVERY', 'Create Run', 'اجازت: delivery.create_run', 'Permission for delivery.create_run.', false, 601),
  ('delivery_mark_delivered', 'delivery.mark_delivered', 'DELIVERY', 'Mark Delivered', 'اجازت: delivery.mark_delivered', 'Permission for delivery.mark_delivered.', false, 602),
  ('delivery_reconcile', 'delivery.reconcile', 'DELIVERY', 'Reconcile', 'اجازت: delivery.reconcile', 'Permission for delivery.reconcile.', false, 603),
  ('claim_view', 'claim.view', 'CLAIMS', 'View', 'اجازت: claim.view', 'Permission for claim.view.', false, 700),
  ('claim_create', 'claim.create', 'CLAIMS', 'Create', 'اجازت: claim.create', 'Permission for claim.create.', false, 701),
  ('claim_review', 'claim.review', 'CLAIMS', 'Review', 'اجازت: claim.review', 'Permission for claim.review.', false, 702),
  ('claim_approve', 'claim.approve', 'CLAIMS', 'Approve', 'اجازت: claim.approve', 'Permission for claim.approve.', false, 703),
  ('warranty_manage', 'warranty.manage', 'CLAIMS', 'Manage', 'اجازت: warranty.manage', 'Permission for warranty.manage.', false, 704),
  ('dashboard_view', 'dashboard.view', 'REPORTING', 'View', 'اجازت: dashboard.view', 'Permission for dashboard.view.', false, 800),
  ('report_build', 'report.build', 'REPORTING', 'Build', 'اجازت: report.build', 'Permission for report.build.', false, 801),
  ('report_schedule', 'report.schedule', 'REPORTING', 'Schedule', 'اجازت: report.schedule', 'Permission for report.schedule.', false, 802),
  ('report_export', 'report.export', 'REPORTING', 'Export', 'اجازت: report.export', 'Permission for report.export.', false, 803),
  ('message_send', 'message.send', 'COMMUNICATIONS', 'Send', 'اجازت: message.send', 'Permission for message.send.', false, 900),
  ('message_campaign', 'message.campaign', 'COMMUNICATIONS', 'Campaign', 'اجازت: message.campaign', 'Permission for message.campaign.', false, 901),
  ('whatsapp_manage_templates', 'whatsapp.manage_templates', 'COMMUNICATIONS', 'Manage Templates', 'اجازت: whatsapp.manage_templates', 'Permission for whatsapp.manage_templates.', false, 902),
  ('whatsapp_kill_switch', 'whatsapp.kill_switch', 'COMMUNICATIONS', 'Kill Switch', 'اجازت: whatsapp.kill_switch', 'Permission for whatsapp.kill_switch.', true, 903),
  ('notification_view', 'notification.view', 'COMMUNICATIONS', 'View', 'اجازت: notification.view', 'Permission for notification.view.', false, 904),
  ('ai_chat', 'ai.chat', 'AI', 'Chat', 'اجازت: ai.chat', 'Permission for ai.chat.', false, 1000),
  ('ai_analytics', 'ai.analytics', 'AI', 'Analytics', 'اجازت: ai.analytics', 'Permission for ai.analytics.', false, 1001),
  ('ai_generate_content', 'ai.generate_content', 'AI', 'Generate Content', 'اجازت: ai.generate_content', 'Permission for ai.generate_content.', false, 1002),
  ('ai_manage_budget', 'ai.manage_budget', 'AI', 'Manage Budget', 'اجازت: ai.manage_budget', 'Permission for ai.manage_budget.', false, 1003),
  ('voice_capture', 'voice.capture', 'VOICE', 'Capture', 'اجازت: voice.capture', 'Permission for voice.capture.', false, 1100),
  ('voice_view', 'voice.view', 'VOICE', 'View', 'اجازت: voice.view', 'Permission for voice.view.', false, 1101),
  ('pwa_sync', 'pwa.sync', 'PWA', 'Sync', 'اجازت: pwa.sync', 'Permission for pwa.sync.', false, 1200),
  ('user_view', 'user.view', 'SYSTEM', 'View', 'اجازت: user.view', 'Permission for user.view.', false, 1300),
  ('user_create', 'user.create', 'SYSTEM', 'Create', 'اجازت: user.create', 'Permission for user.create.', true, 1301),
  ('user_update', 'user.update', 'SYSTEM', 'Update', 'اجازت: user.update', 'Permission for user.update.', false, 1302),
  ('user_deactivate', 'user.deactivate', 'SYSTEM', 'Deactivate', 'اجازت: user.deactivate', 'Permission for user.deactivate.', false, 1303),
  ('role_view', 'role.view', 'SYSTEM', 'View', 'اجازت: role.view', 'Permission for role.view.', false, 1304),
  ('role_create', 'role.create', 'SYSTEM', 'Create', 'اجازت: role.create', 'Permission for role.create.', true, 1305),
  ('role_update', 'role.update', 'SYSTEM', 'Update', 'اجازت: role.update', 'Permission for role.update.', true, 1306),
  ('role_delete', 'role.delete', 'SYSTEM', 'Delete', 'اجازت: role.delete', 'Permission for role.delete.', false, 1307),
  ('settings_manage', 'settings.manage', 'SYSTEM', 'Manage', 'اجازت: settings.manage', 'Permission for settings.manage.', true, 1308),
  ('auditlog_view', 'auditlog.view', 'SYSTEM', 'View', 'اجازت: auditlog.view', 'Permission for auditlog.view.', false, 1309),
  ('integration_manage', 'integration.manage', 'SYSTEM', 'Manage', 'اجازت: integration.manage', 'Permission for integration.manage.', false, 1310),
  ('impersonate_vendor', 'impersonate.vendor', 'SYSTEM', 'Vendor', 'اجازت: impersonate.vendor', 'Permission for impersonate.vendor.', true, 1311)
on conflict (key) do update set module = excluded.module, is_sensitive = excluded.is_sensitive, display_order = excluded.display_order,
  label_en = case when public.permissions.label_en = '' then excluded.label_en else public.permissions.label_en end,
  label_ur = case when public.permissions.label_ur = '' then excluded.label_ur else public.permissions.label_ur end;

insert into public.permission_dependencies (permission_id, requires_permission_id)
select a.id, b.id from (values
  ('product.create', 'product.view'),
  ('product.update', 'product.view'),
  ('product.delete', 'product.view'),
  ('product.bulk_import', 'product.view'),
  ('product.manage_images', 'product.view'),
  ('category.create', 'category.view'),
  ('category.update', 'category.view'),
  ('category.delete', 'category.view'),
  ('brand.create', 'brand.view'),
  ('brand.update', 'brand.view'),
  ('brand.delete', 'brand.view'),
  ('customer.create', 'customer.view'),
  ('customer.update', 'customer.view'),
  ('customer.delete', 'customer.view'),
  ('customer.reassign_agent', 'customer.view'),
  ('customer.export', 'customer.view'),
  ('customer.enrich', 'customer.view'),
  ('lead.create', 'lead.view'),
  ('lead.update', 'lead.view'),
  ('lead.delete', 'lead.view'),
  ('lead.import', 'lead.view'),
  ('lead.reassign', 'lead.view'),
  ('activity.create', 'activity.view'),
  ('activity.delete', 'activity.view'),
  ('followup.manage', 'followup.view'),
  ('beat.manage', 'beat.view'),
  ('beat.visit', 'beat.view'),
  ('beat.visit', 'activity.create'),
  ('order.update_status', 'order.view'),
  ('order.approve', 'order.view'),
  ('order.cancel', 'order.view'),
  ('order.export', 'order.view'),
  ('quote.price', 'quote.view'),
  ('quote.cancel', 'quote.view'),
  ('ledger.record_payment', 'ledger.view'),
  ('ledger.adjust', 'ledger.view'),
  ('collection.record', 'collection.view'),
  ('collection.deposit', 'collection.view'),
  ('collection.deposit', 'collection.record'),
  ('collection.verify_deposit', 'collection.view'),
  ('collection.cancel', 'collection.view'),
  ('collection.reminder', 'collection.view'),
  ('collection.reminder', 'message.send'),
  ('recoverytarget.manage', 'collection.view'),
  ('scheme.create', 'scheme.view'),
  ('scheme.activate', 'scheme.view'),
  ('scheme.analytics', 'scheme.view'),
  ('redemption.request', 'loyalty.view'),
  ('claim.review', 'claim.view'),
  ('claim.approve', 'claim.view'),
  ('role.create', 'role.view'),
  ('role.create', 'user.view'),
  ('role.update', 'role.view'),
  ('role.update', 'user.view'),
  ('role.delete', 'role.view'),
  ('role.delete', 'user.view'),
  ('user.create', 'user.view'),
  ('user.update', 'user.view'),
  ('user.deactivate', 'user.view'),
  ('financials.view_margin', 'product.view_cost')
) as d(permission_key, requires_key)
join public.permissions a on a.key = d.permission_key
join public.permissions b on b.key = d.requires_key
on conflict do nothing;

insert into public.roles (name, description, data_scope, portal_access, is_system_role, is_active)
values ('Administrator', 'Full administrative access across the AKAI CRM.', 'GLOBAL', 'ADMIN', true, true)
on conflict (name) do update set description = excluded.description, data_scope = excluded.data_scope,
  portal_access = excluded.portal_access, is_system_role = excluded.is_system_role, is_active = true;
insert into public.role_permissions (role_id, permission_id)
select r.id, p.id from public.roles r join public.permissions p on p.key = any (array['activity.create', 'activity.delete', 'activity.view', 'ai.analytics', 'ai.chat', 'ai.generate_content', 'ai.manage_budget', 'auditlog.view', 'banner.manage', 'banner.view', 'beat.manage', 'beat.view', 'beat.visit', 'brand.create', 'brand.delete', 'brand.update', 'brand.view', 'catalogvisibility.manage', 'category.create', 'category.delete', 'category.update', 'category.view', 'claim.approve', 'claim.create', 'claim.review', 'claim.view', 'collection.cancel', 'collection.deposit', 'collection.manage', 'collection.record', 'collection.reminder', 'collection.verify_deposit', 'collection.view', 'creditlimit.manage', 'customer.create', 'customer.delete', 'customer.enrich', 'customer.export', 'customer.reassign_agent', 'customer.update', 'customer.view', 'dashboard.view', 'delivery.create_run', 'delivery.mark_delivered', 'delivery.reconcile', 'delivery.view', 'financials.view_margin', 'financials.view_revenue', 'followup.manage', 'followup.view', 'impersonate.vendor', 'integration.manage', 'lead.create', 'lead.delete', 'lead.import', 'lead.reassign', 'lead.update', 'lead.view', 'ledger.adjust', 'ledger.record_payment', 'ledger.view', 'loyalty.adjust', 'loyalty.view', 'message.campaign', 'message.send', 'notification.view', 'order.approve', 'order.cancel', 'order.create', 'order.export', 'order.update_status', 'order.view', 'pricelist.activate', 'pricelist.create', 'pricelist.view', 'product.bulk_import', 'product.create', 'product.delete', 'product.manage_images', 'product.update', 'product.view', 'product.view_cost', 'pwa.sync', 'quote.cancel', 'quote.create', 'quote.price', 'quote.view', 'recoverytarget.manage', 'redemption.approve', 'redemption.request', 'report.build', 'report.export', 'report.schedule', 'reward.manage', 'role.create', 'role.delete', 'role.update', 'role.view', 'scheme.activate', 'scheme.analytics', 'scheme.create', 'scheme.view', 'settings.manage', 'user.create', 'user.deactivate', 'user.update', 'user.view', 'vendoraccount.create', 'vendoraccount.deactivate', 'vendorgroup.manage', 'voice.capture', 'voice.view', 'warranty.manage', 'whatsapp.kill_switch', 'whatsapp.manage_templates'])
where r.name = 'Administrator'
on conflict do nothing;

insert into public.roles (name, description, data_scope, portal_access, is_system_role, is_active)
values ('Sales Agent', 'Own assigned customers and field-sales work without cost, margin, approvals, or settings.', 'OWN', 'SALES', true, true)
on conflict (name) do update set description = excluded.description, data_scope = excluded.data_scope,
  portal_access = excluded.portal_access, is_system_role = excluded.is_system_role, is_active = true;
insert into public.role_permissions (role_id, permission_id)
select r.id, p.id from public.roles r join public.permissions p on p.key = any (array['activity.create', 'activity.view', 'ai.chat', 'beat.view', 'beat.visit', 'brand.view', 'category.view', 'claim.create', 'collection.deposit', 'collection.record', 'collection.view', 'customer.create', 'customer.enrich', 'customer.update', 'customer.view', 'dashboard.view', 'delivery.view', 'financials.view_revenue', 'followup.manage', 'followup.view', 'lead.create', 'lead.import', 'lead.update', 'lead.view', 'notification.view', 'order.create', 'order.view', 'pricelist.view', 'product.view', 'pwa.sync', 'quote.create', 'quote.view', 'scheme.view', 'voice.capture', 'voice.view'])
where r.name = 'Sales Agent'
on conflict do nothing;

insert into public.roles (name, description, data_scope, portal_access, is_system_role, is_active)
values ('Vendor', 'Self-scoped dealer access to visible catalogue, orders, quotes, claims, ledger, and loyalty views.', 'SELF', 'VENDOR', true, true)
on conflict (name) do update set description = excluded.description, data_scope = excluded.data_scope,
  portal_access = excluded.portal_access, is_system_role = excluded.is_system_role, is_active = true;
insert into public.role_permissions (role_id, permission_id)
select r.id, p.id from public.roles r join public.permissions p on p.key = any (array['ai.chat', 'brand.view', 'category.view', 'claim.create', 'claim.view', 'collection.view', 'delivery.view', 'ledger.view', 'loyalty.view', 'notification.view', 'order.create', 'order.view', 'pricelist.view', 'product.view', 'pwa.sync', 'quote.create', 'quote.view', 'redemption.request', 'scheme.view'])
where r.name = 'Vendor'
on conflict do nothing;

insert into public.roles (name, description, data_scope, portal_access, is_system_role, is_active)
values ('Catalogue Manager', 'Global catalogue management without cost visibility or unrelated access.', 'GLOBAL', 'ADMIN', false, true)
on conflict (name) do update set description = excluded.description, data_scope = excluded.data_scope,
  portal_access = excluded.portal_access, is_system_role = excluded.is_system_role, is_active = true;
insert into public.role_permissions (role_id, permission_id)
select r.id, p.id from public.roles r join public.permissions p on p.key = any (array['ai.generate_content', 'brand.create', 'brand.delete', 'brand.update', 'brand.view', 'category.create', 'category.delete', 'category.update', 'category.view', 'collection.manage', 'collection.view', 'dashboard.view', 'notification.view', 'product.bulk_import', 'product.create', 'product.delete', 'product.manage_images', 'product.update', 'product.view'])
where r.name = 'Catalogue Manager'
on conflict do nothing;

insert into public.roles (name, description, data_scope, portal_access, is_system_role, is_active)
values ('Sales Manager', 'Team-scoped sales management with approvals, reassignment, and reporting.', 'TEAM', 'SALES', false, true)
on conflict (name) do update set description = excluded.description, data_scope = excluded.data_scope,
  portal_access = excluded.portal_access, is_system_role = excluded.is_system_role, is_active = true;
insert into public.role_permissions (role_id, permission_id)
select r.id, p.id from public.roles r join public.permissions p on p.key = any (array['activity.create', 'activity.view', 'ai.chat', 'beat.manage', 'beat.view', 'beat.visit', 'brand.view', 'category.view', 'claim.create', 'collection.deposit', 'collection.record', 'collection.verify_deposit', 'collection.view', 'customer.reassign_agent', 'customer.update', 'customer.view', 'dashboard.view', 'delivery.view', 'financials.view_revenue', 'followup.manage', 'followup.view', 'lead.create', 'lead.reassign', 'lead.update', 'lead.view', 'notification.view', 'order.approve', 'order.create', 'order.view', 'pricelist.view', 'product.view', 'pwa.sync', 'quote.create', 'quote.price', 'quote.view', 'report.build', 'scheme.view', 'voice.capture', 'voice.view'])
where r.name = 'Sales Manager'
on conflict do nothing;

insert into public.roles (name, description, data_scope, portal_access, is_system_role, is_active)
values ('Accounts / Recovery Officer', 'Global accounts and recovery operations with revenue visibility but no margin access.', 'GLOBAL', 'ADMIN', false, true)
on conflict (name) do update set description = excluded.description, data_scope = excluded.data_scope,
  portal_access = excluded.portal_access, is_system_role = excluded.is_system_role, is_active = true;
insert into public.role_permissions (role_id, permission_id)
select r.id, p.id from public.roles r join public.permissions p on p.key = any (array['collection.cancel', 'collection.deposit', 'collection.record', 'collection.reminder', 'collection.verify_deposit', 'collection.view', 'creditlimit.manage', 'customer.view', 'dashboard.view', 'financials.view_revenue', 'ledger.adjust', 'ledger.record_payment', 'ledger.view', 'message.send', 'notification.view', 'order.view', 'recoverytarget.manage', 'report.build', 'report.export'])
where r.name = 'Accounts / Recovery Officer'
on conflict do nothing;

insert into public.roles (name, description, data_scope, portal_access, is_system_role, is_active)
values ('Support Agent', 'Global support access to customers, orders, quotes, claims, activities, and messages.', 'GLOBAL', 'ADMIN', false, true)
on conflict (name) do update set description = excluded.description, data_scope = excluded.data_scope,
  portal_access = excluded.portal_access, is_system_role = excluded.is_system_role, is_active = true;
insert into public.role_permissions (role_id, permission_id)
select r.id, p.id from public.roles r join public.permissions p on p.key = any (array['activity.create', 'activity.view', 'ai.chat', 'claim.create', 'claim.view', 'customer.view', 'message.send', 'notification.view', 'order.view', 'quote.view', 'voice.capture', 'voice.view'])
where r.name = 'Support Agent'
on conflict do nothing;

insert into public.roles (name, description, data_scope, portal_access, is_system_role, is_active)
values ('Analyst', 'Read-only global reporting access.', 'GLOBAL', 'ADMIN', false, true)
on conflict (name) do update set description = excluded.description, data_scope = excluded.data_scope,
  portal_access = excluded.portal_access, is_system_role = excluded.is_system_role, is_active = true;
insert into public.role_permissions (role_id, permission_id)
select r.id, p.id from public.roles r join public.permissions p on p.key = any (array['ai.analytics', 'dashboard.view', 'financials.view_revenue', 'notification.view', 'report.build', 'report.export'])
where r.name = 'Analyst'
on conflict do nothing;

-- The Administrator role always holds every permission, including ones added by earlier migrations.
insert into public.role_permissions (role_id, permission_id)
select r.id, p.id from public.roles r cross join public.permissions p where r.name = 'Administrator'
on conflict do nothing;

-- First-admin bootstrap. Links an existing Supabase Auth user (created in the dashboard) to the
-- Administrator role. Only callable from the SQL editor / service role, and only while no active
-- Administrator user exists, so it cannot be used to escalate privileges later.
create or replace function public.bootstrap_first_admin(p_email text, p_full_name text default 'AKAI Administrator')
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  auth_user_id uuid;
  admin_role_id text;
begin
  select id into admin_role_id from public.roles where name = 'Administrator';
  if admin_role_id is null then raise exception 'Run the permission seed first: the Administrator role is missing.'; end if;
  if exists (select 1 from public.users where role_id = admin_role_id and is_active) then
    raise exception 'An active Administrator already exists. Create further users from the Admin portal.';
  end if;
  select id into auth_user_id from auth.users where lower(email) = lower(trim(p_email));
  if auth_user_id is null then
    raise exception 'No Supabase Auth user has the email %. Create it in Authentication > Users first.', p_email;
  end if;
  insert into public.users (id, email, full_name, role_id, is_active, preferred_locale)
  values (auth_user_id, lower(trim(p_email)), p_full_name, admin_role_id, true, 'en')
  on conflict (id) do update set role_id = excluded.role_id, is_active = true, full_name = excluded.full_name;
  return auth_user_id;
end;
$$;
revoke all on function public.bootstrap_first_admin(text, text) from public, anon, authenticated;
