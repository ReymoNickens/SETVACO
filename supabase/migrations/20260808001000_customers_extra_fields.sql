-- The prototype UI also captures a customer's own industry PO code, a
-- free-text company-details blurb, and a separate contact-mailing address —
-- add them now rather than dropping fields the Customers screen already
-- relies on.
alter table customers add column po_code text;
alter table customers add column company_details text;
alter table customers add column contact_address text;
create unique index customers_po_code_company_idx on customers (company_id, upper(po_code)) where po_code is not null;
