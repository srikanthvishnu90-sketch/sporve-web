begin;
insert into public.athletes (parent_id, first_name, date_of_birth, parent_consent)
values ((select id from public.profiles limit 1), 'GateTest', '2015-01-01', false);
rollback;
