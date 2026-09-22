import type { PrismaClient } from "@prisma/client";

/**
 * Restore compatibility only. Real catalogue records must come from the approved
 * catalogue import; this module intentionally does not invent brands, categories,
 * or products.
 */
export const SEED_BRANDS: readonly [] = [];
export const SEED_CATEGORIES: readonly [] = [];

export async function seedCatalogue(prisma: PrismaClient) {
  void prisma;
  // No fake catalogue data is created. Use the approved catalogue importer.
}
