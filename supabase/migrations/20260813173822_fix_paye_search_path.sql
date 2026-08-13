-- calc_ghana_paye_monthly (added in 20260813173638_payroll.sql) was missing
-- `set search_path = public`, unlike every other function in this schema —
-- caught by the security advisor immediately after that migration landed.
create or replace function calc_ghana_paye_monthly(p_taxable numeric) returns numeric
language plpgsql immutable set search_path = public as $$
declare
  v_widths numeric[] := array[490, 110, 130, 3166.67, 16000, 30520];
  v_rates  numeric[] := array[0, 0.05, 0.10, 0.175, 0.25, 0.30, 0.35];
  v_remaining numeric := greatest(p_taxable, 0);
  v_tax numeric := 0;
  v_width numeric;
  i int;
begin
  for i in 1..array_length(v_widths, 1) loop
    exit when v_remaining <= 0;
    v_width := least(v_remaining, v_widths[i]);
    v_tax := v_tax + v_width * v_rates[i];
    v_remaining := v_remaining - v_width;
  end loop;
  if v_remaining > 0 then
    v_tax := v_tax + v_remaining * v_rates[array_length(v_rates, 1)];
  end if;
  return round(v_tax, 2);
end $$;
