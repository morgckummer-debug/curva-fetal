-- 033 — Vitrine do iPad da recepção (vitrine.html) e pré-adesão.
--
-- A paciente vê os planos no iPad, toca em "Quero contratar" e preenche os próprios dados.
-- Isso NÃO cria paciente nem gestação: cria uma pré-adesão, que aparece na Recepção como
-- "Pelo iPad · conferir". A recepção confere o nome com o documento (o nome da adesão não muda
-- depois), passa a maquininha e só então usa o fluxo de "Nova adesão" de sempre, já preenchido.
--
-- O mesmo formulário serve de casa: a recepção manda o link no WhatsApp (…&de=casa) e a
-- paciente preenche com calma; na clínica sobram a conferência do documento, a maquininha e a
-- assinatura. `origem` diz por onde veio.
--
-- O iPad não tem login: a página recebe uma chave da clínica (vitrine_chaves) no endereço,
-- gerada pela recepção. A chave só permite CRIAR pré-adesão; nada é lido de volta.

create table if not exists public.vitrine_chaves (
  token     text primary key,
  dono_id   uuid not null references auth.users(id) on delete cascade,
  criado_em timestamptz not null default now()
);
create unique index if not exists vitrine_chaves_dono_uq on public.vitrine_chaves (dono_id);
alter table public.vitrine_chaves enable row level security; -- sem policy: só pelas funções abaixo

create table if not exists public.pre_adesoes (
  id            bigserial primary key,
  dono_id       uuid not null references auth.users(id) on delete cascade,
  nome          text not null,
  cpf           text not null,           -- 000.000.000-00
  email         text not null default '',
  celular       text not null default '',
  modalidade    text not null check (modalidade in ('essencial','premium','gemelar_essencial','gemelar_dc')),
  dum           date,
  us_data       date,
  us_ig_dias    int check (us_ig_dias between 1 and 300),
  origem        text not null default 'ipad' check (origem in ('ipad','link')),
  status        text not null default 'nova' check (status in ('nova','cadastrada','descartada')),
  gestacao_id   bigint,
  criado_em     timestamptz not null default now(),
  resolvido_em  timestamptz,
  resolvido_por text not null default ''
);
create index if not exists pre_adesoes_dono_status on public.pre_adesoes (dono_id, status);
alter table public.pre_adesoes enable row level security; -- sem policy: só pelas funções abaixo

-- Recepção/médica: devolve (criando se preciso) a chave do iPad da clínica.
create or replace function public.recepcao_vitrine_chave()
returns text
language plpgsql
security definer
set search_path = public
as $$
declare v_dono uuid; v_tok text;
begin
  select dono_id into v_dono from public.recepcao_acessos where user_id = auth.uid();
  if v_dono is null then v_dono := auth.uid(); end if;
  if v_dono is null then raise exception 'sem acesso' using errcode = '42501'; end if;
  select token into v_tok from public.vitrine_chaves where dono_id = v_dono;
  if v_tok is null then
    v_tok := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
    insert into public.vitrine_chaves (token, dono_id) values (v_tok, v_dono);
  end if;
  return v_tok;
end;
$$;

-- iPad (anônimo): grava a pré-adesão. Uma por CPF em aberto: se a mesma paciente reenviar,
-- a anterior é atualizada em vez de duplicar.
create or replace function public.vitrine_pre_adesao(
  p_chave text, p_nome text, p_cpf text, p_email text, p_celular text, p_modalidade text,
  p_dum date default null, p_us_data date default null, p_us_ig_dias int default null,
  p_origem text default 'ipad'
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_dono uuid;
  v_dig  text := regexp_replace(coalesce(p_cpf, ''), '\D', '', 'g');
  v_cpf  text;
  v_nome text := regexp_replace(btrim(coalesce(p_nome, '')), '\s+', ' ', 'g');
  v_id   bigint;
begin
  if p_chave is null or length(p_chave) < 32 then raise exception 'chave inválida'; end if;
  select dono_id into v_dono from public.vitrine_chaves where token = p_chave;
  if v_dono is null then raise exception 'chave inválida'; end if;
  if length(v_nome) < 5 or length(v_nome) > 120 or position(' ' in v_nome) = 0 then raise exception 'informe o nome completo'; end if;
  if length(v_dig) <> 11 then raise exception 'CPF deve ter 11 dígitos'; end if;
  if p_modalidade not in ('essencial','premium','gemelar_essencial','gemelar_dc') then raise exception 'modalidade inválida'; end if;
  if p_dum is not null and (p_dum > current_date or p_dum < current_date - 300) then raise exception 'DUM inválida'; end if;
  if p_us_data is not null and (p_us_data > current_date or p_us_data < current_date - 300) then raise exception 'data do ultrassom inválida'; end if;
  -- Freio contra abuso da página pública: no máximo 30 pré-adesões novas por dia.
  if (select count(*) from public.pre_adesoes where dono_id = v_dono and criado_em > now() - interval '1 day') >= 30 then
    raise exception 'limite diário atingido; procure a recepção';
  end if;
  v_cpf := substr(v_dig,1,3) || '.' || substr(v_dig,4,3) || '.' || substr(v_dig,7,3) || '-' || substr(v_dig,10,2);
  select id into v_id from public.pre_adesoes where dono_id = v_dono and cpf = v_cpf and status = 'nova';
  if v_id is not null then
    update public.pre_adesoes
       set nome = v_nome, email = left(btrim(coalesce(p_email, '')), 120), celular = left(btrim(coalesce(p_celular, '')), 20),
           modalidade = p_modalidade, dum = p_dum, us_data = p_us_data,
           us_ig_dias = case when p_us_data is not null then p_us_ig_dias end, criado_em = now(),
           origem = case when p_origem = 'link' then 'link' else 'ipad' end
     where id = v_id;
  else
    insert into public.pre_adesoes (dono_id, nome, cpf, email, celular, modalidade, dum, us_data, us_ig_dias, origem)
    values (v_dono, v_nome, v_cpf, left(btrim(coalesce(p_email, '')), 120), left(btrim(coalesce(p_celular, '')), 20),
            p_modalidade, p_dum, p_us_data, case when p_us_data is not null then p_us_ig_dias end,
            case when p_origem = 'link' then 'link' else 'ipad' end);
  end if;
  return true;
end;
$$;

-- Recepção/médica: pré-adesões em aberto.
create or replace function public.recepcao_pre_adesoes()
returns jsonb
language plpgsql
security definer
set search_path = public
stable
as $$
declare v_dono uuid;
begin
  select dono_id into v_dono from public.recepcao_acessos where user_id = auth.uid();
  if v_dono is null then v_dono := auth.uid(); end if;
  if v_dono is null then raise exception 'sem acesso' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(to_jsonb(p) - 'dono_id' order by p.criado_em)
                     from public.pre_adesoes p where p.dono_id = v_dono and p.status = 'nova'), '[]'::jsonb);
end;
$$;

-- Recepção/médica: marca a pré-adesão como cadastrada (com a gestação criada) ou descartada.
create or replace function public.recepcao_pre_adesao_resolver(p_id bigint, p_status text, p_gestacao_id bigint default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_dono uuid; v_nome text;
begin
  select dono_id, nome into v_dono, v_nome from public.recepcao_acessos where user_id = auth.uid();
  if v_dono is null then v_dono := auth.uid(); end if;
  if v_dono is null then raise exception 'sem acesso' using errcode = '42501'; end if;
  if p_status not in ('cadastrada','descartada') then raise exception 'status inválido'; end if;
  update public.pre_adesoes
     set status = p_status, gestacao_id = p_gestacao_id, resolvido_em = now(), resolvido_por = coalesce(v_nome, 'médica')
   where id = p_id and dono_id = v_dono;
end;
$$;

revoke all on function public.recepcao_vitrine_chave() from public, anon;
grant execute on function public.recepcao_vitrine_chave() to authenticated;
revoke all on function public.vitrine_pre_adesao(text, text, text, text, text, text, date, date, int, text) from public;
grant execute on function public.vitrine_pre_adesao(text, text, text, text, text, text, date, date, int, text) to anon, authenticated;
revoke all on function public.recepcao_pre_adesoes() from public, anon;
grant execute on function public.recepcao_pre_adesoes() to authenticated;
revoke all on function public.recepcao_pre_adesao_resolver(bigint, text, bigint) from public, anon;
grant execute on function public.recepcao_pre_adesao_resolver(bigint, text, bigint) to authenticated;
