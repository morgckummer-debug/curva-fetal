-- 045 — Frases personalizadas dos médicos guardadas no banco (2026-11-06, pedido da Morgana).
--
-- Até aqui as frases moravam só no localStorage do navegador onde foram editadas: não iam para o
-- repositório, não tinham cópia e não passavam de um computador para outro. Agora o editor de laudos
-- (laudos-dramorgana, laudo-core.js) grava cada chave de frases aqui, por médico, e o navegador fica
-- só como cache. Quem edita é a digitadora logada, com o médico escolhido no seletor: nenhum médico
-- precisa mandar arquivo nem ter login.
--
-- Chave (`chave`): a mesma do localStorage, ex. 'ob23-phrase-templates-v2:paulo' (laudo + médico).
-- Dona dos dados: a Dra. (`user_id` = dono_laudos()). As digitadoras são outros usuários do Auth
-- ligados a ela em `laudo_digitadoras` — tabela à parte de `recepcao_acessos` de propósito: quem só
-- digita laudo NÃO pode abrir o painel da recepção (CPF, pagamentos).
--
-- Rodar UMA vez no SQL Editor do projeto Supabase do Curvas.
-- Depois, para liberar cada digitadora (rodar no SQL Editor, não pela API):
--   1. Authentication → Users → Add user (e-mail + senha, "Auto Confirm User" marcado).
--      O e-mail é só um identificador interno: o laudo monta <id>@laudos.invalid a partir do nome
--      escolhido na lista (tpsl, mel, emo, mesc) e a digitadora digita só a senha.
--   2. select public.liberar_digitadora('tpsl@laudos.invalid', 'e-mail-da-dra@exemplo.com', 'Thays Pereira');

-- Quem pode gravar frases: digitadoras ligadas a uma dona.
create table if not exists public.laudo_digitadoras (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  dono_id    uuid not null references auth.users(id) on delete cascade,
  nome       text not null default '',
  created_at timestamptz not null default now()
);
-- RLS ligada e nenhuma policy: ninguém lê/escreve pela API. Só o SQL Editor e as funções abaixo.
alter table public.laudo_digitadoras enable row level security;
revoke all on public.laudo_digitadoras from anon, authenticated;

-- Dona dos laudos do usuário logado: a dona (ela mesma) ou a dona da digitadora.
create or replace function public.dono_laudos()
returns uuid
language sql
security definer
set search_path = public
stable
as $$
  select coalesce((select dono_id from public.laudo_digitadoras where user_id = auth.uid()), auth.uid());
$$;
revoke all on function public.dono_laudos() from public, anon;
grant execute on function public.dono_laudos() to authenticated;

create table if not exists public.laudo_frases (
  user_id        uuid        not null default public.dono_laudos(),
  chave          text        not null,
  valor          jsonb       not null,
  atualizado_por text        not null default '',
  atualizado_em  timestamptz not null default now(),
  primary key (user_id, chave)
);
alter table public.laudo_frases enable row level security;
revoke all on public.laudo_frases from anon, authenticated;
-- Leitura direta pela API; escrita só pelas funções laudo_frases_gravar/apagar (abaixo).
grant select on public.laudo_frases to authenticated;

drop policy if exists laudo_frases_sel on public.laudo_frases;
create policy laudo_frases_sel on public.laudo_frases for select to authenticated
  using (user_id = public.dono_laudos());

create or replace function public.laudo_frases_gravar(p_chave text, p_valor jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_dono uuid := public.dono_laudos();
begin
  if v_dono is null then raise exception 'sem acesso' using errcode = '42501'; end if;
  if coalesce(p_chave, '') = '' or p_valor is null then raise exception 'chave ou valor vazio'; end if;
  insert into public.laudo_frases (user_id, chave, valor) values (v_dono, p_chave, p_valor)
  on conflict (user_id, chave) do update set valor = excluded.valor;
end;
$$;

create or replace function public.laudo_frases_apagar(p_chave text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_dono uuid := public.dono_laudos();
begin
  if v_dono is null then raise exception 'sem acesso' using errcode = '42501'; end if;
  delete from public.laudo_frases where user_id = v_dono and chave = p_chave;
end;
$$;
revoke all on function public.laudo_frases_gravar(text, jsonb) from public, anon;
revoke all on function public.laudo_frases_apagar(text)        from public, anon;
grant execute on function public.laudo_frases_gravar(text, jsonb) to authenticated;
grant execute on function public.laudo_frases_apagar(text)        to authenticated;

-- Histórico: toda gravação e exclusão fica registrada (quem, quando, valor antes e depois). Só
-- acréscimo — RLS ligada, sem policy, sem permissão para anon/authenticated. Lê-se pelo painel
-- do Supabase (Table Editor) ou pelo SQL Editor.
create table if not exists public.laudo_frases_historico (
  id      bigserial   primary key,
  user_id uuid        not null,
  chave   text        not null,
  em      timestamptz not null default now(),
  por     text        not null default '',
  acao    text        not null,
  antes   jsonb,
  depois  jsonb
);
create index if not exists laudo_frases_historico_idx on public.laudo_frases_historico (user_id, chave, em desc);
alter table public.laudo_frases_historico enable row level security;
revoke all on public.laudo_frases_historico from anon, authenticated;

-- Nome de quem gravou: o da digitadora; sem registro, o e-mail do login (a dona).
create or replace function public._laudo_frases_quem()
returns text
language sql
security definer
set search_path = public, auth
stable
as $$
  select coalesce(nullif((select nome from public.laudo_digitadoras where user_id = auth.uid()), ''),
                  (select email from auth.users where id = auth.uid()),
                  'Sistema (alteração direta no banco)');
$$;

-- Antes de gravar: carimba quem e quando (a digitadora não escolhe o próprio nome).
create or replace function public._laudo_frases_carimbo()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  new.atualizado_por := public._laudo_frases_quem();
  new.atualizado_em  := now();
  return new;
end;
$$;
drop trigger if exists laudo_frases_carimbo on public.laudo_frases;
create trigger laudo_frases_carimbo before insert or update on public.laudo_frases
  for each row execute function public._laudo_frases_carimbo();

-- Depois de gravar: histórico. AFTER, e não BEFORE, para o upsert que vira UPDATE não registrar
-- também o INSERT que foi descartado; regravar o mesmo valor não gera registro.
create or replace function public._laudo_frases_historico_trg()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare quem text := public._laudo_frases_quem();
begin
  if tg_op = 'DELETE' then
    insert into public.laudo_frases_historico (user_id, chave, por, acao, antes)
    values (old.user_id, old.chave, quem, 'apagou', old.valor);
  elsif tg_op = 'INSERT' then
    insert into public.laudo_frases_historico (user_id, chave, por, acao, depois)
    values (new.user_id, new.chave, quem, 'gravou', new.valor);
  elsif new.valor is distinct from old.valor then
    insert into public.laudo_frases_historico (user_id, chave, por, acao, antes, depois)
    values (new.user_id, new.chave, quem, 'gravou', old.valor, new.valor);
  end if;
  return null;
end;
$$;
drop trigger if exists laudo_frases_trg on public.laudo_frases;
create trigger laudo_frases_trg after insert or update or delete on public.laudo_frases
  for each row execute function public._laudo_frases_historico_trg();

create or replace function public.liberar_digitadora(p_email_digitadora text, p_email_dono text, p_nome text default '')
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_dig  uuid;
  v_dono uuid;
begin
  select id into v_dig  from auth.users where lower(email) = lower(p_email_digitadora);
  select id into v_dono from auth.users where lower(email) = lower(p_email_dono);
  if v_dig  is null then raise exception 'digitadora não encontrada em Authentication → Users'; end if;
  if v_dono is null then raise exception 'dono (médica) não encontrado'; end if;
  if v_dig = v_dono then raise exception 'a digitadora precisa ser outro usuário'; end if;
  insert into public.laudo_digitadoras (user_id, dono_id, nome)
  values (v_dig, v_dono, coalesce(p_nome, ''))
  on conflict (user_id) do update set dono_id = excluded.dono_id, nome = excluded.nome;
end;
$$;
revoke all on function public.liberar_digitadora(text, text, text) from public, anon, authenticated;
