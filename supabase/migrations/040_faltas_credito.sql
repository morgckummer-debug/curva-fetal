-- 040: falta sem reagendamento vira crédito (contrato, item 7d). 2026-10-16, pedido da Morgana.
-- pagamentos_acompanhamento.faltas jsonb = { itens: [{key,n,valor,data,validade,em,por}], usos: [{valor,data,desc,em,por}] }
-- itens = exames que a gestante perdeu (valor avulso cheio, guardado no momento do registro);
-- usos = crédito já usado em outro serviço da clínica. O app calcula o saldo e o leva ao extrato do encerramento.
alter table public.pagamentos_acompanhamento
  add column if not exists faltas jsonb;

create or replace function public.recepcao_faltas_set(p_gestacao_id bigint, p_faltas jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_dono uuid; v_nome text;
begin
  select dono_id, nome into v_dono, v_nome from public.recepcao_acessos where user_id = auth.uid();
  if v_dono is null then v_dono := auth.uid(); end if;
  if v_dono is null then raise exception 'sem acesso' using errcode = '42501'; end if;
  if not exists (select 1 from public.gestacoes where id = p_gestacao_id and user_id = v_dono and excluido_em is null) then
    raise exception 'gestação não encontrada';
  end if;
  insert into public.pagamentos_acompanhamento (gestacao_id, user_id, faltas, atualizado_por, atualizado_em)
  values (p_gestacao_id, v_dono, p_faltas, coalesce(v_nome, ''), now())
  on conflict (gestacao_id) do update set faltas = excluded.faltas;
end;
$$;

create or replace function public.recepcao_faltas()
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
  return coalesce((select jsonb_object_agg(gestacao_id::text, faltas)
                     from public.pagamentos_acompanhamento
                    where user_id = v_dono and faltas is not null), '{}'::jsonb);
end;
$$;

revoke all on function public.recepcao_faltas_set(bigint, jsonb) from public, anon;
grant execute on function public.recepcao_faltas_set(bigint, jsonb) to authenticated;
revoke all on function public.recepcao_faltas() from public, anon;
grant execute on function public.recepcao_faltas() to authenticated;

-- Histórico da ficha (038) passa a registrar as faltas e os usos do crédito.
create or replace function public._historico_pagamentos()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  k text;
  a jsonb := case when tg_op = 'INSERT' then '{}'::jsonb else to_jsonb(old) end;
  d jsonb := to_jsonb(new);
  quem text := public._historico_quem();
begin
  foreach k in array array['status','forma','parcelas','valor_pago','contrato_assinado','observacao','celular',
                           'contratos','comprovantes','trocas','encerramento','agendamento','faltas'] loop
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
