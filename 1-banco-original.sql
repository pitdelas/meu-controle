-- MEU CONTROLE: estrutura do banco (Supabase / Postgres)
-- Cole tudo no SQL Editor do Supabase e clique em Run.

-- Clientes de cada empreendedor
create table public.clients (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  name text not null,
  phone text,
  created_at timestamptz not null default now()
);

-- Entradas (serviços vendidos) e despesas
create table public.entries (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  type text not null check (type in ('in', 'out')),   -- in = entrada, out = despesa
  client_id uuid references public.clients(id) on delete set null,
  description text,
  category text,                                       -- usada nas despesas
  total numeric(12,2) not null check (total > 0),
  entry_date date not null default current_date,
  due_date date,                                       -- quando o cliente deve pagar
  created_at timestamptz not null default now()
);

-- Pagamentos recebidos (permite pagamento parcial)
create table public.payments (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  entry_id uuid not null references public.entries(id) on delete cascade,
  amount numeric(12,2) not null check (amount > 0),
  paid_on date not null default current_date,
  created_at timestamptz not null default now()
);

create index on public.clients (user_id);
create index on public.entries (user_id, entry_date);
create index on public.payments (user_id, entry_id);

-- SEGURANÇA: cada usuário só enxerga e altera os próprios dados
alter table public.clients  enable row level security;
alter table public.entries  enable row level security;
alter table public.payments enable row level security;

create policy "clients: só o dono" on public.clients
  for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy "entries: só o dono" on public.entries
  for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy "payments: só o dono" on public.payments
  for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
