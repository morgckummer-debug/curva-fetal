-- 044: reagendar UM exame já agendado (Morgana, 2026-10-21). A recepção escolhe o exame, digita a nova data e
-- hora (já trocadas na Feegow) e manda o link pessoal de sempre. A data só muda no app quando a gestante toca
-- em "Confirmo" no link; até lá fica em agendamento.reagendamento e a data antiga continua valendo.
-- Ao confirmar, o item de agendamento.agendados ganha a data nova e 'r' (quando foi reagendado).

-- Recepção/médica: guarda o reagendamento pendente e devolve o código do link.
create or replace function public.recepcao_reagendar(p_gestacao_id bigint, p_key text, p_d text, p_h text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare v_dono uuid; v_nome text; v_tok text; v_ag jsonb; v_it jsonb;
begin
  select dono_id, nome into v_dono, v_nome from public.recepcao_acessos where user_id = auth.uid();
  if v_dono is null then v_dono := auth.uid(); end if;
  if v_dono is null then raise exception 'sem acesso' using errcode = '42501'; end if;
  if not exists (select 1 from public.gestacoes where id = p_gestacao_id and user_id = v_dono and excluido_em is null) then
    raise exception 'gestação não encontrada';
  end if;
  if not public._agenda_liberada(p_gestacao_id) then
    raise exception 'Contrato não assinado ou pagamento não confirmado';
  end if;
  if p_d !~ '^\d{4}-\d{2}-\d{2}$' or p_h !~ '^\d{2}:\d{2}$' then raise exception 'data ou horário inválido'; end if;
  if extract(dow from p_d::date) = 0 then raise exception 'domingo a clínica não abre'; end if;
  if extract(dow from p_d::date) = 6 and p_h > '12:00' then raise exception 'sábado só até 12h'; end if;
  if exists (select 1 from public.ausencias a where a.user_id = v_dono and p_d::date between a.inicio and a.fim) then
    raise exception 'a médica está ausente nesse dia';
  end if;
  select agenda_link->>'token', agendamento into v_tok, v_ag from public.pagamentos_acompanhamento where gestacao_id = p_gestacao_id;
  if v_tok is null or v_ag->>'estado' <> 'agendado' then raise exception 'exame ainda não agendado'; end if;
  select e into v_it from jsonb_array_elements(coalesce(v_ag->'agendados', '[]'::jsonb)) e where e->>'key' = p_key;
  if v_it is null then raise exception 'exame ainda não agendado'; end if;
  update public.pagamentos_acompanhamento
     set agendamento = agendamento || jsonb_build_object('reagendamento', jsonb_build_object(
           'key', p_key, 'n', v_it->'n', 'd', p_d, 'h', p_h, 'de', v_it->'d', 'deh', v_it->'h', 'em', now(), 'por', coalesce(v_nome, '')))
   where gestacao_id = p_gestacao_id;
  return v_tok;
end;
$$;

-- Mesma 039; "Alterar horários" reescreve a agenda inteira e descarta um reagendamento pendente.
create or replace function public.recepcao_agendamento_horarios(p_gestacao_id bigint, p_nome text, p_itens jsonb)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare v_dono uuid; v_nome text; v_tok text;
begin
  select dono_id, nome into v_dono, v_nome from public.recepcao_acessos where user_id = auth.uid();
  if v_dono is null then v_dono := auth.uid(); end if;
  if v_dono is null then raise exception 'sem acesso' using errcode = '42501'; end if;
  if not exists (select 1 from public.gestacoes where id = p_gestacao_id and user_id = v_dono and excluido_em is null) then
    raise exception 'gestação não encontrada';
  end if;
  if not public._agenda_liberada(p_gestacao_id) then
    raise exception 'Contrato não assinado ou pagamento não confirmado';
  end if;
  if jsonb_typeof(p_itens) <> 'array' or jsonb_array_length(p_itens) = 0 then raise exception 'sem exames'; end if;
  select agenda_link->>'token' into v_tok from public.pagamentos_acompanhamento where gestacao_id = p_gestacao_id;
  if v_tok is null then
    v_tok := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
    update public.pagamentos_acompanhamento
       set agenda_link = jsonb_build_object('token', v_tok, 'nome', left(coalesce(p_nome, ''), 60), 'exames', '[]'::jsonb, 'criado', now())
     where gestacao_id = p_gestacao_id;
  end if;
  update public.pagamentos_acompanhamento
     set agendamento = (coalesce(agendamento, '{}'::jsonb) - 'reagendamento') || jsonb_build_object('estado', 'agendado', 'agendados', p_itens, 'confirmada', null)
   where gestacao_id = p_gestacao_id;
  return v_tok;
end;
$$;

-- Paciente: mesma 039, mais 'reagendamento' (o pendente, se houver).
create or replace function public.agenda_publica(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
stable
as $$
declare v_link jsonb; v_ag jsonb; v_dono uuid; v_bloq jsonb; v_gid bigint;
begin
  if p_token is null or length(p_token) < 32 then return null; end if;
  select agenda_link, agendamento, user_id, gestacao_id into v_link, v_ag, v_dono, v_gid
    from public.pagamentos_acompanhamento where agenda_link->>'token' = p_token;
  if v_link is null then return null; end if;
  if not public._agenda_liberada(v_gid) then
    return jsonb_build_object('nome', v_link->'nome', 'liberado', false);
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('de', inicio, 'ate', fim) order by inicio), '[]'::jsonb)
    into v_bloq from public.ausencias where user_id = v_dono and fim >= current_date;
  return jsonb_build_object('nome', v_link->'nome', 'exames', v_link->'exames', 'liberado', true,
                            'resposta', case when v_ag->>'estado' = 'respondeu' then v_ag->'resposta' else null end,
                            'agendado', (v_ag->>'estado' = 'agendado'),
                            'agendados', case when v_ag->>'estado' = 'agendado' then v_ag->'agendados' else null end,
                            'confirmada', case when v_ag->>'estado' = 'agendado' then v_ag->'confirmada' else null end,
                            'reagendamento', case when v_ag->>'estado' = 'agendado' then v_ag->'reagendamento' else null end,
                            'bloqueados', v_bloq);
end;
$$;

-- Paciente: "Confirmo". Com reagendamento pendente, confirma só ele: troca a data do exame e marca 'r'.
create or replace function public.agenda_confirmar(p_token text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare v_gid bigint; v_ag jsonb; v_rg jsonb; v_novos jsonb;
begin
  if p_token is null or length(p_token) < 32 then return false; end if;
  select gestacao_id, agendamento into v_gid, v_ag from public.pagamentos_acompanhamento
   where agenda_link->>'token' = p_token and agendamento->>'estado' = 'agendado' and agendamento ? 'agendados'
     and public._agenda_liberada(gestacao_id);
  if v_gid is null then return false; end if;
  v_rg := v_ag->'reagendamento';
  if v_rg is null or jsonb_typeof(v_rg) <> 'object' then
    update public.pagamentos_acompanhamento set agendamento = agendamento || jsonb_build_object('confirmada', now())
     where gestacao_id = v_gid;
    return true;
  end if;
  select coalesce(jsonb_agg(case when e->>'key' = v_rg->>'key'
                                 then e || jsonb_build_object('d', v_rg->'d', 'h', v_rg->'h', 'r', now())
                                 else e end order by o), '[]'::jsonb)
    into v_novos from jsonb_array_elements(v_ag->'agendados') with ordinality t(e, o);
  update public.pagamentos_acompanhamento
     set agendamento = (agendamento - 'reagendamento') || jsonb_build_object('agendados', v_novos)
   where gestacao_id = v_gid;
  return true;
end;
$$;

revoke all on function public.recepcao_reagendar(bigint, text, text, text) from public, anon;
grant execute on function public.recepcao_reagendar(bigint, text, text, text) to authenticated;
revoke all on function public.recepcao_agendamento_horarios(bigint, text, jsonb) from public, anon;
grant execute on function public.recepcao_agendamento_horarios(bigint, text, jsonb) to authenticated;
revoke all on function public.agenda_publica(text) from public;
grant execute on function public.agenda_publica(text) to anon, authenticated;
revoke all on function public.agenda_confirmar(text) from public;
grant execute on function public.agenda_confirmar(text) to anon, authenticated;
