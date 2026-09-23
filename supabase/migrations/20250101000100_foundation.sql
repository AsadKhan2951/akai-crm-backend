-- AKAI CRM foundation (RECONSTRUCTED).
-- The original 0001_foundation migration was missing from the recovered source. This file recreates only the objects
-- that 0002_permission_access and later migrations expect to exist, based on the legacy Prisma schema.

create type "Portal" as enum ('ADMIN', 'SALES', 'VENDOR');

create table "roles" (
  "id" text primary key default gen_random_uuid()::text,
  "name" text not null,
  "description" text,
  "is_active" boolean not null default true,
  "created_at" timestamptz(6) not null default now(),
  "updated_at" timestamptz(6) not null default now()
);

create table "permissions" (
  "id" text primary key default gen_random_uuid()::text,
  "code" text not null unique,
  "description" text,
  "created_at" timestamptz(6) not null default now()
);

create table "role_permissions" (
  "role_id" text not null references "roles"("id") on delete cascade,
  "permission_id" text not null references "permissions"("id") on delete cascade,
  primary key ("role_id", "permission_id")
);
create index "role_permissions_permission_id_idx" on "role_permissions" ("permission_id");
