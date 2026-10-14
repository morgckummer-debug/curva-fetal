-- 036: dias em que a médica não atende (recesso, congresso, folga). A página agendar.html
-- tira esses dias da lista que a gestante vê, e agenda_responder recusa data dentro deles.
-- Só a dona cadastra (RLS por auth.uid()); a gestante recebe só as datas, nunca o motivo.
create table if not exists public.ausencias (
  id bigint generated always as identity primary key,
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  inicio date not null,
  fim date not null,
  motivo text,
  criado_em timestamptz not null default now(),
  constraint ausencias_periodo_ck check (fim >= inicio)
);
create index if not exists ausencias_user_idx on public.ausencias (user_id, fim);
alter table public.ausencias enable row level security;
drop policy if exists ausencias_select on public.ausencias;
drop policy if exists ausencias_insert on public.ausencias;
drop policy if exists ausencias_update on public.ausencias;
drop policy if exists ausencias_delete on public.ausencias;
create policy ausencias_select on public.ausencias for select to authenticated using (user_id = auth.uid());
create policy ausencias_insert on public.ausencias for insert to authenticated with check (user_id = auth.uid());
create policy ausencias_update on public.ausencias for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy ausencias_delete on public.ausencias for delete to authenticated using (user_id = auth.uid());

-- Mesma agenda_publica da 032, mais 'bloqueados': [{de, ate}] das ausências da dona que ainda não acabaram.
create or replace function public.agenda_publica(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
stable
as $$
declare v_link jsonb; v_ag jsonb; v_dono uuid; v_bloq jsonb;
begin
  if p_token is null or length(p_token) < 32 then return null; end if;
  select agenda_link, agendamento, user_id into v_link, v_ag, v_dono
    from public.pagamentos_acompanhamento where agenda_link->>'token' = p_token;
  if v_link is null then return null; end if;
  select coalesce(jsonb_agg(jsonb_build_object('de', inicio, 'ate', fim) order by inicio), '[]'::jsonb)
    into v_bloq from public.ausencias where user_id = v_dono and fim >= current_date;
  return jsonb_build_object('nome', v_link->'nome', 'exames', v_link->'exames',
                            'resposta', case when v_ag->>'estado' = 'respondeu' then v_ag->'resposta' else null end,
                            'agendado', (v_ag->>'estado' = 'agendado'),
                            'agendados', case when v_ag->>'estado' = 'agendado' then v_ag->'agendados' else null end,
                            'confirmada', case when v_ag->>'estado' = 'agendado' then v_ag->'confirmada' else null end,
                            'bloqueados', v_bloq);
end;
$$;

-- Mesma agenda_responder da 031, recusando domingo e dia de ausência.
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

revoke all on function public.agenda_publica(text) from public;
grant execute on function public.agenda_publica(text) to anon, authenticated;
revoke all on function public.agenda_responder(text, jsonb, text) from public;
grant execute on function public.agenda_responder(text, jsonb, text) to anon, authenticated;
