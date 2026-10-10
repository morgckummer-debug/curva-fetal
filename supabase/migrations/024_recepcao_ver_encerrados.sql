-- 024: a recepção passa a ver também os acompanhamentos ENCERRADOS (desistência, parto,
-- perda, óbito), marcados na lista, em vez de a paciente sumir. painel_recepcao() devolve
-- 'status' e não filtra mais por status = 'ativa'. Só esta função muda.

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
        'status',         g.status,
        'tipo_gestacao',  g.tipo_gestacao,
        'dum',            g.dum,
        'ig_base_data',   g.ig_base_data,
        'ig_base_valor',  g.ig_base_valor,
        'pagamento', (
          select jsonb_build_object(
                   'status', pg.status, 'forma', pg.forma, 'parcelas', pg.parcelas,
                   'contrato_assinado', pg.contrato_assinado, 'observacao', pg.observacao,
                   'celular', pg.celular, 'valor_pago', pg.valor_pago, 'comprovantes', pg.comprovantes,
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
      and g.acompanhamento is not null
  ), '[]'::jsonb);
end;
$$;

grant execute on function public.painel_recepcao() to authenticated;
