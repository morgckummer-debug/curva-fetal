-- 031: link pessoal para a paciente escolher as datas do próximo exame (página agendar.html, sem login).
-- A recepção gera o link ao "Combinar datas"; a resposta da paciente cai na ficha como "Respondeu".
alter table public.pagamentos_acompanhamento
  add column if not exists agenda_link jsonb;

create unique index if not exists pagamentos_agenda_token_uq
  on public.pagamentos_acompanhamento ((agenda_link->>'token'));

-- Recepção/médica: cria (ou reaproveita) o código da paciente e grava os exames/janelas que o link vai mostrar.
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

-- Paciente (anônima): lê só o primeiro nome, os exames com janela e a resposta anterior (se houver).
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
                            'agendado', (v_ag->>'estado' = 'agendado'));
end;
$$;

-- Paciente (anônima): grava as preferências. p_prefs = [{"key":"d28","datas":[{"d":"2026-11-03","p":"manha"}]}]
create or replace function public.agenda_responder(p_token text, p_prefs jsonb, p_obs text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_gid bigint; v_link jsonb; v_ex jsonb; v_pref jsonb; v_d jsonb;
  v_out jsonb := '[]'::jsonb; v_datas jsonb; v_keys text[] := '{}'; v_de text; v_ate text; v_n int;
begin
  if p_token is null or length(p_token) < 32 then return false; end if;
  select gestacao_id, agenda_link into v_gid, v_link from public.pagamentos_acompanhamento where agenda_link->>'token' = p_token;
  if v_gid is null then return false; end if;
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

revoke all on function public.recepcao_agenda_link(bigint, text, jsonb) from public, anon;
grant execute on function public.recepcao_agenda_link(bigint, text, jsonb) to authenticated;
revoke all on function public.agenda_publica(text) from public;
grant execute on function public.agenda_publica(text) to anon, authenticated;
revoke all on function public.agenda_responder(text, jsonb, text) from public;
grant execute on function public.agenda_responder(text, jsonb, text) to anon, authenticated;
