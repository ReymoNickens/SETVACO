-- Local/dev demo dataset — mirrors the initial* arrays in index.html exactly,
-- so `supabase db reset` reproduces the same starting point the live
-- prototype ships with. Not applied in production (see docs/architecture.md
-- §4) — roles/branches/nav_permissions, the only *required* reference data,
-- are seeded by the migrations themselves, not here.

do $$
declare
  v_accra uuid; v_kumasi uuid; v_tema uuid;
  v_sr01 uuid; v_sr02 uuid; v_sr03 uuid; v_sr04 uuid; v_sr05 uuid;
  v_wp1001 uuid; v_wp1012 uuid; v_cv2004 uuid; v_sm2110 uuid; v_br3005 uuid;
  v_cn3311 uuid; v_el4002 uuid; v_wp1020 uuid; v_wp1031 uuid; v_wp1044 uuid;
  v_eq5001 uuid; v_eq5002 uuid; v_eq5003 uuid; v_eq5004 uuid; v_eq5005 uuid;
  v_v01 uuid; v_v02 uuid; v_v03 uuid; v_v04 uuid;
  v_c01 uuid; v_c02 uuid; v_c03 uuid; v_c04 uuid; v_c05 uuid;
  v_admin uuid; v_sales uuid; v_warehouse uuid; v_procurement uuid; v_service uuid; v_finance uuid;
  v_qt9001 uuid; v_qt9002 uuid; v_qt9003 uuid;
  v_inv6001 uuid;
  v_po7710 uuid; v_po7705 uuid; v_po7698 uuid;
  v_sj210 uuid; v_sj208 uuid;
begin
  select id into v_accra  from branches where name = 'Accra HQ';
  select id into v_kumasi from branches where name = 'Kumasi Branch';
  select id into v_tema   from branches where name = 'Tema Warehouse';

  -- ---- Demo staff accounts (auth.users -> profiles via the handle_new_auth_user trigger) ----
  -- Password for every seeded account: 'setvaco-demo' (local/dev only).
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data)
  values
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'e.mensah@setvaco.com', crypt('setvaco-demo', gen_salt('bf')), now(), now(), now(), '{"provider":"email","providers":["email"]}', '{"name":"Efua Mensah","username":"emensah","role":"admin"}'),
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'k.owusu@setvaco.com', crypt('setvaco-demo', gen_salt('bf')), now(), now(), now(), '{"provider":"email","providers":["email"]}', '{"name":"Kwabena Owusu","username":"kowusu","role":"sales"}'),
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'y.darko@setvaco.com', crypt('setvaco-demo', gen_salt('bf')), now(), now(), now(), '{"provider":"email","providers":["email"]}', '{"name":"Yaw Darko","username":"ydarko","role":"warehouse"}'),
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'a.sarpong@setvaco.com', crypt('setvaco-demo', gen_salt('bf')), now(), now(), now(), '{"provider":"email","providers":["email"]}', '{"name":"Abena Sarpong","username":"asarpong","role":"procurement"}'),
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'k.boateng@setvaco.com', crypt('setvaco-demo', gen_salt('bf')), now(), now(), now(), '{"provider":"email","providers":["email"]}', '{"name":"Kojo Boateng","username":"kboateng","role":"service"}'),
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'a.amponsah@setvaco.com', crypt('setvaco-demo', gen_salt('bf')), now(), now(), now(), '{"provider":"email","providers":["email"]}', '{"name":"Adjoa Amponsah","username":"aamponsah","role":"finance"}');

  select id into v_admin       from profiles where email = 'e.mensah@setvaco.com';
  select id into v_sales       from profiles where email = 'k.owusu@setvaco.com';
  select id into v_warehouse   from profiles where email = 'y.darko@setvaco.com';
  select id into v_procurement from profiles where email = 'a.sarpong@setvaco.com';
  select id into v_service     from profiles where email = 'k.boateng@setvaco.com';
  select id into v_finance     from profiles where email = 'a.amponsah@setvaco.com';

  -- ---- Stock rooms ----
  insert into stock_rooms (name, branch_id) values ('Main Store', v_accra)      returning id into v_sr01;
  insert into stock_rooms (name, branch_id) values ('Wear Parts Yard', v_accra) returning id into v_sr02;
  insert into stock_rooms (name, branch_id) values ('Main Store', v_kumasi)     returning id into v_sr03;
  insert into stock_rooms (name, branch_id) values ('Main Store', v_tema)      returning id into v_sr04;
  insert into stock_rooms (name, branch_id) values ('Bonded Store', v_tema)    returning id into v_sr05;

  -- ---- Parts ----
  insert into items (type, name, brand, category, branch_id, stock_room_id, qty, reorder, cost, sell) values
    ('part', 'Jaw Crusher Wear Plate', 'Terex Powerscreen', 'Wear Parts', v_accra, v_sr02, 4, 6, 3800, 5200) returning id into v_wp1001;
  insert into items (type, name, brand, category, branch_id, stock_room_id, qty, reorder, cost, sell) values
    ('part', 'Cone Crusher Mantle', 'Sandvik', 'Wear Parts', v_kumasi, v_sr03, 2, 3, 6200, 8600) returning id into v_wp1012;
  insert into items (type, name, brand, category, branch_id, stock_room_id, qty, reorder, cost, sell) values
    ('part', 'Conveyor Belt (per m)', 'AUROX', 'Conveyor', v_accra, v_sr01, 40, 20, 45, 68) returning id into v_cv2004;
  insert into items (type, name, brand, category, branch_id, stock_room_id, qty, reorder, cost, sell) values
    ('part', 'Screen Mesh Panel', 'Powerscreen', 'Screening Media', v_tema, v_sr04, 15, 10, 210, 310) returning id into v_sm2110;
  insert into items (type, name, brand, category, branch_id, stock_room_id, qty, reorder, cost, sell) values
    ('part', 'Crusher Bearing Set', 'Sandvik', 'Bearings', v_accra, v_sr01, 6, 8, 950, 1350) returning id into v_br3005;
  insert into items (type, name, brand, category, branch_id, stock_room_id, qty, reorder, cost, sell) values
    ('part', 'Hydraulic Filter', 'Terex', 'Consumable', v_kumasi, v_sr03, 22, 12, 55, 85) returning id into v_cn3311;
  insert into items (type, name, brand, category, branch_id, stock_room_id, qty, reorder, cost, sell) values
    ('part', 'VFD Drive Module', 'Voltline', 'Electrical', v_accra, v_sr01, 1, 2, 4100, 5600) returning id into v_el4002;
  insert into items (type, name, brand, category, branch_id, stock_room_id, qty, reorder, cost, sell) values
    ('part', 'Feeder Grizzly Bar', 'Powerscreen', 'Wear Parts', v_tema, v_sr05, 8, 6, 380, 540) returning id into v_wp1020;
  insert into items (type, name, brand, category, branch_id, stock_room_id, qty, reorder, cost, sell) values
    ('part', 'Impact Crusher Blow Bar', 'Sandvik', 'Wear Parts', v_accra, v_sr02, 3, 5, 1650, 2300) returning id into v_wp1031;
  insert into items (type, name, brand, category, branch_id, stock_room_id, qty, reorder, cost, sell) values
    ('part', 'Toggle Plate', 'Terex', 'Wear Parts', v_kumasi, v_sr03, 5, 4, 720, 990) returning id into v_wp1044;

  -- ---- Equipment ----
  insert into items (type, name, brand, category, branch_id, stock_room_id, qty, reorder, cost, sell) values
    ('equipment', 'Mobile Jaw Crusher MJ-42', 'Terex Powerscreen', 'Crushing Plant', v_accra, v_sr01, 1, 1, 1850000, 2350000) returning id into v_eq5001;
  insert into items (type, name, brand, category, branch_id, stock_room_id, qty, reorder, cost, sell) values
    ('equipment', 'Cone Crusher CH430', 'Sandvik', 'Crushing Plant', v_kumasi, v_sr03, 1, 1, 2100000, 2650000) returning id into v_eq5002;
  insert into items (type, name, brand, category, branch_id, stock_room_id, qty, reorder, cost, sell) values
    ('equipment', 'Mobile Screening Plant MS-18', 'Powerscreen', 'Screening Plant', v_tema, v_sr04, 2, 1, 980000, 1250000) returning id into v_eq5003;
  insert into items (type, name, brand, category, branch_id, stock_room_id, qty, reorder, cost, sell) values
    ('equipment', 'Radial Stacking Conveyor 24m', 'AUROX', 'Conveying', v_accra, v_sr02, 3, 1, 210000, 275000) returning id into v_eq5004;
  insert into items (type, name, brand, category, branch_id, stock_room_id, qty, reorder, cost, sell) values
    ('equipment', 'Impact Crusher NP1213', 'Sandvik', 'Crushing Plant', v_tema, v_sr05, 0, 1, 1650000, 2050000) returning id into v_eq5005;

  -- ---- Vendors ----
  insert into vendors (name, code, contact, email, phone, alt_contact, categories, tax_exempt, certificate_path) values
    ('Sandvik Parts Distribution', 'SND-GH-014', 'Lars Eriksson', 'parts@sandvik-gh.com', '+233 30 222 1145', 'Mikael Roos, Accounts', 'Crusher wear parts, bearings', false, 'sandvik-business-cert.pdf') returning id into v_v01;
  insert into vendors (name, code, contact, email, phone, alt_contact, categories, tax_exempt, certificate_path) values
    ('Terex Aftermarket', 'TRX-WA-221', 'Mensah Owusu', 'aftermarket@terex.com', '+233 24 556 7788', '', 'Wear parts, filters, electrical', false, null) returning id into v_v02;
  insert into vendors (name, code, contact, email, phone, alt_contact, categories, tax_exempt, certificate_path) values
    ('AUROX Composites and Compounds Oy', 'AUX-FI-009', 'Mika Laine', 'sales@auroxcc.fi', '+358 40 123 4567', '', 'Conveyor belting', true, null) returning id into v_v03;
  insert into vendors (name, code, contact, email, phone, alt_contact, categories, tax_exempt, certificate_path) values
    ('Voltline Electrical Supplies', 'VLT-GH-077', 'Nana Yeboah', 'info@voltline.com.gh', '+233 20 334 8899', '', 'Electrical, VFD drives', false, null) returning id into v_v04;

  -- ---- Customers + contacts ----
  insert into customers (name, tier, country, country_code, address, email, phone, contact_person, contact_address, company_details, po_code, credit_limit, outstanding, tax_exempt) values
    ('Chorkor Mines Ltd', 'Gold', 'Ghana', 'GH', 'Plot 12, Tarkwa Industrial Area, Tarkwa', 'procurement@chorkormines.com', '+233 24 111 2233', 'Samuel Aidoo', 'Plot 12, Tarkwa Industrial Area, Tarkwa', 'Registered mining operator · TIN GH-0091827', 'CHK-001', 150000, 42000, false) returning id into v_c01;
  insert into customer_contacts (customer_id, name, role, email, phone) values
    (v_c01, 'Samuel Aidoo', 'Procurement Manager', 's.aidoo@chorkormines.com', '+233 24 111 2233'),
    (v_c01, 'Linda Owusu', 'Finance Officer', 'l.owusu@chorkormines.com', '+233 24 111 9090');

  insert into customers (name, tier, country, country_code, address, email, phone, contact_person, contact_address, company_details, po_code, credit_limit, outstanding, tax_exempt) values
    ('Akwatia Gold Ltd', 'Gold', 'Ghana', 'GH', 'Km 4 Akwatia-Kade Rd, Akwatia', 'buying@akwatiagold.com', '+233 24 220 6611', 'Grace Antwi', 'Km 4 Akwatia-Kade Rd, Akwatia', 'Registered mining operator · TIN GH-0075512', 'AWG-002', 100000, 88000, false) returning id into v_c02;
  insert into customer_contacts (customer_id, name, role, email, phone) values
    (v_c02, 'Grace Antwi', 'Purchasing Lead', 'g.antwi@akwatiagold.com', '+233 24 220 6611');
  insert into approval_flagged_customers (customer_id) values (v_c02);

  insert into customers (name, tier, country, country_code, address, email, phone, contact_person, contact_address, company_details, po_code, credit_limit, outstanding, tax_exempt) values
    ('Ghana Gold Processing', 'Silver', 'Ghana', 'GH', 'Industrial Area, Obuasi', 'orders@ghanagoldproc.com', '+233 20 445 1290', 'Isaac Boadu', 'Industrial Area, Obuasi', 'Processing plant operator · TIN GH-0062341', 'GGP-003', 60000, 15000, true) returning id into v_c03;
  insert into customer_contacts (customer_id, name, role, email, phone) values
    (v_c03, 'Isaac Boadu', 'Plant Manager', 'i.boadu@ghanagoldproc.com', '+233 20 445 1290');

  insert into customers (name, tier, country, country_code, address, email, phone, contact_person, contact_address, company_details, po_code, credit_limit, outstanding, tax_exempt) values
    ('Bamako Quarry Co.', 'Standard', 'Mali', 'ML', 'Zone Industrielle, Bamako', 'achats@bamakoquarry.ml', '+223 76 334 220', 'Moussa Traoré', 'Zone Industrielle, Bamako', 'Quarry operator · RCCM ML-BKO-2014', 'BMQ-004', 30000, 5000, false) returning id into v_c04;
  insert into customer_contacts (customer_id, name, role, email, phone) values
    (v_c04, 'Moussa Traoré', 'Site Manager', 'm.traore@bamakoquarry.ml', '+223 76 334 220');

  insert into customers (name, tier, country, country_code, address, email, phone, contact_person, contact_address, company_details, po_code, credit_limit, outstanding, tax_exempt) values
    ('Ivorian Aggregates SARL', 'Silver', 'Côte d''Ivoire', 'CI', 'Zone Industrielle Yopougon, Abidjan', 'contact@ivorianagg.ci', '+225 07 08 556 213', 'Aya Kouassi', 'Zone Industrielle Yopougon, Abidjan', 'Aggregates producer · RCCM CI-ABJ-2011', 'IVA-005', 50000, 20000, false) returning id into v_c05;
  insert into customer_contacts (customer_id, name, role, email, phone) values
    (v_c05, 'Aya Kouassi', 'Buyer', 'a.kouassi@ivorianagg.ci', '+225 07 08 556 213');

  -- ---- Quotations + lines ----
  insert into quotations (type, customer_id, country, subtotal, apply_tax, tax_rate, tax_amount, total, lead_time_days, eta, prepared_by_id, status, quote_date, created_by) values
    ('part', v_c01, 'Ghana', 10400, true, 15, 1560, 11960, 14, '2026-08-19', v_sales, 'Quoted', '2026-08-05', v_sales) returning id into v_qt9001;
  insert into quotation_lines (quotation_id, item_id, description, qty, unit_price, new_part, line_no) values
    (v_qt9001, v_wp1001, 'Jaw Crusher Wear Plate', 2, 5200, false, 1);

  insert into quotations (type, customer_id, country, subtotal, apply_tax, tax_rate, tax_amount, total, lead_time_days, eta, prepared_by_id, status, quote_date, created_by) values
    ('equipment', v_c02, 'Ghana', 2650000, true, 15, 397500, 3047500, 45, '2026-09-20', v_sales, 'Sent', '2026-08-04', v_sales) returning id into v_qt9002;
  insert into quotation_lines (quotation_id, item_id, description, qty, unit_price, new_part, line_no) values
    (v_qt9002, v_eq5002, 'Cone Crusher CH430', 1, 2650000, false, 1);

  insert into quotations (type, customer_id, country, subtotal, apply_tax, tax_rate, tax_amount, total, lead_time_days, eta, prepared_by_id, status, quote_date, created_by) values
    ('part', v_c03, 'Ghana', 850, false, 15, 0, 850, 5, '2026-08-06', v_sales, 'Invoiced', '2026-08-01', v_sales) returning id into v_qt9003;
  insert into quotation_lines (quotation_id, item_id, description, qty, unit_price, new_part, line_no) values
    (v_qt9003, v_cn3311, 'Hydraulic Filter', 10, 85, false, 1);

  -- ---- Invoice (QT-9003 already converted) ----
  insert into invoices (quotation_id, type, customer_id, subtotal, apply_tax, tax_rate, tax_amount, total, status, invoice_date, created_by) values
    (v_qt9003, 'part', v_c03, 850, false, 15, 0, 850, 'Paid', '2026-08-01', v_sales) returning id into v_inv6001;
  insert into invoice_lines (invoice_id, item_id, description, qty, unit_price, new_part, line_no) values
    (v_inv6001, v_cn3311, 'Hydraulic Filter', 10, 85, false, 1);

  -- ---- Purchase orders + lines ----
  insert into purchase_orders (vendor_id, status, po_date, expected, source, created_by) values
    (v_v03, 'In Transit', '2026-08-02', '2026-08-14', 'manual', v_procurement) returning id into v_po7710;
  insert into purchase_order_lines (purchase_order_id, item_id, item_name, qty) values (v_po7710, v_cv2004, 'Conveyor Belt (per m)', 50);

  insert into purchase_orders (vendor_id, status, po_date, expected, source, created_by) values
    (v_v01, 'Ordered', '2026-08-05', '2026-08-20', 'manual', v_procurement) returning id into v_po7705;
  insert into purchase_order_lines (purchase_order_id, item_id, item_name, qty) values (v_po7705, v_wp1012, 'Cone Crusher Mantle', 3);

  insert into purchase_orders (vendor_id, status, po_date, expected, source, created_by) values
    (v_v02, 'Received', '2026-07-25', '2026-08-01', 'manual', v_procurement) returning id into v_po7698;
  insert into purchase_order_lines (purchase_order_id, item_id, item_name, qty) values (v_po7698, v_cn3311, 'Hydraulic Filter', 30);

  -- ---- Service jobs ----
  insert into service_jobs (customer_id, job_type, country, description, technician_id, technician_name, item_id, item_name, qty, eta, prepared_by_id, status, job_date) values
    (v_c01, 'Crusher Reline', 'Ghana', 'Full jaw crusher liner replacement and toggle inspection.', v_service, 'K. Boateng', v_wp1001, 'Jaw Crusher Wear Plate', 2, '2026-08-12', v_service, 'In Progress', '2026-08-05') returning id into v_sj210;
  insert into service_jobs (customer_id, job_type, country, description, technician_id, technician_name, item_id, item_name, qty, eta, prepared_by_id, status, job_date) values
    (v_c02, 'Feeder Repair', 'Ghana', 'Vibrating feeder grizzly bar replacement.', null, 'E. Adonoo', v_wp1020, 'Feeder Grizzly Bar', 2, '2026-08-06', v_service, 'Completed', '2026-08-03') returning id into v_sj208;

  -- ---- Audit log, notifications, variance log ----
  insert into audit_log (ts, actor_id, actor_name, action, module) values
    ('2026-08-05T09:12:00', v_sales, 'Kwabena Owusu', 'Created quotation QT-9001 for Chorkor Mines Ltd', 'Sales'),
    ('2026-08-05T10:40:00', v_procurement, 'Abena Sarpong', 'Raised PO-7705 to Sandvik Parts Distribution', 'Purchasing'),
    ('2026-08-03T14:05:00', v_service, 'Kojo Boateng', 'Completed service job SJ-208 — parts consumed from stock', 'Service');

  insert into notifications (ts, type, message, read) values
    ('2026-08-02T08:00:00', 'po', 'PO-7710 received from AUROX — 1 line item in transit', true);

  insert into variance_log (item_id, branch_id, expected, counted, delta, severity, note) values
    (v_cn3311, v_kumasi, 26, 22, -4, 'Low', 'Within normal consumption drift'),
    (v_br3005, v_accra, 8, 6, -2, 'High', 'Unreconciled against sales orders and service jobs — flagged for review'),
    (v_sm2110, v_tema, 18, 15, -3, 'Medium', 'One unit issued without matching sales order');
end $$;
