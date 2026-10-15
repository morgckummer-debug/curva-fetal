-- 038 — Histórico da ficha (2026-10-15, pedido da Morgana: "preciso estar resguardada de qualquer problema").
--
-- Registro permanente de toda alteração na ficha da recepção: conferência de pagamento, contratos,
-- comprovantes, trocas de plano, agendamento, encerramento, e plano/status/datação da gestação.
-- Gravado por TRIGGER no banco, não pelo app: vale para qualquer caminho (tela da recepção, app da
-- médica, iPad, página da paciente), e o app não tem como esquecer de registrar.
--
-- Só se acrescenta: RLS ligado e nenhuma policy de insert/update/delete; o trigger (security definer)
-- é o único que escreve. Nem a médica nem as secretárias apagam ou editam uma linha pela API.
-- Leitura só pela RPC recepcao_historico(), para a dona e as secretárias dela.

create table if not exists public.historico_ficha (
  id          bigserial primary key,
  gestacao_id bigint      not null,
  dono_id     uuid        not null,
  em          timestamptz not null default now(),
  por         text        not null default '',
  campo       text        not null,
  antes       jsonb,
  depois      jsonb
);
create index if not exists historico_ficha_gest_idx on public.historico_ficha (gestacao_id, em desc);
alter table public.historico_ficha enable row level security;
revoke all on public.historico_ficha from anon, authenticated;

-- Quem fez: e-mail do login; sem login, foi a gestante (iPad da vitrine ou página do agendamento).
create or replace function public._historico_quem()
returns text language sql security definer set search_path = public, auth stable as $$
  select coalesce((select u.email from auth.users u where u.id = auth.uid()),
                  case when auth.role() = 'anon' then 'Gestante (iPad / link, sem login)' else 'Sistema (alteração direta no banco)' end);
$$;

create or replace function public._historico_pagamentos()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  k text;
  a jsonb := case when tg_op = 'INSERT' then '{}'::jsonb else to_jsonb(old) end;
  d jsonb := to_jsonb(new);
  quem text := public._historico_quem();
begin
  -- agenda_link e atualizado_* mudam junto com outros campos e não dizem nada por si.
  foreach k in array array['status','forma','parcelas','valor_pago','contrato_assinado','observacao','celular',
                           'contratos','comprovantes','trocas','encerramento','agendamento'] loop
    if (a -> k) is distinct from (d -> k)
       and not (tg_op = 'INSERT' and (d -> k) in ('null'::jsonb, '[]'::jsonb, '""'::jsonb, 'false'::jsonb)
                and k <> 'status') then
      insert into public.historico_ficha (gestacao_id, dono_id, por, campo, antes, depois)
      values (new.gestacao_id, new.user_id, quem, k, a -> k, d -> k);
    end if;
  end loop;
  return null;
end;
$$;

drop trigger if exists historico_pagamentos on public.pagamentos_acompanhamento;
create trigger historico_pagamentos after insert or update on public.pagamentos_acompanhamento
  for each row execute function public._historico_pagamentos();

-- Gestação: só os campos que importam para o contrato. O saveDB da médica reescreve a tabela inteira,
-- mas linha sem mudança real não gera registro (is distinct from).
create or replace function public._historico_gestacoes()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  k text;
  a jsonb := case when tg_op = 'INSERT' then '{}'::jsonb else to_jsonb(old) end;
  d jsonb := to_jsonb(new);
  quem text := public._historico_quem();
begin
  if tg_op = 'INSERT' and new.acompanhamento is null then return null; end if;
  foreach k in array array['acompanhamento','status','dum','ig_base_data','ig_base_valor','excluido_em'] loop
    if (a -> k) is distinct from (d -> k) and not (tg_op = 'INSERT' and (d -> k) = 'null'::jsonb) then
      insert into public.historico_ficha (gestacao_id, dono_id, por, campo, antes, depois)
      values (new.id, new.user_id, quem, 'gestacao.' || k, a -> k, d -> k);
    end if;
  end loop;
  return null;
end;
$$;

drop trigger if exists historico_gestacoes on public.gestacoes;
create trigger historico_gestacoes after insert or update on public.gestacoes
  for each row execute function public._historico_gestacoes();

create or replace function public.recepcao_historico(p_gestacao_id bigint)
returns jsonb language plpgsql security definer set search_path = public stable as $$
declare v_dono uuid;
begin
  select dono_id into v_dono from public.recepcao_acessos where user_id = auth.uid();
  if v_dono is null then v_dono := auth.uid(); end if;
  if v_dono is null then raise exception 'sem acesso' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('em', h.em, 'por', h.por, 'campo', h.campo, 'antes', h.antes, 'depois', h.depois)
                     order by h.em desc, h.id desc)
      from public.historico_ficha h
     where h.gestacao_id = p_gestacao_id and h.dono_id = v_dono), '[]'::jsonb);
end;
$$;

revoke all on function public.recepcao_historico(bigint) from public, anon;
grant execute on function public.recepcao_historico(bigint) to authenticated;
revoke all on function public._historico_quem() from public, anon, authenticated;
