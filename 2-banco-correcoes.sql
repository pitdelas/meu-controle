-- MEU CONTROLE: correções do esquema
-- Rode no SQL Editor do Supabase DEPOIS do script original.

-- 1) Impedir que um usuário ligue seus registros a clientes/lançamentos de outro.
--    As chaves estrangeiras não passam pelo RLS, então a regra precisa estar na própria FK.
alter table public.clients add constraint clients_id_user_key unique (id, user_id);
alter table public.entries add constraint entries_id_user_key unique (id, user_id);

alter table public.entries drop constraint entries_client_id_fkey;
alter table public.entries add constraint entries_client_fk
  foreign key (client_id, user_id) references public.clients (id, user_id)
  on delete set null (client_id);

alter table public.payments drop constraint payments_entry_id_fkey;
alter table public.payments add constraint payments_entry_fk
  foreign key (entry_id, user_id) references public.entries (id, user_id)
  on delete cascade;

-- 2) Coerência: despesa não tem cliente; só entrada recebe pagamento.
alter table public.entries add constraint entries_cliente_so_em_entrada
  check (type = 'in' or client_id is null);

-- 3) Data padrão no fuso do Brasil (o servidor do Supabase roda em UTC:
--    sem isso, tudo que for lançado depois das 21h cai no dia seguinte).
alter table public.entries  alter column entry_date set default ((now() at time zone 'America/Sao_Paulo')::date);
alter table public.payments alter column paid_on    set default ((now() at time zone 'America/Sao_Paulo')::date);

-- 4) Pagamentos não podem passar do total, nem ir para uma despesa.
create or replace function public.validar_pagamento() returns trigger
language plpgsql as $$
declare
  v_total numeric;
  v_tipo  text;
  v_pago  numeric;
begin
  select total, type into v_total, v_tipo
    from public.entries where id = new.entry_id
    for update;                       -- trava o lançamento: evita dois pagamentos simultâneos estourarem o total
  if v_tipo <> 'in' then
    raise exception 'Pagamentos só podem ser registrados em entradas';
  end if;
  select coalesce(sum(amount), 0) into v_pago
    from public.payments where entry_id = new.entry_id and id <> new.id;
  if v_pago + new.amount > v_total then
    raise exception 'Pagamento maior que o valor em aberto (falta R$ %)', v_total - v_pago;
  end if;
  return new;
end $$;

create trigger payments_validar before insert or update on public.payments
  for each row execute function public.validar_pagamento();

-- Também impede baixar o total de um serviço para menos do que já foi pago.
create or replace function public.validar_total() returns trigger
language plpgsql as $$
declare v_pago numeric;
begin
  select coalesce(sum(amount), 0) into v_pago from public.payments where entry_id = new.id;
  if new.total < v_pago then
    raise exception 'O total não pode ficar menor que o já recebido (R$ %)', v_pago;
  end if;
  return new;
end $$;

create trigger entries_validar_total before update of total on public.entries
  for each row execute function public.validar_total();

-- 5) Índices que faltavam (busca por cliente e contas a receber por vencimento).
create index if not exists entries_client_idx on public.entries (client_id, user_id);
create index if not exists entries_due_idx on public.entries (user_id, due_date)
  where type = 'in' and due_date is not null;

-- 6) Políticas com (select auth.uid()): recomendação do Supabase para o
--    auth.uid() ser calculado uma vez por consulta, não uma vez por linha.
drop policy "clients: só o dono"  on public.clients;
drop policy "entries: só o dono"  on public.entries;
drop policy "payments: só o dono" on public.payments;

create policy "clients: só o dono" on public.clients
  for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

create policy "entries: só o dono" on public.entries
  for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

create policy "payments: só o dono" on public.payments
  for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

-- 7) Visão pronta para o app: quanto já foi pago, quanto falta e a situação.
--    security_invoker = true é obrigatório: sem isso a view ignora o RLS
--    e qualquer usuário veria os lançamentos de todos.
create or replace view public.entries_status
with (security_invoker = true) as
select
  e.*,
  coalesce(p.pago, 0)           as pago,
  e.total - coalesce(p.pago, 0) as falta,
  case
    when e.type = 'out' then null
    when coalesce(p.pago, 0) >= e.total then 'pago'
    when e.due_date < (now() at time zone 'America/Sao_Paulo')::date then 'vencido'
    when coalesce(p.pago, 0) > 0 then 'parcial'
    else 'pendente'
  end as status
from public.entries e
left join (
  select entry_id, sum(amount) as pago from public.payments group by entry_id
) p on p.entry_id = e.id;
