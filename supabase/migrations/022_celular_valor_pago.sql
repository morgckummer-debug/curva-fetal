-- 022 — Celular da paciente e valor pago, gravados na conferência de pagamento.
--
-- Antes o celular só ia para o contrato (não era gravado) e o valor pago era digitado a cada
-- encerramento. Agora ficam em pagamentos_acompanhamento (tabela da recepção, à parte de
-- gestacoes pelo mesmo motivo da 017: o saveDB da médica reescreve gestacoes inteira).

alter table public.pagamentos_acompanhamento
  add column if not exists celular text,
  add column if not exists valor_pago numeric(10,2) check (valor_pago is null or valor_pago >= 0);

-- Painel: devolve celular e valor_pago junto da conferência.
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
                   'celular', pg.celular, 'valor_pago', pg.valor_pago,
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

-- Conferência: ganha celular e valor pago (assinatura nova; a de 6 argumentos sai).
drop function if exists public.recepcao_pagamento(bigint, text, text, int, boolean, text);
create or replace function public.recepcao_pagamento(
  p_gestacao_id bigint, p_status text, p_forma text, p_parcelas int,
  p_contrato boolean, p_obs text,
  p_celular text default null, p_valor_pago numeric default null
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
    (gestacao_id, user_id, status, forma, parcelas, contrato_assinado, observacao,
     celular, valor_pago, atualizado_por, atualizado_em)
  values
    (p_gestacao_id, v_dono, p_status, nullif(p_forma, ''), p_parcelas, coalesce(p_contrato, false),
     left(coalesce(p_obs, ''), 500), nullif(left(coalesce(p_celular, ''), 30), ''), p_valor_pago,
     coalesce(v_nome, ''), now())
  on conflict (gestacao_id) do update set
    status = excluded.status, forma = excluded.forma, parcelas = excluded.parcelas,
    contrato_assinado = excluded.contrato_assinado, observacao = excluded.observacao,
    celular = excluded.celular, valor_pago = excluded.valor_pago,
    atualizado_por = excluded.atualizado_por, atualizado_em = excluded.atualizado_em;
end;
$$;

-- Só o celular (usado ao cadastrar a adesão, antes de qualquer conferência de pagamento).
create or replace function public.recepcao_contato(p_gestacao_id bigint, p_celular text)
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
  insert into public.pagamentos_acompanhamento (gestacao_id, user_id, celular, atualizado_por, atualizado_em)
  values (p_gestacao_id, v_dono, nullif(left(coalesce(p_celular, ''), 30), ''), coalesce(v_nome, ''), now())
  on conflict (gestacao_id) do update set
    celular = excluded.celular, atualizado_por = excluded.atualizado_por, atualizado_em = excluded.atualizado_em;
end;
$$;

revoke all on function public.painel_recepcao() from public, anon;
revoke all on function public.recepcao_pagamento(bigint, text, text, int, boolean, text, text, numeric) from public, anon;
revoke all on function public.recepcao_contato(bigint, text) from public, anon;
grant execute on function public.painel_recepcao() to authenticated;
grant execute on function public.recepcao_pagamento(bigint, text, text, int, boolean, text, text, numeric) to authenticated;
grant execute on function public.recepcao_contato(bigint, text) to authenticated;
