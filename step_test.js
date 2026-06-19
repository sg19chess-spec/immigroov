const { Client } = require('pg');
const f = (iso) => new Intl.DateTimeFormat('en',{timeZone:'Europe/Amsterdam',hour:'2-digit',minute:'2-digit',hour12:false}).format(new Date(iso));
(async()=>{
  const c=new Client({connectionString:process.env.DATABASE_URL,ssl:{rejectUnauthorized:false}});
  await c.connect(); await c.query('BEGIN');
  try {
    const m=(await c.query(`select mm.id from mentors mm join users u on u.id=mm.user_id where u.email='emma@demo.immigroov.test'`)).rows[0].id;
    const s30=(await c.query(`select id from services where mentor_id=$1 and duration=30 and is_active limit 1`,[m])).rows[0].id;
    const s60=(await c.query(`select id from services where mentor_id=$1 and duration=60 and is_active limit 1`,[m])).rows[0].id;
    const day=(await c.query(`select (current_date + interval '40 day')::date d`)).rows[0].d;
    // override that date to 09:00-11:00 Amsterdam (controls the day)
    await c.query(`insert into specific_availability(mentor_id,slot_date,start_time,end_time,timezone,is_blackout) values($1,$2,'09:00','11:00','Europe/Amsterdam',false)`,[m,day]);

    let r=(await c.query(`select slot_start from get_available_slots($1,$2,$3,$3) order by slot_start`,[m,s30,day])).rows;
    console.log('30-min, 09:00–11:00 →', r.map(x=>f(x.slot_start)).join(', '), `(${r.length} slots)`);

    r=(await c.query(`select slot_start from get_available_slots($1,$2,$3,$3) order by slot_start`,[m,s60,day])).rows;
    console.log('60-min, 09:00–11:00 →', r.map(x=>f(x.slot_start)).join(', '), `(${r.length} slots)`);

    // book a 30-min at 09:30 Amsterdam
    const nineThirty=(await c.query(`select ($1::text||' 09:30')::timestamp at time zone 'Europe/Amsterdam' t`,[day])).rows[0].t;
    const uu=(await c.query(`insert into users(email,role) values('stept@x.com','user') returning id`)).rows[0].id;
    await c.query(`insert into bookings(user_id,mentor_id,service_id,slot_time,status) values($1,$2,$3,$4,'confirmed')`,[uu,m,s30,nineThirty]);

    r=(await c.query(`select slot_start from get_available_slots($1,$2,$3,$3) order by slot_start`,[m,s60,day])).rows;
    console.log('\nAfter a 30-min booking at 09:30 — 60-min service →', r.map(x=>f(x.slot_start)).join(', '), `(${r.length}; expect only 10:00)`);
    r=(await c.query(`select slot_start from get_available_slots($1,$2,$3,$3) order by slot_start`,[m,s30,day])).rows;
    console.log('   ...and 30-min service →', r.map(x=>f(x.slot_start)).join(', '), '(9:30 gone)');
  } finally { await c.query('ROLLBACK'); console.log('\n(rolled back)'); await c.end(); }
})().catch(e=>{console.error('FATAL',e.message);process.exit(1)});
