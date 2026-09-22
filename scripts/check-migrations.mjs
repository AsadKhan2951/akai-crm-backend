// Verifies the migration chain before `supabase db push`.
import fs from "node:fs";

const dir = "supabase/migrations";
const files = fs.readdirSync(dir).filter((f) => f.endsWith(".sql")).sort();
const versions = files.map((f) => f.split("_")[0]);
const expectedMissing = ["0001_foundation", "0005_catalogue_admin", "0006_versioned_price_lists", "0008_vendor_purchase_suggestions", "0009_vendor_portal_workflows", "0010_vendor_payment_method"];
let failed = false;

if (new Set(versions).size !== versions.length) { console.log("BLOCKED duplicate migration versions"); failed = true; }
for (const name of expectedMissing) {
  const [num, ...rest] = name.split("_");
  const file = `20250101${num}00_${rest.join("_")}.sql`;
  if (fs.existsSync(`${dir}/${file}`)) console.log(`PASS ${file}`);
  else { console.log(`BLOCKED missing ${file} (restore the original ${name}/migration.sql)`); failed = true; }
}
console.log(`${files.length} migration files found.`);
console.log(failed ? "\nMigration chain: BLOCKED — do not run supabase db push on production." : "\nMigration chain: complete.");
process.exitCode = failed ? 1 : 0;
