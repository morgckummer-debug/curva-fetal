-- 025 — Canal direto pelo Telegram (Premium e Gemelar Premium).
--
-- Cada gestação elegível ganha um código de uso único (vai no QR do contrato). A Edge Function
-- `telegram-bot` (supabase/functions/telegram-bot) usa estas tabelas com a service_role; o
-- navegador nunca lê nem escreve nelas direto — só a RPC telegram_codigo(), que o contrato chama.
--
-- Elegível = gestação ativa, não excluída, acompanhamento 'premium' ou 'gemelar_dc'.
-- Perdeu a elegibilidade (encerrou o plano, trocou de modalidade) → a função bloqueia a paciente
-- e fecha o tópico na próxima atividade do bot.
-- Idempotente.

create table if not exists public.telegram_vinculos (
  gestacao_id  bigint primary key references public.gestacoes(id) on delete cascade,
  codigo       text not null unique,
  chat_id      bigint,              -- preenchido pelo primeiro chat que usar o código
  topic_id     bigint,              -- tópico da paciente no grupo da médica
  vinculado_em timestamptz,
  bloqueado    boolean not null default false,
  bloqueado_em timestamptz,
  criado_em    timestamptz not null default now()
);
create index if not exists telegram_vinculos_chat_idx on public.telegram_vinculos (chat_id);
create index if not exists telegram_vinculos_topic_idx on public.telegram_vinculos (topic_id);

create table if not exists public.telegram_mensagens (
  id           bigint generated always as identity primary key,
  gestacao_id  bigint not null references public.gestacoes(id) on delete cascade,
  direcao      text not null check (direcao in ('paciente','medica','bot')),
  texto        text,
  tipo         text,                -- text, photo, voice, document...
  criado_em    timestamptz not null default now()
);
create index if not exists telegram_mensagens_gest_idx on public.telegram_mensagens (gestacao_id, criado_em);

-- RLS ligada e sem policy: só a service_role (Edge Function) acessa.
alter table public.telegram_vinculos enable row level security;
alter table public.telegram_mensagens enable row level security;
revoke all on public.telegram_vinculos, public.telegram_mensagens from anon, authenticated;

-- Devolve o código da gestação (cria se não existir). Recusa quem não é dono dos dados e
-- gestação que não seja Premium/Gemelar Premium ativa. Chamada pelo contrato (recepção ou médica).
create or replace function public.telegram_codigo(p_gestacao_id bigint)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_dono uuid := public.dono_recepcao();
  v_cod text;
begin
  if v_dono is null then raise exception 'sem acesso' using errcode = '42501'; end if;
  if not exists (select 1 from public.gestacoes
                  where id = p_gestacao_id and user_id = v_dono and excluido_em is null
                    and status = 'ativa' and acompanhamento in ('premium','gemelar_dc')) then
    raise exception 'gestação Premium ativa não encontrada';
  end if;
  select codigo into v_cod from public.telegram_vinculos where gestacao_id = p_gestacao_id;
  if v_cod is null then
    v_cod := substr(replace(gen_random_uuid()::text, '-', ''), 1, 12);
    insert into public.telegram_vinculos (gestacao_id, codigo) values (p_gestacao_id, v_cod);
  end if;
  return v_cod;
end;
$$;
revoke all on function public.telegram_codigo(bigint) from public, anon;
grant execute on function public.telegram_codigo(bigint) to authenticated;
