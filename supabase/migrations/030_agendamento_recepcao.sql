-- 030: etiqueta de agendamento na recepção. Quando a mensagem "Combinar datas" é enviada, a ficha fica
-- "Aguardando resposta" (com a data); "Confirmar agendamento" muda para "Agendado".
alter table public.pagamentos_acompanhamento
  add column if not exists agendamento jsonb;

create or replace function public.recepcao_agendamento_set(p_gestacao_id bigint, p_estado text, p_slots text[])
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_dono uuid; v_nome text; v_ag jsonb;
begin
  select dono_id, nome into v_dono, v_nome from public.recepcao_acessos where user_id = auth.uid();
  if v_dono is null then v_dono := auth.uid(); end if;
  if v_dono is null then raise exception 'sem acesso' using errcode = '42501'; end if;
  if p_estado not in ('aguardando','agendado') then raise exception 'estado inválido'; end if;
  if not exists (select 1 from public.gestacoes where id = p_gestacao_id and user_id = v_dono and excluido_em is null) then
    raise exception 'gestação não encontrada';
  end if;
  v_ag := jsonb_build_object('estado', p_estado, 'desde', now(), 'slots', to_jsonb(coalesce(p_slots, '{}'::text[])), 'por', coalesce(v_nome, ''));
  insert into public.pagamentos_acompanhamento (gestacao_id, user_id, agendamento, atualizado_por, atualizado_em)
  values (p_gestacao_id, v_dono, v_ag, coalesce(v_nome, ''), now())
  on conflict (gestacao_id) do update set agendamento = v_ag;
end;
$$;

create or replace function public.recepcao_agendamentos()
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
  return coalesce((select jsonb_object_agg(gestacao_id::text, agendamento)
                     from public.pagamentos_acompanhamento
                    where user_id = v_dono and agendamento is not null), '{}'::jsonb);
end;
$$;

revoke all on function public.recepcao_agendamento_set(bigint, text, text[]) from public, anon;
grant execute on function public.recepcao_agendamento_set(bigint, text, text[]) to authenticated;
revoke all on function public.recepcao_agendamentos() from public, anon;
grant execute on function public.recepcao_agendamentos() to authenticated;
