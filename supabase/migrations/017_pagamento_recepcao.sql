-- 017 — Conferência de pagamento do acompanhamento + CPF na tela da recepção.
--
-- O Curvas não tem dados financeiros: a fonte da verdade do pagamento continua sendo a
-- Feegow / a maquininha. Esta tabela guarda só a CONFERÊNCIA manual ("a recepção confirmou
-- que está pago"), com quem marcou e quando, para a médica auditar sem abrir outro sistema.
--
-- Fica numa tabela à parte (e não em colunas de gestacoes) de propósito: o app da médica
-- reescreve gestacoes inteira a cada saveDB(); uma coluna editada pela recepção seria
-- sobrescrita pelo estado antigo da tela dela.
--
-- A recepção escreve só por recepcao_pagamento() (security definer); a médica lê/escreve
-- direto pela policy de dono.

create table if not exists public.pagamentos_acompanhamento (
  gestacao_id      bigint primary key references public.gestacoes(id) on delete cascade,
  user_id          uuid   not null references auth.users(id) on delete cascade, -- a médica (dona)
  status           text   not null default 'pendente' check (status in ('pendente','parcial','quitado')),
  forma            text   check (forma in ('cartao','pix','dinheiro','outro')),
  parcelas         int    check (parcelas between 1 and 12),
  contrato_assinado boolean not null default false,
  observacao       text   not null default '',
  atualizado_por   text   not null default '',
  atualizado_em    timestamptz not null default now()
);

alter table public.pagamentos_acompanhamento enable row level security;

drop policy if exists "dono pode tudo" on public.pagamentos_acompanhamento;
create policy "dono pode tudo" on public.pagamentos_acompanhamento
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Painel da recepção: agora com CPF (busca por nome ou CPF) e a conferência de pagamento.
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
  -- A própria médica também abre esta tela (para conferir pagamentos): enxerga só o que é dela.
  if v_dono is null then v_dono := auth.uid(); end if;
  if v_dono is null then
    raise exception 'sem acesso' using errcode = '42501';
  end if;

  return coalesce((
    select jsonb_agg(
      jsonb_build_object(
        'gestacao_id',    g.id,
        'nome',           p.nome,
        'cpf',            p.cpf,
        'acompanhamento', g.acompanhamento,
        'tipo_gestacao',  g.tipo_gestacao,
        'dum',            g.dum,
        'ig_base_data',   g.ig_base_data,
        'ig_base_valor',  g.ig_base_valor,
        'pagamento', (
          select jsonb_build_object(
                   'status', pg.status, 'forma', pg.forma, 'parcelas', pg.parcelas,
                   'contrato_assinado', pg.contrato_assinado, 'observacao', pg.observacao,
                   'atualizado_por', pg.atualizado_por, 'atualizado_em', pg.atualizado_em)
          from public.pagamentos_acompanhamento pg where pg.gestacao_id = g.id
        ),
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

-- A recepção registra a conferência (só das gestações da própria médica).
create or replace function public.recepcao_pagamento(
  p_gestacao_id bigint, p_status text, p_forma text, p_parcelas int,
  p_contrato boolean, p_obs text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_dono uuid;
  v_nome text;
begin
  select dono_id, nome into v_dono, v_nome from public.recepcao_acessos where user_id = auth.uid();
  if v_dono is null then
    v_dono := auth.uid();
    v_nome := 'Dra. Morgana';
  end if;
  if v_dono is null then
    raise exception 'sem acesso' using errcode = '42501';
  end if;
  if not exists (select 1 from public.gestacoes where id = p_gestacao_id and user_id = v_dono and excluido_em is null) then
    raise exception 'gestação não encontrada';
  end if;
  if p_status not in ('pendente','parcial','quitado') then
    raise exception 'status inválido';
  end if;
  insert into public.pagamentos_acompanhamento
    (gestacao_id, user_id, status, forma, parcelas, contrato_assinado, observacao, atualizado_por, atualizado_em)
  values
    (p_gestacao_id, v_dono, p_status, nullif(p_forma, ''), p_parcelas, coalesce(p_contrato, false),
     left(coalesce(p_obs, ''), 500), coalesce(v_nome, ''), now())
  on conflict (gestacao_id) do update set
    status = excluded.status, forma = excluded.forma, parcelas = excluded.parcelas,
    contrato_assinado = excluded.contrato_assinado, observacao = excluded.observacao,
    atualizado_por = excluded.atualizado_por, atualizado_em = excluded.atualizado_em;
end;
$$;

revoke all on function public.painel_recepcao() from public, anon;
revoke all on function public.recepcao_pagamento(bigint, text, text, int, boolean, text) from public, anon;
grant execute on function public.painel_recepcao() to authenticated;
grant execute on function public.recepcao_pagamento(bigint, text, text, int, boolean, text) to authenticated;
