-- 039: agendamento só depois de contrato assinado E pagamento confirmado (Morgana, 2026-10-16).
-- A tela da recepção já bloqueia "Combinar datas" e "Confirmar agendamento"; aqui o servidor recusa também,
-- e o link pessoal da paciente (agendar.html) gerado antes disso deixa de aceitar datas até liberar.

create or replace function public._agenda_liberada(p_gestacao_id bigint)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select coalesce((select pa.status = 'quitado'
                      and (coalesce(pa.contrato_assinado, false)
                           or exists (select 1 from jsonb_array_elements(coalesce(pa.contratos, '[]'::jsonb)) e
                                       where e->>'kind' = 'assinado'))
                     from public.pagamentos_acompanhamento pa where pa.gestacao_id = p_gestacao_id), false);
$$;
revoke all on function public._agenda_liberada(bigint) from public, anon, authenticated;

-- Recepção: mesma 031, recusando antes de liberar.
create or replace function public.recepcao_agenda_link(p_gestacao_id bigint, p_nome text, p_exames jsonb)
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
  if jsonb_typeof(p_exames) <> 'array' or jsonb_array_length(p_exames) = 0 then
    raise exception 'sem exames';
  end if;
  select agenda_link->>'token' into v_tok from public.pagamentos_acompanhamento where gestacao_id = p_gestacao_id;
  if v_tok is null then
    v_tok := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
  end if;
  insert into public.pagamentos_acompanhamento (gestacao_id, user_id, agenda_link, atualizado_por, atualizado_em)
  values (p_gestacao_id, v_dono, jsonb_build_object('token', v_tok, 'nome', left(coalesce(p_nome, ''), 60), 'exames', p_exames, 'criado', now()), coalesce(v_nome, ''), now())
  on conflict (gestacao_id) do update
    set agenda_link = jsonb_build_object('token', v_tok, 'nome', left(coalesce(p_nome, ''), 60), 'exames', p_exames, 'criado', now());
  return v_tok;
end;
$$;

-- Recepção: mesma 032, recusando antes de liberar.
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
     set agendamento = coalesce(agendamento, '{}'::jsonb) || jsonb_build_object('estado', 'agendado', 'agendados', p_itens, 'confirmada', null)
   where gestacao_id = p_gestacao_id;
  return v_tok;
end;
$$;

-- Paciente: mesma 036; antes de liberar devolve só o primeiro nome e liberado = false.
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
                            'bloqueados', v_bloq);
end;
$$;

-- Paciente: mesma 036, recusando antes de liberar.
create or replace function public.agenda_responder(p_token text, p_prefs jsonb, p_obs text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_gid bigint; v_link jsonb; v_ex jsonb; v_pref jsonb; v_d jsonb; v_dono uuid;
  v_out jsonb := '[]'::jsonb; v_datas jsonb; v_keys text[] := '{}'; v_de text; v_ate text; v_n int;
begin
  if p_token is null or length(p_token) < 32 then return false; end if;
  select gestacao_id, agenda_link, user_id into v_gid, v_link, v_dono from public.pagamentos_acompanhamento where agenda_link->>'token' = p_token;
  if v_gid is null then return false; end if;
  if not public._agenda_liberada(v_gid) then raise exception 'agendamento ainda não liberado'; end if;
  if jsonb_typeof(p_prefs) <> 'array' then raise exception 'formato inválido'; end if;
  for v_pref in select * from jsonb_array_elements(p_prefs) loop
    select e into v_ex from jsonb_array_elements(v_link->'exames') e where e->>'key' = v_pref->>'key';
    if v_ex is null then raise exception 'exame inválido'; end if;
    v_de := v_ex->>'de'; v_ate := v_ex->>'ate'; v_datas := '[]'::jsonb; v_n := 0;
    for v_d in select * from jsonb_array_elements(coalesce(v_pref->'datas', '[]'::jsonb)) loop
      v_n := v_n + 1;
      exit when v_n > 3;
      if (v_d->>'d') !~ '^\d{4}-\d{2}-\d{2}$' or (v_d->>'d') < v_de or (v_d->>'d') > v_ate then
        raise exception 'data fora do período';
      end if;
      if extract(dow from (v_d->>'d')::date) = 0
         or exists (select 1 from public.ausencias a where a.user_id = v_dono and (v_d->>'d')::date between a.inicio and a.fim) then
        raise exception 'dia sem atendimento';
      end if;
      v_datas := v_datas || jsonb_build_array(jsonb_build_object('d', v_d->>'d',
                   'p', case when v_d->>'p' in ('manha','tarde') then v_d->>'p' else 'qualquer' end));
    end loop;
    if jsonb_array_length(v_datas) > 0 then
      v_out := v_out || jsonb_build_array(jsonb_build_object('key', v_ex->>'key', 'n', v_ex->>'n', 'datas', v_datas));
      v_keys := v_keys || (v_ex->>'key');
    end if;
  end loop;
  if jsonb_array_length(v_out) = 0 then raise exception 'sem datas'; end if;
  update public.pagamentos_acompanhamento
     set agendamento = jsonb_build_object('estado', 'respondeu', 'desde', now(), 'slots', to_jsonb(v_keys), 'por', 'paciente',
                                          'resposta', jsonb_build_object('prefs', v_out, 'obs', left(coalesce(p_obs, ''), 300)))
   where gestacao_id = v_gid;
  return true;
end;
$$;

-- Paciente: "Confirmo" (mesma 032), recusando antes de liberar.
create or replace function public.agenda_confirmar(p_token text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_token is null or length(p_token) < 32 then return false; end if;
  update public.pagamentos_acompanhamento
     set agendamento = agendamento || jsonb_build_object('confirmada', now())
   where agenda_link->>'token' = p_token and agendamento->>'estado' = 'agendado' and agendamento ? 'agendados'
     and public._agenda_liberada(gestacao_id);
  return found;
end;
$$;

revoke all on function public.recepcao_agenda_link(bigint, text, jsonb) from public, anon;
grant execute on function public.recepcao_agenda_link(bigint, text, jsonb) to authenticated;
revoke all on function public.recepcao_agendamento_horarios(bigint, text, jsonb) from public, anon;
grant execute on function public.recepcao_agendamento_horarios(bigint, text, jsonb) to authenticated;
revoke all on function public.agenda_publica(text) from public;
grant execute on function public.agenda_publica(text) to anon, authenticated;
revoke all on function public.agenda_responder(text, jsonb, text) from public;
grant execute on function public.agenda_responder(text, jsonb, text) to anon, authenticated;
revoke all on function public.agenda_confirmar(text) from public;
grant execute on function public.agenda_confirmar(text) to anon, authenticated;
