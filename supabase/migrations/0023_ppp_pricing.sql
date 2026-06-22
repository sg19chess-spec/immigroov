-- PPP (Purchasing Power Parity) pricing.
-- Price-level factors (US = 1.00), floored so we never sell too cheap. PPP only
-- applies to services where the mentor enabled is_ppp. Country comes from the
-- frontend (HTTPS IP geolocation -> timezone fallback -> manual override).
create table if not exists ppp_factors (country_code varchar(2) primary key, factor numeric not null);
insert into ppp_factors(country_code, factor) values
 ('US',1.00),('CA',0.92),('GB',0.94),('IE',0.95),('DE',0.90),('FR',0.92),('NL',0.93),
 ('ES',0.78),('IT',0.80),('PT',0.72),('SE',0.97),('NO',1.05),('CH',1.15),('PL',0.55),
 ('RO',0.50),('AU',0.95),('NZ',0.90),('JP',0.85),('KR',0.78),('SG',0.85),('HK',0.90),
 ('AE',0.72),('SA',0.60),('QA',0.70),('IN',0.30),('PK',0.29),('BD',0.32),('LK',0.32),
 ('NP',0.30),('ID',0.38),('PH',0.40),('VN',0.37),('TH',0.45),('MY',0.45),('CN',0.55),
 ('BR',0.45),('MX',0.50),('AR',0.40),('CO',0.42),('CL',0.55),('PE',0.45),('ZA',0.45),
 ('NG',0.40),('KE',0.42),('EG',0.28),('MA',0.45),('TR',0.40),('RU',0.42),('UA',0.35)
on conflict (country_code) do update set factor = excluded.factor;

insert into platform_settings(key,value,description)
values ('ppp_floor','0.40','Minimum PPP factor (never price below this fraction of base)')
on conflict (key) do nothing;

create or replace function get_ppp_factor(p_cc text)
returns numeric language sql stable security definer set search_path = public as $$
  select greatest(
    coalesce((select factor from ppp_factors where country_code = upper(p_cc)), 1.0),
    coalesce((select value::numeric from platform_settings where key = 'ppp_floor'), 0.40));
$$;
grant execute on function get_ppp_factor(text) to anon, authenticated;

-- book_session(_guest) gain p_ppp_factor (default 1.0); mentor payout scales by it.
-- (full bodies applied via the project; see 0021/0022 plus the p_ppp_factor arg)
