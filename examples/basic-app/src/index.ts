// Minimal smoke-test entrypoint: query the local Supabase stack's PostgREST
// endpoint (served by Kong at 127.0.0.1:54321/rest/v1) and print the results.
// Replace with your own app; keep it dependency-free until you need more.

const SUPABASE_URL = process.env["SUPABASE_URL"] ?? "http://127.0.0.1:54321";
const key = process.env["SUPABASE_PUBLISHABLE_KEY"];

interface Item {
  id: number;
  name: string;
}

async function main(): Promise<void> {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/items?select=*&order=id.asc&limit=50`, {
    headers: key ? { apikey: key, Authorization: `Bearer ${key}` } : {},
  });

  if (!res.ok) {
    console.error(`PostgREST responded ${res.status}:`, await res.text());
    process.exitCode = 1;
    return;
  }

  const items = (await res.json()) as Item[];
  console.log(`${items.length} item(s) from the local Supabase stack:`);
  for (const it of items) console.log(`  ${it.id}. ${it.name}`);
}

main();
