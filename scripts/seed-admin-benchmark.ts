import { PrismaClient } from "@prisma/client";

const prisma = new PrismaClient();

async function main() {
  if (process.env.AKAI_BENCHMARK_SEED !== "1") throw new Error("Refusing to seed benchmark data. Set AKAI_BENCHMARK_SEED=1 explicitly.");
  await prisma.$transaction(async (tx) => {
    await tx.$executeRawUnsafe(`
      insert into public.customers (id, name, business_name, area_code, normalized_name, import_key, customer_type, credit_limit_pkr, current_balance_pkr, status, is_internal_account, data_complete)
      select gen_random_uuid(), 'BENCHMARK INTERNAL', 'BENCHMARK INTERNAL — NOT REAL', coalesce((select code from public.area_codes order by code limit 1), 'BENCHMARK'), 'BENCHMARK_ADMIN_50K', 'OTHER', 0::numeric(12,2), 0::numeric(12,2), 'INACTIVE', true, true
      where not exists (select 1 from public.customers where import_key='BENCHMARK_ADMIN_50K');
      insert into public.orders (id, order_number, customer_id, placed_by_user_id, placed_via, payment_method, status, approval_required, subtotal_pkr, discount_pkr, points_redeemed, points_discount_pkr, total_pkr, points_earned, placed_at)
      select gen_random_uuid(), 'BENCHMARK-ADMIN-' || lpad(g::text, 5, '0'), c.id, u.id, 'ADMIN', 'BALANCE', 'DELIVERED', false, p.total_pkr, 0::numeric(12,2), 0, 0::numeric(12,2), p.total_pkr, 0, now() - ((g % 365)::text || ' days')::interval
      from generate_series(1,50000) g
      cross join lateral (select id from public.customers where import_key='BENCHMARK_ADMIN_50K' limit 1) c
      cross join lateral (select id from public.users order by created_at limit 1) u
      cross join lateral (select coalesce(sum(price_pkr),0)::numeric(12,2) total_pkr from (select price_pkr from public.products where is_active order by sku limit 4) selected) p
      where not exists (select 1 from public.orders where order_number='BENCHMARK-ADMIN-00001');
      insert into public.order_lines (id, order_id, product_id, quantity, unit_price_pkr, line_total_pkr)
      select gen_random_uuid(), o.id, p.id, 1::numeric(12,3), p.price_pkr, p.price_pkr
      from public.orders o
      cross join lateral (select id, price_pkr from public.products where is_active order by sku limit 4 offset ((row_number() over (order by o.order_number)::integer - 1) % 4)) p
      where o.order_number like 'BENCHMARK-ADMIN-%'
        and not exists (select 1 from public.order_lines ol where ol.order_id=o.id);
    `);
  });
  console.log("Admin benchmark fixture seeded: 50,000 benchmark orders and four lines per order (200,000 lines target). Records are marked BENCHMARK and internal.");
}

main().catch((error) => { console.error(error); process.exitCode = 1; }).finally(() => prisma.$disconnect());
