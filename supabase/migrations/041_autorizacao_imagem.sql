-- 041: autorização de uso de imagens 3D do bebê (contrato, item 10). 2026-10-16, pedido da Morgana.
-- pagamentos_acompanhamento.imagem jsonb =
--   { autoriza: bool, em, origem: 'contrato'|'contrato_ipad', por,
--     revogada_em?, revogada_por?, revogada_via? }
-- Gravada quando a gestante assina o contrato (na tela ou no iPad). Revogar só muda para "não autoriza";
-- o Histórico da ficha (038) guarda o valor anterior.
alter table public.pagamentos_acompanhamento
  add column if not exists imagem jsonb;

create or replace function public.recepcao_imagem_set(p_gestacao_id bigint, p_imagem jsonb)
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
  insert into public.pagamentos_acompanhamento (gestacao_id, user_id, imagem, atualizado_por, atualizado_em)
  values (p_gestacao_id, v_dono, p_imagem, coalesce(v_nome, ''), now())
  on conflict (gestacao_id) do update set imagem = excluded.imagem;
end;
$$;

create or replace function public.recepcao_imagens()
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
  return coalesce((select jsonb_object_agg(gestacao_id::text, imagem)
                     from public.pagamentos_acompanhamento
                    where user_id = v_dono and imagem is not null), '{}'::jsonb);
end;
$$;

revoke all on function public.recepcao_imagem_set(bigint, jsonb) from public, anon;
grant execute on function public.recepcao_imagem_set(bigint, jsonb) to authenticated;
revoke all on function public.recepcao_imagens() from public, anon;
grant execute on function public.recepcao_imagens() to authenticated;

-- iPad da vitrine: a assinatura passa a levar a escolha ('sim'/'nao'). Parâmetro com default para a
-- página antiga (em cache no iPad) continuar assinando; a antiga, de 3 parâmetros, sai para não ficar ambígua.
drop function if exists public.vitrine_assinatura_salvar(text, bigint, text);
create or replace function public.vitrine_assinatura_salvar(p_token text, p_id bigint, p_html text, p_imagem text default null)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare v_dono uuid; c public.contratos_ipad%rowtype; v_item jsonb; v_termo boolean; v_img jsonb;
begin
  if coalesce(length(p_token), 0) < 32 then raise exception 'chave inválida'; end if;
  select dono_id into v_dono from public.vitrine_chaves where token_assinatura = p_token;
  if v_dono is null then raise exception 'chave inválida'; end if;
  if p_html is null or length(p_html) > 3500000 then raise exception 'documento inválido'; end if;
  select * into c from public.contratos_ipad
   where id = p_id and dono_id = v_dono and status = 'pendente' and criado_em > now() - interval '7 days'
   for update;
  if c.id is null then raise exception 'documento não encontrado ou já assinado'; end if;
  v_termo := c.nome like 'Termo aditivo%';
  update public.contratos_ipad set status = 'assinado', assinado_em = now(), html_assinado = p_html where id = c.id;
  v_item := jsonb_build_object('path', 'ipad:' || c.id,
              'nome', case when v_termo then replace(c.nome, 'Termo aditivo', 'Termo aditivo assinado no iPad') else 'Contrato assinado no iPad' end,
              'tipo', 'text/html', 'kind', 'assinado', 'valor', c.valor, 'por', 'iPad da recepção', 'em', now());
  if not v_termo and p_imagem in ('sim', 'nao') then
    v_img := jsonb_build_object('autoriza', p_imagem = 'sim', 'em', now(), 'origem', 'contrato_ipad', 'por', 'Gestante (iPad)');
  end if;
  insert into public.pagamentos_acompanhamento
    (gestacao_id, user_id, contratos, contrato_assinado, imagem, atualizado_por, atualizado_em)
  values (c.gestacao_id, v_dono, jsonb_build_array(v_item), true, v_img, 'iPad da recepção', now())
  on conflict (gestacao_id) do update set
    contratos = coalesce(pagamentos_acompanhamento.contratos, '[]'::jsonb) || jsonb_build_array(v_item),
    contrato_assinado = true,
    imagem = coalesce(v_img, pagamentos_acompanhamento.imagem);
  return true;
end;
$$;
revoke all on function public.vitrine_assinatura_salvar(text, bigint, text, text) from public;
grant execute on function public.vitrine_assinatura_salvar(text, bigint, text, text) to anon, authenticated;

-- Histórico da ficha (038) passa a registrar a autorização de imagem e a revogação.
create or replace function public._historico_pagamentos()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  k text;
  a jsonb := case when tg_op = 'INSERT' then '{}'::jsonb else to_jsonb(old) end;
  d jsonb := to_jsonb(new);
  quem text := public._historico_quem();
begin
  foreach k in array array['status','forma','parcelas','valor_pago','contrato_assinado','observacao','celular',
                           'contratos','comprovantes','trocas','encerramento','agendamento','faltas','imagem'] loop
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
