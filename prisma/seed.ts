import { PrismaClient } from "@prisma/client";
import { SEED_BRANDS, SEED_CATEGORIES, seedCatalogue } from "./catalogue-seed";

const prisma = new PrismaClient();

const PERMISSION_GROUPS = {
  CATALOGUE: [
    "product.view", "product.create", "product.update", "product.delete", "product.bulk_import", "product.view_cost", "product.manage_images",
    "category.view", "category.create", "category.update", "category.delete",
    "brand.view", "brand.create", "brand.update", "brand.delete",
    "collection.view", "collection.manage", "pricelist.view", "pricelist.create", "pricelist.activate",
  ],
  CUSTOMERS: [
    "customer.view", "customer.create", "customer.update", "customer.delete", "customer.reassign_agent", "customer.export", "customer.enrich",
    "vendorgroup.manage", "catalogvisibility.manage", "vendoraccount.create", "vendoraccount.deactivate",
  ],
  PIPELINE: [
    "lead.view", "lead.create", "lead.update", "lead.delete", "lead.import", "lead.reassign", "activity.view", "activity.create", "activity.delete",
    "followup.view", "followup.manage", "beat.view", "beat.manage", "beat.visit",
  ],
  "ORDERS AND QUOTES": [
    "order.view", "order.create", "order.update_status", "order.approve", "order.cancel", "order.export", "quote.view", "quote.create", "quote.price", "quote.cancel",
  ],
  FINANCE: [
    "ledger.view", "ledger.record_payment", "ledger.adjust", "collection.view", "collection.record", "collection.deposit", "collection.verify_deposit", "collection.cancel", "collection.reminder", "recoverytarget.manage", "creditlimit.manage", "financials.view_revenue", "financials.view_margin",
  ],
  "PROMOTIONS AND LOYALTY": [
    "banner.view", "banner.manage", "scheme.view", "scheme.create", "scheme.activate", "scheme.analytics", "reward.manage", "loyalty.view", "redemption.request", "redemption.approve", "loyalty.adjust",
  ],
  DELIVERY: ["delivery.view", "delivery.create_run", "delivery.mark_delivered", "delivery.reconcile"],
  CLAIMS: ["claim.view", "claim.create", "claim.review", "claim.approve", "warranty.manage"],
  REPORTING: ["dashboard.view", "report.build", "report.schedule", "report.export"],
  COMMUNICATIONS: ["message.send", "message.campaign", "whatsapp.manage_templates", "whatsapp.kill_switch", "notification.view"],
  AI: ["ai.chat", "ai.analytics", "ai.generate_content", "ai.manage_budget"],
  VOICE: ["voice.capture", "voice.view"],
  PWA: ["pwa.sync"],
  SYSTEM: ["user.view", "user.create", "user.update", "user.deactivate", "role.view", "role.create", "role.update", "role.delete", "settings.manage", "auditlog.view", "integration.manage", "impersonate.vendor"],
} as const;

const SENSITIVE = new Set([
  "product.view_cost", "financials.view_margin", "pricelist.activate", "ledger.adjust", "loyalty.adjust", "collection.cancel", "customer.export", "role.create", "role.update", "user.create", "settings.manage", "impersonate.vendor", "whatsapp.kill_switch",
]);

const DEPENDENCIES: Record<string, string[]> = {
  "product.create": ["product.view"], "product.update": ["product.view"], "product.delete": ["product.view"], "product.bulk_import": ["product.view"], "product.manage_images": ["product.view"],
  "category.create": ["category.view"], "category.update": ["category.view"], "category.delete": ["category.view"],
  "brand.create": ["brand.view"], "brand.update": ["brand.view"], "brand.delete": ["brand.view"],
  "customer.create": ["customer.view"], "customer.update": ["customer.view"], "customer.delete": ["customer.view"], "customer.reassign_agent": ["customer.view"], "customer.export": ["customer.view"], "customer.enrich": ["customer.view"],
  "lead.create": ["lead.view"], "lead.update": ["lead.view"], "lead.delete": ["lead.view"], "lead.import": ["lead.view"], "lead.reassign": ["lead.view"],
  "activity.create": ["activity.view"], "activity.delete": ["activity.view"], "followup.manage": ["followup.view"], "beat.manage": ["beat.view"], "beat.visit": ["beat.view", "activity.create"],
  "order.update_status": ["order.view"], "order.approve": ["order.view"], "order.cancel": ["order.view"], "order.export": ["order.view"],
  "quote.price": ["quote.view"], "quote.cancel": ["quote.view"],
  "ledger.record_payment": ["ledger.view"], "ledger.adjust": ["ledger.view"],
  "collection.record": ["collection.view"], "collection.deposit": ["collection.view", "collection.record"], "collection.verify_deposit": ["collection.view"], "collection.cancel": ["collection.view"], "collection.reminder": ["collection.view", "message.send"], "recoverytarget.manage": ["collection.view"],
  "scheme.create": ["scheme.view"], "scheme.activate": ["scheme.view"], "scheme.analytics": ["scheme.view"], "redemption.request": ["loyalty.view"],
  "claim.review": ["claim.view"], "claim.approve": ["claim.view"],
  "role.create": ["role.view", "user.view"], "role.update": ["role.view", "user.view"], "role.delete": ["role.view", "user.view"],
  "user.create": ["user.view"], "user.update": ["user.view"], "user.deactivate": ["user.view"],
  "financials.view_margin": ["product.view_cost"],
};

const PRESET_ROLES = [
  {
    name: "Administrator",
    description: "Full administrative access across the AKAI CRM.",
    dataScope: "GLOBAL" as const,
    portalAccess: "ADMIN" as const,
    isSystemRole: true,
    permissions: "ALL" as const,
  },
  {
    name: "Sales Agent",
    description: "Own assigned customers and field-sales work without cost, margin, approvals, or settings.",
    dataScope: "OWN" as const,
    portalAccess: "SALES" as const,
    isSystemRole: true,
    permissions: [
      "product.view", "category.view", "brand.view", "collection.view", "pricelist.view", "customer.view", "customer.create", "customer.update", "customer.enrich", "lead.view", "lead.create", "lead.update", "lead.import", "activity.view", "activity.create", "voice.capture", "voice.view", "followup.view", "followup.manage", "beat.view", "beat.visit", "order.view", "order.create", "quote.view", "quote.create", "collection.view", "collection.record", "collection.deposit", "claim.create", "dashboard.view", "financials.view_revenue", "scheme.view", "delivery.view", "ai.chat", "pwa.sync",
    ],
  },
  {
    name: "Vendor",
    description: "Self-scoped dealer access to visible catalogue, orders, quotes, claims, ledger, and loyalty views.",
    dataScope: "SELF" as const,
    portalAccess: "VENDOR" as const,
    isSystemRole: true,
    permissions: ["product.view", "category.view", "brand.view", "collection.view", "pricelist.view", "order.view", "order.create", "quote.view", "quote.create", "claim.view", "claim.create", "scheme.view", "ledger.view", "loyalty.view", "redemption.request", "delivery.view", "ai.chat", "pwa.sync"],
  },
  {
    name: "Catalogue Manager",
    description: "Global catalogue management without cost visibility or unrelated access.",
    dataScope: "GLOBAL" as const,
    portalAccess: "ADMIN" as const,
    isSystemRole: false,
    permissions: ["product.view", "product.create", "product.update", "product.delete", "product.bulk_import", "product.manage_images", "category.view", "category.create", "category.update", "category.delete", "brand.view", "brand.create", "brand.update", "brand.delete", "collection.view", "collection.manage", "ai.generate_content", "dashboard.view"],
  },
  {
    name: "Sales Manager",
    description: "Team-scoped sales management with approvals, reassignment, and reporting.",
    dataScope: "TEAM" as const,
    portalAccess: "SALES" as const,
    isSystemRole: false,
    permissions: ["product.view", "category.view", "brand.view", "collection.view", "pricelist.view", "customer.view", "customer.update", "customer.reassign_agent", "lead.view", "lead.create", "lead.update", "lead.reassign", "activity.view", "activity.create", "voice.capture", "voice.view", "followup.view", "followup.manage", "beat.view", "beat.manage", "beat.visit", "order.view", "order.create", "order.approve", "quote.view", "quote.create", "quote.price", "collection.view", "collection.record", "collection.deposit", "collection.verify_deposit", "claim.create", "dashboard.view", "report.build", "financials.view_revenue", "scheme.view", "delivery.view", "ai.chat", "pwa.sync"],
  },
  {
    name: "Accounts / Recovery Officer",
    description: "Global accounts and recovery operations with revenue visibility but no margin access.",
    dataScope: "GLOBAL" as const,
    portalAccess: "ADMIN" as const,
    isSystemRole: false,
    permissions: ["ledger.view", "ledger.record_payment", "ledger.adjust", "collection.view", "collection.record", "collection.deposit", "collection.verify_deposit", "collection.cancel", "collection.reminder", "recoverytarget.manage", "creditlimit.manage", "customer.view", "order.view", "dashboard.view", "report.build", "report.export", "financials.view_revenue", "message.send"],
  },
  {
    name: "Support Agent",
    description: "Global support access to customers, orders, quotes, claims, activities, and messages.",
    dataScope: "GLOBAL" as const,
    portalAccess: "ADMIN" as const,
    isSystemRole: false,
    permissions: ["customer.view", "order.view", "quote.view", "claim.view", "claim.create", "activity.create", "voice.capture", "voice.view", "message.send", "ai.chat"],
  },
  {
    name: "Analyst",
    description: "Read-only global reporting access.",
    dataScope: "GLOBAL" as const,
    portalAccess: "ADMIN" as const,
    isSystemRole: false,
    permissions: ["dashboard.view", "report.build", "report.export", "financials.view_revenue", "ai.analytics"],
  },
] as const;

function labelFromKey(key: string) {
  return key.split(".").at(-1)?.replaceAll("_", " ").replace(/(^|\\s)\\S/g, (letter) => letter.toUpperCase()) ?? key;
}

function expandDependencies(keys: string[]) {
  const expanded = new Set(keys);
  const visit = (key: string) => {
    for (const prerequisite of DEPENDENCIES[key] ?? []) {
      if (!expanded.has(prerequisite)) {
        expanded.add(prerequisite);
        visit(prerequisite);
      }
    }
  };
  for (const key of [...expanded]) visit(key);
  return [...expanded];
}

async function main() {
  const permissionRows = Object.entries(PERMISSION_GROUPS).flatMap(([module, keys], moduleIndex) =>
    keys.map((key, displayIndex) => ({
      key,
      module,
      labelEn: labelFromKey(key),
      labelUr: `اجازت: ${key}`,
      description: `Permission for ${key}.`,
      isSensitive: SENSITIVE.has(key),
      displayOrder: moduleIndex * 100 + displayIndex,
    })),
  );

  await prisma.permission.createMany({ data: permissionRows, skipDuplicates: true });
  const permissions = await prisma.permission.findMany({ select: { id: true, key: true } });
  const permissionIds = new Map(permissions.map((permission) => [permission.key, permission.id]));

  await prisma.permissionDependency.createMany({
    data: Object.entries(DEPENDENCIES).flatMap(([key, prerequisites]) => prerequisites.map((requiresPermissionKey) => ({
      permissionId: permissionIds.get(key)!,
      requiresPermissionId: permissionIds.get(requiresPermissionKey)!,
    }))),
    skipDuplicates: true,
  });

  for (const preset of PRESET_ROLES) {
    const role = await prisma.role.upsert({
      where: { name: preset.name },
      create: { name: preset.name, description: preset.description, dataScope: preset.dataScope, portalAccess: preset.portalAccess, isSystemRole: preset.isSystemRole, isActive: true },
      update: { description: preset.description, dataScope: preset.dataScope, portalAccess: preset.portalAccess, isSystemRole: preset.isSystemRole, isActive: true },
    });
    const keys = preset.permissions === "ALL" ? permissions.map((permission) => permission.key) : [...preset.permissions, "notification.view"];
    const expandedKeys = expandDependencies([...keys]);
    await prisma.rolePermission.deleteMany({ where: { roleId: role.id } });
    await prisma.rolePermission.createMany({
      data: expandedKeys.map((key) => ({ roleId: role.id, permissionId: permissionIds.get(key)! })),
      skipDuplicates: true,
    });
  }

  await seedCatalogue(prisma);
  console.log(`Seeded ${permissionRows.length} permissions, ${PRESET_ROLES.length} preset roles, ${SEED_BRANDS.length} brands, and ${SEED_CATEGORIES.length} categories.`);
}

main()
  .catch((error) => {
    console.error(error);
    process.exitCode = 1;
  })
  .finally(async () => prisma.$disconnect());
