-- 043 — A gestante escolhe, por um link, entre devolução por Pix e crédito (2026-10-18, pedido da Morgana).
--
-- No encerramento (desistência, perda, óbito fetal, parto) o extrato oferece duas opções e a devolução
-- fica em 'escolha' até a recepção registrar o que a gestante respondeu. Agora a mensagem do WhatsApp
-- leva um link pessoal (encerramento.html?t=<token>): a gestante vê só o primeiro nome e os dois valores
-- já guardados no extrato, escolhe, e se for Pix informa a chave e o titular. A ficha da recepção passa
-- sozinha para "Devolução pendente" (Pix) ou "Crédito ativo".
--
-- Os valores NÃO são recalculados aqui: vêm de pagamentos_acompanhamento.encerramento (estorno/crédito),
-- gravado pelo app no encerramento. A escolha só é aceita uma vez, com a devolução em 'escolha'.
-- Também recria recepcao_devolucao para não apagar a chave Pix ao registrar a devolução feita.
-- Idempotente.

create table if not exists public.encerramento_links (
  token        text primary key,
  dono_id      uuid not null references auth.users(id) on delete cascade,
  gestacao_id  bigint not null unique,
  criado_por   text not null default '',
  criado_em    timestamptz not null default now(),
  aberto_em    timestamptz
);
alter table public.encerramento_links enable row level security; -- sem policy: só pelas funções abaixo
revoke all on public.encerramento_links from anon, authenticated;

-- Médica/secretária: devolve o token da gestação (o mesmo a cada chamada).
create or replace function public.recepcao_encerramento_link(p_gestacao_id bigint)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare v_dono uuid; v_quem text; v_tok text;
begin
  select dono_id, nome into v_dono, v_quem from public.recepcao_acessos where user_id = auth.uid();
  if v_dono is null then v_dono := auth.uid(); v_quem := 'Dra. Morgana'; end if;
  if v_dono is null then raise exception 'sem acesso' using errcode = '42501'; end if;
  if not exists (select 1 from public.gestacoes where id = p_gestacao_id and user_id = v_dono and excluido_em is null) then
    raise exception 'gestação não encontrada';
  end if;
  select token into v_tok from public.encerramento_links where gestacao_id = p_gestacao_id and dono_id = v_dono;
  if v_tok is not null then return v_tok; end if;
  v_tok := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
  insert into public.encerramento_links (token, dono_id, gestacao_id, criado_por)
  values (v_tok, v_dono, p_gestacao_id, coalesce(v_quem, ''));
  return v_tok;
end;
$$;
revoke all on function public.recepcao_encerramento_link(bigint) from public, anon;
grant execute on function public.recepcao_encerramento_link(bigint) to authenticated;

-- Página sem login: só primeiro nome, motivo, plano e os valores do extrato. Nunca CPF nem exames.
create or replace function public.encerramento_publico(p_token text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare l public.encerramento_links; v_nome text; v_status text; e jsonb;
begin
  if p_token is null or length(p_token) < 40 then return null; end if;
  select * into l from public.encerramento_links where token = p_token;
  if l.token is null then return null; end if;
  select split_part(trim(p.nome), ' ', 1), g.status into v_nome, v_status
    from public.gestacoes g join public.patients p on p.id = g.paciente_id
   where g.id = l.gestacao_id and g.user_id = l.dono_id and g.excluido_em is null;
  if v_status is null then return null; end if;
  select encerramento into e from public.pagamentos_acompanhamento
   where gestacao_id = l.gestacao_id and user_id = l.dono_id;
  update public.encerramento_links set aberto_em = coalesce(aberto_em, now()) where token = p_token;
  if v_status = 'ativa' or e is null then
    return json_build_object('nome', v_nome, 'pronto', false);
  end if;
  return json_build_object(
    'nome', v_nome, 'pronto', true,
    'motivo', e->>'motivo', 'plano', e->>'plano', 'em', e->>'em',
    'estorno', coalesce((e->>'estorno')::numeric, 0), 'credito', coalesce((e->>'credito')::numeric, 0),
    'credito_nova_gestacao', coalesce((e->>'credito_nova_gestacao')::boolean, false),
    'validade', e->>'validade',
    'credito_falta', coalesce((e->>'credito_falta')::numeric, 0), 'credito_falta_validade', e->>'credito_falta_validade',
    'status', coalesce(e->'devolucao'->>'status', 'nada'),
    'opcao', e->'devolucao'->>'opcao',
    'via_link', coalesce((e->'devolucao'->>'via') = 'link', false));
end;
$$;
revoke all on function public.encerramento_publico(text) from public;
grant execute on function public.encerramento_publico(text) to anon, authenticated;

-- A gestante escolhe: 'pix' (com chave e titular) ou 'credito'. Uma vez só, com a devolução em 'escolha'.
create or replace function public.encerramento_escolher(p_token text, p_opcao text, p_pix_chave text, p_pix_titular text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare l public.encerramento_links; e jsonb; v_valor numeric; v_dev jsonb;
begin
  if p_token is null or length(p_token) < 40 then raise exception 'link inválido'; end if;
  select * into l from public.encerramento_links where token = p_token;
  if l.token is null then raise exception 'link inválido'; end if;
  if p_opcao not in ('pix', 'credito') then raise exception 'opção inválida'; end if;
  if not exists (select 1 from public.gestacoes where id = l.gestacao_id and user_id = l.dono_id
                  and excluido_em is null and status <> 'ativa') then
    raise exception 'link inválido';
  end if;
  select encerramento into e from public.pagamentos_acompanhamento
   where gestacao_id = l.gestacao_id and user_id = l.dono_id for update;
  if e is null or coalesce(e->'devolucao'->>'status', '') <> 'escolha' then
    raise exception 'escolha já registrada';
  end if;
  if p_opcao = 'pix' then
    v_valor := coalesce((e->>'estorno')::numeric, 0);
    if v_valor <= 0 then raise exception 'opção indisponível'; end if;
    if length(trim(coalesce(p_pix_chave, ''))) < 4 or length(trim(coalesce(p_pix_titular, ''))) < 3 then
      raise exception 'informe a chave Pix e o nome do titular';
    end if;
    v_dev := jsonb_build_object('status', 'pendente', 'opcao', 'dinheiro', 'valor', v_valor, 'forma', 'pix',
      'pix', jsonb_build_object('chave', left(trim(p_pix_chave), 120), 'titular', left(trim(p_pix_titular), 120)),
      'via', 'link', 'por', 'Gestante', 'em', now());
  else
    v_valor := coalesce((e->>'credito')::numeric, 0);
    if v_valor <= 0 then raise exception 'opção indisponível'; end if;
    v_dev := jsonb_build_object('status', 'credito', 'opcao', 'credito', 'valor', v_valor,
      'via', 'link', 'por', 'Gestante', 'em', now());
  end if;
  update public.pagamentos_acompanhamento
     set encerramento = jsonb_set(encerramento, '{devolucao}', v_dev),
         atualizado_por = 'Gestante (link)', atualizado_em = now()
   where gestacao_id = l.gestacao_id and user_id = l.dono_id;
  return json_build_object('ok', true, 'opcao', p_opcao);
end;
$$;
revoke all on function public.encerramento_escolher(text, text, text, text) from public;
grant execute on function public.encerramento_escolher(text, text, text, text) to anon, authenticated;

-- recepcao_devolucao (027) reescrevia a devolução inteira: a chave Pix informada pela gestante sumia
-- ao registrar a devolução feita. Mesma função, guardando 'pix' e 'via' da devolução anterior.
create or replace function public.recepcao_devolucao(
  p_gestacao_id bigint, p_status text, p_opcao text, p_valor numeric, p_data date, p_forma text, p_obs text,
  p_comprovante jsonb default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_dono uuid;
  v_nome text;
  v_ant jsonb;
  v_comp jsonb;
begin
  select dono_id, nome into v_dono, v_nome from public.recepcao_acessos where user_id = auth.uid();
  if v_dono is null then
    v_dono := auth.uid();
    v_nome := 'Dra. Morgana';
  end if;
  if v_dono is null then
    raise exception 'sem acesso' using errcode = '42501';
  end if;
  if p_status not in ('pendente', 'escolha', 'devolvido', 'credito', 'nada') then
    raise exception 'status inválido';
  end if;
  if p_comprovante is not null and (
       p_comprovante->>'path' is null
       or p_comprovante->>'path' not like v_dono::text || '/' || p_gestacao_id::text || '/%') then
    raise exception 'caminho do comprovante inválido';
  end if;
  select encerramento->'devolucao' into v_ant
    from public.pagamentos_acompanhamento
   where gestacao_id = p_gestacao_id and user_id = v_dono and encerramento is not null;
  if not found then
    raise exception 'encerramento não registrado';
  end if;
  -- sem comprovante novo, mantém o que já estava anexado
  v_comp := coalesce(p_comprovante, v_ant->'comprovante');
  update public.pagamentos_acompanhamento
     set encerramento = jsonb_set(encerramento, '{devolucao}', jsonb_strip_nulls(jsonb_build_object(
           'status', p_status, 'opcao', nullif(p_opcao, ''), 'valor', p_valor, 'data', p_data,
           'forma', nullif(left(coalesce(p_forma, ''), 40), ''), 'obs', left(coalesce(p_obs, ''), 500),
           'comprovante', v_comp, 'pix', v_ant->'pix', 'via', v_ant->'via',
           'por', coalesce(v_nome, ''), 'em', now()))),
         atualizado_por = coalesce(v_nome, ''), atualizado_em = now()
   where gestacao_id = p_gestacao_id and user_id = v_dono;
end;
$$;
revoke all on function public.recepcao_devolucao(bigint, text, text, numeric, date, text, text, jsonb) from public, anon;
grant execute on function public.recepcao_devolucao(bigint, text, text, numeric, date, text, text, jsonb) to authenticated;
