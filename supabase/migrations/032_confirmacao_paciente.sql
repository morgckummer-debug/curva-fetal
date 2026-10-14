-- 032: depois de marcar na Feegow, a recepção manda à paciente o mesmo link pessoal: ela vê dia e hora de cada
-- exame e toca em "Confirmo". A ficha mostra "Paciente confirmou".

-- Recepção/médica: guarda os dias e horários marcados (junto do agendamento 'agendado') e devolve o código.
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

-- Paciente (anônima): vê também o que foi marcado e se já confirmou.
create or replace function public.agenda_publica(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
stable
as $$
declare v_link jsonb; v_ag jsonb;
begin
  if p_token is null or length(p_token) < 32 then return null; end if;
  select agenda_link, agendamento into v_link, v_ag
    from public.pagamentos_acompanhamento where agenda_link->>'token' = p_token;
  if v_link is null then return null; end if;
  return jsonb_build_object('nome', v_link->'nome', 'exames', v_link->'exames',
                            'resposta', case when v_ag->>'estado' = 'respondeu' then v_ag->'resposta' else null end,
                            'agendado', (v_ag->>'estado' = 'agendado'),
                            'agendados', case when v_ag->>'estado' = 'agendado' then v_ag->'agendados' else null end,
                            'confirmada', case when v_ag->>'estado' = 'agendado' then v_ag->'confirmada' else null end);
end;
$$;

-- Paciente (anônima): "Confirmo".
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
   where agenda_link->>'token' = p_token and agendamento->>'estado' = 'agendado' and agendamento ? 'agendados';
  return found;
end;
$$;

revoke all on function public.recepcao_agendamento_horarios(bigint, text, jsonb) from public, anon;
grant execute on function public.recepcao_agendamento_horarios(bigint, text, jsonb) to authenticated;
revoke all on function public.agenda_publica(text) from public;
grant execute on function public.agenda_publica(text) to anon, authenticated;
revoke all on function public.agenda_confirmar(text) from public;
grant execute on function public.agenda_confirmar(text) to anon, authenticated;
