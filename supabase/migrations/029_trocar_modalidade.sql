-- 029: troca de modalidade (upgrade/downgrade, contrato item 9). A recepção não escreve em gestacoes;
-- esta função troca gestacoes.acompanhamento e guarda o registro da troca em pagamentos_acompanhamento.trocas.
alter table public.pagamentos_acompanhamento
  add column if not exists trocas jsonb not null default '[]'::jsonb;

create or replace function public.recepcao_trocar_modalidade(p_gestacao_id bigint, p_nova text, p_registro jsonb)
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
  if v_dono is null then v_dono := auth.uid(); end if;
  if v_dono is null then
    raise exception 'sem acesso' using errcode = '42501';
  end if;
  if p_nova not in ('essencial','premium','gemelar_essencial','gemelar_dc') then
    raise exception 'modalidade inválida';
  end if;
  if not exists (select 1 from public.gestacoes
                  where id = p_gestacao_id and user_id = v_dono and excluido_em is null and status = 'ativa'
                    and acompanhamento is not null and acompanhamento <> p_nova) then
    raise exception 'gestação ativa com plano diferente não encontrada';
  end if;
  update public.gestacoes set acompanhamento = p_nova where id = p_gestacao_id;
  insert into public.pagamentos_acompanhamento (gestacao_id, user_id, trocas, atualizado_por, atualizado_em)
  values (p_gestacao_id, v_dono,
          jsonb_build_array(coalesce(p_registro, '{}'::jsonb) || jsonb_build_object('por', coalesce(v_nome, ''), 'em', now())),
          coalesce(v_nome, ''), now())
  on conflict (gestacao_id) do update set
    trocas = pagamentos_acompanhamento.trocas
             || jsonb_build_array(coalesce(p_registro, '{}'::jsonb) || jsonb_build_object('por', coalesce(v_nome, ''), 'em', now()));
end;
$$;

revoke all on function public.recepcao_trocar_modalidade(bigint, text, jsonb) from public, anon;
grant execute on function public.recepcao_trocar_modalidade(bigint, text, jsonb) to authenticated;
