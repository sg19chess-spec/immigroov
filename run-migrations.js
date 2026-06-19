const { Client } = require('pg');
const fs = require('fs');
const path = require('path');

const connectionString = process.env.DATABASE_URL;
const files = process.argv.slice(2);

(async () => {
  const client = new Client({
    connectionString,
    ssl: { rejectUnauthorized: false },
  });
  try {
    await client.connect();
    console.log('Connected to database OK\n');

    if (files.length === 0) {
      // connection test only
      const r = await client.query('select current_database() db, version()');
      console.log('DB:', r.rows[0].db);
      console.log(r.rows[0].version.split(',')[0]);
      return;
    }

    for (const f of files) {
      const sql = fs.readFileSync(f, 'utf8');
      process.stdout.write(`Applying ${path.basename(f)} ... `);
      await client.query(sql);
      console.log('done');
    }
    console.log('\nAll migrations applied successfully.');
  } catch (e) {
    console.error('\nERROR:', e.message);
    process.exitCode = 1;
  } finally {
    await client.end();
  }
})();
