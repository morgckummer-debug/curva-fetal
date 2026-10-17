-- 042 — Link pessoal da via do contrato para a gestante (2026-10-17, pedido da Morgana).
--
-- No computador o navegador não consegue anexar arquivo numa conversa do WhatsApp: a secretária
-- teria de escolher o arquivo à mão (risco de mandar o contrato de outra paciente). Em vez do
-- arquivo, a mensagem leva um link (via.html?t=<token>) que abre só a via daquela gestante.
--
-- recepcao_via_publicar: médica/secretária guarda uma cópia do HTML da via e recebe o token.
-- via_publica: a página sem login lê a via pelo token (nunca lista nada, só devolve aquela).
-- Idempotente.

create table if not exists public.vias_gestante (
  token        text primary key,
  dono_id      uuid not null references auth.users(id) on delete cascade,
  gestacao_id  bigint not null,
  nome         text not null default '',   -- 'Contrato' | 'Termo aditivo'
  html         text not null,
  criado_por   text not null default '',
  criado_em    timestamptz not null default now(),
  aberto_em    timestamptz
);
create index if not exists vias_gestante_gest on public.vias_gestante (gestacao_id);
alter table public.vias_gestante enable row level security; -- sem policy: só pelas funções abaixo
revoke all on public.vias_gestante from anon, authenticated;

create or replace function public.recepcao_via_publicar(p_gestacao_id bigint, p_nome text, p_html text)
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
  if p_html is null or length(p_html) < 100 or length(p_html) > 3000000 then
    raise exception 'documento inválido';
  end if;
  -- mesma via já publicada: reaproveita o link
  select token into v_tok from public.vias_gestante
   where gestacao_id = p_gestacao_id and dono_id = v_dono and md5(html) = md5(p_html) limit 1;
  if v_tok is not null then return v_tok; end if;
  v_tok := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
  insert into public.vias_gestante (token, dono_id, gestacao_id, nome, html, criado_por)
  values (v_tok, v_dono, p_gestacao_id, coalesce(p_nome, ''), p_html, coalesce(v_quem, ''));
  return v_tok;
end;
$$;
revoke all on function public.recepcao_via_publicar(bigint, text, text) from public, anon;
grant execute on function public.recepcao_via_publicar(bigint, text, text) to authenticated;

create or replace function public.via_publica(p_token text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare r public.vias_gestante;
begin
  if p_token is null or length(p_token) < 40 then return null; end if;
  select v.* into r from public.vias_gestante v
    join public.gestacoes g on g.id = v.gestacao_id and g.excluido_em is null
   where v.token = p_token;
  if r.token is null then return null; end if;
  update public.vias_gestante set aberto_em = coalesce(aberto_em, now()) where token = p_token;
  return json_build_object('nome', r.nome, 'html', r.html);
end;
$$;
revoke all on function public.via_publica(text) from public;
grant execute on function public.via_publica(text) to anon, authenticated;
