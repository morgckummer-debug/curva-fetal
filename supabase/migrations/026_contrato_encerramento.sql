alter table public.pagamentos_acompanhamento
  add column if not exists contratos jsonb not null default '[]'::jsonb,
  add column if not exists encerramento jsonb;

-- Painel: devolve também contratos e encerramento.
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
                   'contratos', pg.contratos, 'encerramento', pg.encerramento,
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

-- Registra um contrato já enviado ao Storage (cópia gerada ou foto/PDF assinado).
-- Anexar o ASSINADO marca contrato_assinado = true.
create or replace function public.recepcao_contrato_add(
  p_gestacao_id bigint, p_path text, p_nome text, p_tipo text, p_kind text, p_valor numeric default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_dono uuid;
  v_nome text;
  v_item jsonb;
begin
  select dono_id, nome into v_dono, v_nome from public.recepcao_acessos where user_id = auth.uid();
  if v_dono is null then
    v_dono := auth.uid();
    v_nome := 'Dra. Morgana';
  end if;
  if v_dono is null then
    raise exception 'sem acesso' using errcode = '42501';
  end if;
  if p_kind not in ('gerado', 'assinado') then
    raise exception 'tipo de contrato inválido';
  end if;
  if not exists (select 1 from public.gestacoes where id = p_gestacao_id and user_id = v_dono and excluido_em is null) then
    raise exception 'gestação não encontrada';
  end if;
  if p_path is null or p_path not like v_dono::text || '/' || p_gestacao_id::text || '/%' then
    raise exception 'caminho inválido';
  end if;
  v_item := jsonb_build_object('path', p_path, 'nome', left(coalesce(p_nome, ''), 120),
              'tipo', left(coalesce(p_tipo, ''), 60), 'kind', p_kind, 'valor', p_valor,
              'por', coalesce(v_nome, ''), 'em', now());
  insert into public.pagamentos_acompanhamento
    (gestacao_id, user_id, contratos, contrato_assinado, atualizado_por, atualizado_em)
  values (p_gestacao_id, v_dono, jsonb_build_array(v_item), p_kind = 'assinado', coalesce(v_nome, ''), now())
  on conflict (gestacao_id) do update set
    contratos = pagamentos_acompanhamento.contratos || jsonb_build_array(v_item),
    contrato_assinado = pagamentos_acompanhamento.contrato_assinado or (p_kind = 'assinado');
end;
$$;

-- Tira um contrato da lista (o app apaga o arquivo do Storage).
create or replace function public.recepcao_contrato_remover(p_gestacao_id bigint, p_path text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_dono uuid;
begin
  select dono_id into v_dono from public.recepcao_acessos where user_id = auth.uid();
  if v_dono is null then v_dono := auth.uid(); end if;
  if v_dono is null then
    raise exception 'sem acesso' using errcode = '42501';
  end if;
  update public.pagamentos_acompanhamento
     set contratos = coalesce((
           select jsonb_agg(x) from jsonb_array_elements(contratos) x where x->>'path' <> p_path
         ), '[]'::jsonb)
   where gestacao_id = p_gestacao_id and user_id = v_dono;
end;
$$;

-- Encerra o acompanhamento E grava o extrato (substitui, por sobrecarga, a versão de 2 parâmetros da 021).
create or replace function public.recepcao_encerrar(p_gestacao_id bigint, p_motivo text, p_extrato jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_dono uuid;
  v_nome text;
  v_status text;
begin
  select dono_id, nome into v_dono, v_nome from public.recepcao_acessos where user_id = auth.uid();
  if v_dono is null then
    v_dono := auth.uid();
    v_nome := 'Dra. Morgana';
  end if;
  if v_dono is null then
    raise exception 'sem acesso' using errcode = '42501';
  end if;
  v_status := case p_motivo
    when 'parto' then 'finalizada'
    when 'perda' then 'aborto'
    when 'obito' then 'obito_fetal'
    when 'desistencia' then 'desistencia'
    else null end;
  if v_status is null then raise exception 'motivo inválido'; end if;
  if p_extrato is null or octet_length(p_extrato::text) > 20000 then raise exception 'extrato inválido'; end if;
  if not exists (select 1 from public.gestacoes
                  where id = p_gestacao_id and user_id = v_dono and excluido_em is null and status = 'ativa') then
    raise exception 'gestação ativa não encontrada';
  end if;
  update public.gestacoes set status = v_status where id = p_gestacao_id;
  insert into public.pagamentos_acompanhamento (gestacao_id, user_id, encerramento, atualizado_por, atualizado_em)
  values (p_gestacao_id, v_dono, p_extrato || jsonb_build_object('por', coalesce(v_nome, ''), 'gravado_em', now()),
          coalesce(v_nome, ''), now())
  on conflict (gestacao_id) do update set
    encerramento = excluded.encerramento, atualizado_por = excluded.atualizado_por, atualizado_em = excluded.atualizado_em;
end;
$$;

-- Registro retroativo (ou correção) do extrato de uma gestação JÁ encerrada. Não muda o status.
create or replace function public.recepcao_extrato_salvar(p_gestacao_id bigint, p_extrato jsonb)
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
  if p_extrato is null or octet_length(p_extrato::text) > 20000 then raise exception 'extrato inválido'; end if;
  if not exists (select 1 from public.gestacoes
                  where id = p_gestacao_id and user_id = v_dono and excluido_em is null and status <> 'ativa') then
    raise exception 'gestação encerrada não encontrada';
  end if;
  insert into public.pagamentos_acompanhamento (gestacao_id, user_id, encerramento, atualizado_por, atualizado_em)
  values (p_gestacao_id, v_dono, p_extrato || jsonb_build_object('por', coalesce(v_nome, ''), 'gravado_em', now()),
          coalesce(v_nome, ''), now())
  on conflict (gestacao_id) do update set
    encerramento = excluded.encerramento, atualizado_por = excluded.atualizado_por, atualizado_em = excluded.atualizado_em;
end;
$$;

-- Status da devolução: pendente | escolha (desistência, paciente ainda não escolheu) |
-- devolvido | credito | nada.
create or replace function public.recepcao_devolucao(
  p_gestacao_id bigint, p_status text, p_opcao text, p_valor numeric, p_data date, p_forma text, p_obs text)
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
  if p_status not in ('pendente', 'escolha', 'devolvido', 'credito', 'nada') then
    raise exception 'status inválido';
  end if;
  if not exists (select 1 from public.pagamentos_acompanhamento
                  where gestacao_id = p_gestacao_id and user_id = v_dono and encerramento is not null) then
    raise exception 'encerramento não registrado';
  end if;
  update public.pagamentos_acompanhamento
     set encerramento = jsonb_set(encerramento, '{devolucao}', jsonb_build_object(
           'status', p_status, 'opcao', nullif(p_opcao, ''), 'valor', p_valor, 'data', p_data,
           'forma', nullif(left(coalesce(p_forma, ''), 40), ''), 'obs', left(coalesce(p_obs, ''), 500),
           'por', coalesce(v_nome, ''), 'em', now())),
         atualizado_por = coalesce(v_nome, ''), atualizado_em = now()
   where gestacao_id = p_gestacao_id and user_id = v_dono;
end;
$$;

revoke all on function public.painel_recepcao() from public, anon;
revoke all on function public.recepcao_contrato_add(bigint, text, text, text, text, numeric) from public, anon;
revoke all on function public.recepcao_contrato_remover(bigint, text) from public, anon;
revoke all on function public.recepcao_encerrar(bigint, text, jsonb) from public, anon;
revoke all on function public.recepcao_extrato_salvar(bigint, jsonb) from public, anon;
revoke all on function public.recepcao_devolucao(bigint, text, text, numeric, date, text, text) from public, anon;
grant execute on function public.painel_recepcao() to authenticated;
grant execute on function public.recepcao_contrato_add(bigint, text, text, text, text, numeric) to authenticated;
grant execute on function public.recepcao_contrato_remover(bigint, text) to authenticated;
grant execute on function public.recepcao_encerrar(bigint, text, jsonb) to authenticated;
grant execute on function public.recepcao_extrato_salvar(bigint, jsonb) to authenticated;
grant execute on function public.recepcao_devolucao(bigint, text, text, numeric, date, text, text) to authenticated;

-- 026 — Contrato arquivado/assinado e extrato do encerramento (com status da devolução).
--
-- Até aqui o contrato gerado não era guardado, "assinado" era só uma caixinha, e o extrato do
-- encerramento (valor devolvido/crédito) só existia na mensagem de WhatsApp. Agora:
--   pagamentos_acompanhamento.contratos     jsonb  lista de {path,nome,tipo,kind,por,em,valor}
--                                                  kind = 'gerado' (cópia do contrato) | 'assinado' (foto/PDF)
--   pagamentos_acompanhamento.encerramento  jsonb  extrato do encerramento + devolucao{status,...}
-- Os arquivos vão para o MESMO bucket privado `comprovantes` (023), em
-- {dono_id}/{gestacao_id}/contrato-...: as policies de lá já cobrem qualquer nome na pasta da médica.
--
-- Idempotente.
