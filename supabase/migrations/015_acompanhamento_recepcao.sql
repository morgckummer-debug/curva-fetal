-- 015 — Acompanhamento gestacional (modalidade contratada) e acesso restrito da recepção.
--
-- 1) gestacoes.acompanhamento: modalidade contratada (null = avulsa / sem acompanhamento).
-- 2) exams.extra: a visita foi usada como "ultrassom extra" do plano (não ocupa nenhuma
--    janela do calendário).
-- 3) recepcao_acessos + painel_recepcao(): login das secretárias que enxerga SÓ nome da
--    paciente, modalidade e datas/IG dos exames. Elas são usuários do Supabase Auth à parte;
--    as policies "dono pode tudo" (user_id = auth.uid()) continuam valendo e fazem com que
--    elas NÃO leiam patients/gestacoes/exams diretamente. O único caminho é a função abaixo
--    (security definer), que devolve um recorte fixo: sem CPF, sem medidas, sem laudos.

alter table public.gestacoes
  add column if not exists acompanhamento text
  check (acompanhamento in ('essencial','premium','gemelar_dc'));

alter table public.exams
  add column if not exists extra boolean not null default false;

create table if not exists public.recepcao_acessos (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  dono_id    uuid not null references auth.users(id) on delete cascade,
  nome       text not null default '',
  created_at timestamptz not null default now()
);

-- RLS ligada e nenhuma policy: ninguém lê/escreve a tabela pela API. Só a função abaixo
-- e o SQL Editor (liberar_recepcao) mexem nela.
alter table public.recepcao_acessos enable row level security;

create or replace function public.eh_recepcao()
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (select 1 from public.recepcao_acessos where user_id = auth.uid());
$$;

create or replace function public.painel_recepcao()
returns jsonb
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_dono uuid;
begin
  select dono_id into v_dono from public.recepcao_acessos where user_id = auth.uid();
  if v_dono is null then
    raise exception 'sem acesso' using errcode = '42501';
  end if;

  return coalesce((
    select jsonb_agg(
      jsonb_build_object(
        'gestacao_id',    g.id,
        'nome',           p.nome,
        'acompanhamento', g.acompanhamento,
        'tipo_gestacao',  g.tipo_gestacao,
        'dum',            g.dum,
        'ig_base_data',   g.ig_base_data,
        'ig_base_valor',  g.ig_base_valor,
        'exames', coalesce((
          select jsonb_agg(
                   jsonb_build_object(
                     'data_exame',     x.data_exame,
                     'ig_dias_manual', x.ig_dias_manual,
                     'extra',          x.extra,
                     'externo',        x.externo
                   ) order by x.data_exame)
          from (
            select e.data_exame,
                   max(e.ig_dias_manual) as ig_dias_manual,
                   bool_or(e.extra)      as extra,
                   bool_or(e.externo)    as externo
            from public.exams e
            where e.gestacao_id = g.id and e.excluido_em is null
            group by e.data_exame
          ) x
        ), '[]'::jsonb)
      ) order by p.nome
    )
    from public.gestacoes g
    join public.patients p on p.id = g.paciente_id
    where g.user_id = v_dono
      and g.excluido_em is null
      and p.excluido_em is null
      and g.status = 'ativa'
      and g.acompanhamento is not null
  ), '[]'::jsonb);
end;
$$;

revoke all on function public.eh_recepcao()     from public, anon;
revoke all on function public.painel_recepcao() from public, anon;
grant execute on function public.eh_recepcao()     to authenticated;
grant execute on function public.painel_recepcao() to authenticated;

-- Liberar uma secretária (rodar no SQL Editor, não pela API):
--   1. Authentication → Users → Add user (e-mail + senha, "Auto Confirm User" marcado).
--   2. select public.liberar_recepcao('secretaria@exemplo.com', 'e-mail-da-dra@exemplo.com', 'Nome');
create or replace function public.liberar_recepcao(p_email_secretaria text, p_email_dono text, p_nome text default '')
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sec uuid;
  v_dono uuid;
begin
  select id into v_sec  from auth.users where lower(email) = lower(p_email_secretaria);
  select id into v_dono from auth.users where lower(email) = lower(p_email_dono);
  if v_sec is null  then raise exception 'secretária não encontrada em Authentication → Users'; end if;
  if v_dono is null then raise exception 'dono (médica) não encontrado'; end if;
  if v_sec = v_dono then raise exception 'a secretária precisa ser outro usuário'; end if;
  insert into public.recepcao_acessos (user_id, dono_id, nome)
  values (v_sec, v_dono, coalesce(p_nome, ''))
  on conflict (user_id) do update set dono_id = excluded.dono_id, nome = excluded.nome;
end;
$$;
revoke all on function public.liberar_recepcao(text, text, text) from public, anon, authenticated;
