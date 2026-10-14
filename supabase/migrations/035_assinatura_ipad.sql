-- 035 — Assinatura do contrato no iPad da vitrine (2026-10-14, pedido da Morgana).
--
-- A secretária confere os dados e gera o contrato no computador; a gestante assina no iPad da
-- vitrine (vitrine.html, sem login). No iPad a secretária digita nome ou CPF, acha o contrato que
-- está esperando assinatura e toca em "Assinar na tela".
--
-- O iPad não lê o Storage (bucket privado, só com login). Por isso, ao arquivar um contrato gerado,
-- o app também guarda uma cópia do HTML aqui (contratos_ipad), com a assinatura da clínica já
-- embutida. A cópia assinada também fica aqui, e entra na ficha como contrato assinado com
-- path = 'ipad:<id>' (o app sabe abrir esse caminho por recepcao_contrato_ipad_html).
--
-- A chave do iPad que assina (vitrine_chaves.token_assinatura) é OUTRA que a chave da vitrine (?k=),
-- porque a chave da vitrine também vai no link "de casa" mandado pelo WhatsApp: quem tem o link de
-- casa não pode buscar contratos. Só o endereço do iPad (…&a=<token>) leva esta.
--
-- Idempotente.

alter table public.vitrine_chaves add column if not exists token_assinatura text;
create unique index if not exists vitrine_chaves_tokass_uq on public.vitrine_chaves (token_assinatura);

create table if not exists public.contratos_ipad (
  id            bigserial primary key,
  dono_id       uuid not null references auth.users(id) on delete cascade,
  gestacao_id   bigint not null,
  path          text not null,            -- cópia gerada no Storage
  nome          text not null default '', -- 'Contrato gerado' | 'Termo aditivo · …'
  valor         numeric,
  html          text not null,
  clinica_img   text,                     -- assinatura da clínica (data: PNG), se guardada
  gerado_por    text not null default '',
  status        text not null default 'pendente' check (status in ('pendente','assinado','substituido')),
  criado_em     timestamptz not null default now(),
  assinado_em   timestamptz,
  html_assinado text
);
create index if not exists contratos_ipad_dono_status on public.contratos_ipad (dono_id, status);
alter table public.contratos_ipad enable row level security; -- sem policy: só pelas funções abaixo

-- Recepção/médica: devolve (criando se preciso) a chave do iPad que assina.
create or replace function public.recepcao_vitrine_assinatura_token()
returns text
language plpgsql
security definer
set search_path = public
as $$
declare v_dono uuid; v_tok text;
begin
  select dono_id into v_dono from public.recepcao_acessos where user_id = auth.uid();
  if v_dono is null then v_dono := auth.uid(); end if;
  if v_dono is null then raise exception 'sem acesso' using errcode = '42501'; end if;
  perform public.recepcao_vitrine_chave(); -- garante a linha da clínica
  select token_assinatura into v_tok from public.vitrine_chaves where dono_id = v_dono;
  if v_tok is null then
    v_tok := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
    update public.vitrine_chaves set token_assinatura = v_tok where dono_id = v_dono;
  end if;
  return v_tok;
end;
$$;

-- Recepção/médica: deixa um contrato recém-gerado disponível para assinar no iPad.
-- Uma via nova substitui a anterior do mesmo tipo (contrato ou termo aditivo) da mesma gestação.
create or replace function public.recepcao_contrato_ipad(
  p_gestacao_id bigint, p_path text, p_nome text, p_valor numeric, p_html text, p_clinica_img text default null)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare v_dono uuid; v_nome text; v_id bigint; v_termo boolean := coalesce(p_nome, '') like 'Termo aditivo%';
begin
  select dono_id, nome into v_dono, v_nome from public.recepcao_acessos where user_id = auth.uid();
  if v_dono is null then v_dono := auth.uid(); v_nome := 'Dra. Morgana'; end if;
  if v_dono is null then raise exception 'sem acesso' using errcode = '42501'; end if;
  if not exists (select 1 from public.gestacoes where id = p_gestacao_id and user_id = v_dono and excluido_em is null) then
    raise exception 'gestação não encontrada';
  end if;
  if p_path is null or p_path not like v_dono::text || '/' || p_gestacao_id::text || '/%' then
    raise exception 'caminho inválido';
  end if;
  if p_html is null or length(p_html) > 3000000 then raise exception 'documento inválido'; end if;
  if p_clinica_img is not null and (p_clinica_img not like 'data:image/png;base64,%' or length(p_clinica_img) > 500000) then
    p_clinica_img := null;
  end if;
  update public.contratos_ipad set status = 'substituido'
   where dono_id = v_dono and gestacao_id = p_gestacao_id and status = 'pendente'
     and (nome like 'Termo aditivo%') = v_termo;
  insert into public.contratos_ipad (dono_id, gestacao_id, path, nome, valor, html, clinica_img, gerado_por)
  values (v_dono, p_gestacao_id, p_path, left(coalesce(p_nome, ''), 120), p_valor, p_html, p_clinica_img, coalesce(v_nome, ''))
  returning id into v_id;
  return v_id;
end;
$$;

-- Recepção/médica: o HTML assinado no iPad (para "Ver" e "Enviar cópia à gestante").
create or replace function public.recepcao_contrato_ipad_html(p_id bigint)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare v_dono uuid; v_html text;
begin
  select dono_id into v_dono from public.recepcao_acessos where user_id = auth.uid();
  if v_dono is null then v_dono := auth.uid(); end if;
  if v_dono is null then raise exception 'sem acesso' using errcode = '42501'; end if;
  select html_assinado into v_html from public.contratos_ipad where id = p_id and dono_id = v_dono;
  if v_html is null then raise exception 'documento não encontrado'; end if;
  return v_html;
end;
$$;

-- iPad (anônimo): busca por nome ou CPF entre os contratos esperando assinatura.
-- Só os gerados nos últimos 7 dias, de gestação ativa. Devolve no máximo 10, sem o CPF inteiro.
create or replace function public.vitrine_assinatura_buscar(p_token text, p_busca text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_dono uuid;
  v_txt  text := translate(lower(trim(coalesce(p_busca, ''))), 'áàâãäéèêëíìîïóòôõöúùûüç', 'aaaaaeeeeiiiiooooouuuuc');
  v_dig  text := regexp_replace(coalesce(p_busca, ''), '\D', '', 'g');
begin
  if coalesce(length(p_token), 0) < 32 then raise exception 'chave inválida'; end if;
  select dono_id into v_dono from public.vitrine_chaves where token_assinatura = p_token;
  if v_dono is null then raise exception 'chave inválida'; end if;
  if length(v_txt) < 3 then return '[]'::jsonb; end if;
  return coalesce((
    select jsonb_agg(x order by x->>'criado_em' desc) from (
      select jsonb_build_object(
        'id', c.id, 'nome', p.nome, 'documento', c.nome, 'criado_em', c.criado_em,
        'cpf', case when length(regexp_replace(p.cpf, '\D', '', 'g')) = 11
                    then '***.' || substr(regexp_replace(p.cpf, '\D', '', 'g'), 4, 3) || '.' || substr(regexp_replace(p.cpf, '\D', '', 'g'), 7, 3) || '-**'
                    else '' end) as x
        from public.contratos_ipad c
        join public.gestacoes g on g.id = c.gestacao_id and g.user_id = v_dono and g.excluido_em is null and g.status = 'ativa'
        join public.patients p on p.id = g.paciente_id
       where c.dono_id = v_dono and c.status = 'pendente' and c.criado_em > now() - interval '7 days'
         and not exists (  -- já assinado por outro caminho (tela do computador, PDF anexado)
           select 1 from public.pagamentos_acompanhamento pa, jsonb_array_elements(coalesce(pa.contratos, '[]'::jsonb)) e
            where pa.gestacao_id = c.gestacao_id and e->>'kind' = 'assinado'
              and (e->>'em')::timestamptz >= c.criado_em
              and ((e->>'nome') like 'Termo aditivo%') = (c.nome like 'Termo aditivo%'))
         and ( (length(v_dig) >= 3 and v_dig = regexp_replace(v_txt, '[\s.\-]', '', 'g')
                and regexp_replace(p.cpf, '\D', '', 'g') like '%' || v_dig || '%')
            or (v_dig = '' and translate(lower(p.nome), 'áàâãäéèêëíìîïóòôõöúùûüç', 'aaaaaeeeeiiiiooooouuuuc') like '%' || v_txt || '%') )
       order by c.criado_em desc
       limit 10) s), '[]'::jsonb);
end;
$$;

-- iPad (anônimo): o documento a assinar.
create or replace function public.vitrine_assinatura_doc(p_token text, p_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_dono uuid; v_r jsonb;
begin
  if coalesce(length(p_token), 0) < 32 then raise exception 'chave inválida'; end if;
  select dono_id into v_dono from public.vitrine_chaves where token_assinatura = p_token;
  if v_dono is null then raise exception 'chave inválida'; end if;
  select jsonb_build_object('id', c.id, 'html', c.html, 'documento', c.nome, 'gerado_por', c.gerado_por, 'clinica_img', c.clinica_img,
                            'nome', p.nome, 'cpf', p.cpf)
    into v_r
    from public.contratos_ipad c
    join public.gestacoes g on g.id = c.gestacao_id and g.user_id = v_dono and g.excluido_em is null and g.status = 'ativa'
    join public.patients p on p.id = g.paciente_id
   where c.id = p_id and c.dono_id = v_dono and c.status = 'pendente' and c.criado_em > now() - interval '7 days'
         and not exists (  -- já assinado por outro caminho (tela do computador, PDF anexado)
           select 1 from public.pagamentos_acompanhamento pa, jsonb_array_elements(coalesce(pa.contratos, '[]'::jsonb)) e
            where pa.gestacao_id = c.gestacao_id and e->>'kind' = 'assinado'
              and (e->>'em')::timestamptz >= c.criado_em
              and ((e->>'nome') like 'Termo aditivo%') = (c.nome like 'Termo aditivo%'));
  if v_r is null then raise exception 'documento não encontrado ou já assinado'; end if;
  return v_r;
end;
$$;

-- iPad (anônimo): grava a via assinada e a põe na ficha como contrato assinado.
create or replace function public.vitrine_assinatura_salvar(p_token text, p_id bigint, p_html text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare v_dono uuid; c public.contratos_ipad%rowtype; v_item jsonb; v_termo boolean;
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
  insert into public.pagamentos_acompanhamento
    (gestacao_id, user_id, contratos, contrato_assinado, atualizado_por, atualizado_em)
  values (c.gestacao_id, v_dono, jsonb_build_array(v_item), true, 'iPad da recepção', now())
  on conflict (gestacao_id) do update set
    contratos = coalesce(pagamentos_acompanhamento.contratos, '[]'::jsonb) || jsonb_build_array(v_item),
    contrato_assinado = true;
  return true;
end;
$$;

revoke all on function public.recepcao_vitrine_assinatura_token() from public, anon;
revoke all on function public.recepcao_contrato_ipad(bigint, text, text, numeric, text, text) from public, anon;
revoke all on function public.recepcao_contrato_ipad_html(bigint) from public, anon;
revoke all on function public.vitrine_assinatura_buscar(text, text) from public;
revoke all on function public.vitrine_assinatura_doc(text, bigint) from public;
revoke all on function public.vitrine_assinatura_salvar(text, bigint, text) from public;
grant execute on function public.recepcao_vitrine_assinatura_token() to authenticated;
grant execute on function public.recepcao_contrato_ipad(bigint, text, text, numeric, text, text) to authenticated;
grant execute on function public.recepcao_contrato_ipad_html(bigint) to authenticated;
grant execute on function public.vitrine_assinatura_buscar(text, text) to anon, authenticated;
grant execute on function public.vitrine_assinatura_doc(text, bigint) to anon, authenticated;
grant execute on function public.vitrine_assinatura_salvar(text, bigint, text) to anon, authenticated;
