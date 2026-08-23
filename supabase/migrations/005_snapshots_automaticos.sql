-- ═══════════════════════════════════════════════════════════════════════════
-- 005 — Snapshots automáticos (cópias de segurança dentro do próprio Supabase)
-- ═══════════════════════════════════════════════════════════════════════════
--
-- O plano Free do Supabase não faz backup automático nenhum. Até aqui, a única
-- cópia dos dados eram as três tabelas vivas (patients, gestacoes, exams) —
-- e cada saveDB() do app reescreve as três inteiras por upsert, a partir do
-- que está na memória do navegador. Uma linha sobrescrita com estado errado
-- não tinha para onde voltar.
--
-- Esta migração cria a área onde o app passa a guardar uma foto congelada do
-- banco, uma por dia em que houve alteração. São ARQUIVOS no Storage, não
-- linhas em tabela: nada que o app faça no dia a dia (upsert, delete da
-- lixeira, cascade) encosta neles.
--
-- Cobre: dado sobrescrito por bug, exclusão acidental, colisão com o editor
--        de laudos (que grava nas mesmas tabelas).
-- NÃO cobre: perder o projeto Supabase inteiro — o snapshot mora dentro dele.
--        Para esse caso só serve o arquivo baixado pelo botão "⬇ Backup".
--
-- Idempotente: pode rodar mais de uma vez sem efeito colateral.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── 1. O bucket ───────────────────────────────────────────────────────────
-- public = false: nenhum arquivo aqui é acessível por URL pública. A leitura
-- passa obrigatoriamente pelas policies abaixo, com a sessão da usuária.
--
-- file_size_limit de 25 MB é folga larga: um snapshot é um JSON de dezenas de
-- KB. O limite existe só para que um bug de loop não encha a cota de 1 GB do
-- plano Free com um arquivo gigante.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('backups', 'backups', false, 26214400, array['application/json'])
on conflict (id) do update
  set public             = excluded.public,
      file_size_limit    = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- ── 2. Quem enxerga o quê ─────────────────────────────────────────────────
-- Os arquivos ficam em backups/{user_id}/{data}.json. As policies amarram a
-- primeira pasta do caminho ao auth.uid() de quem está pedindo, então cada
-- conta só alcança os próprios snapshots — mesmo padrão do RLS das tabelas.
--
-- storage.foldername('abc-123/2026-08-23.json') devolve {'abc-123'}, e o [1]
-- pega esse primeiro nível.

drop policy if exists "snapshots: dono lê"      on storage.objects;
drop policy if exists "snapshots: dono grava"   on storage.objects;
drop policy if exists "snapshots: dono atualiza" on storage.objects;
drop policy if exists "snapshots: dono apaga"   on storage.objects;

create policy "snapshots: dono lê"
  on storage.objects for select to authenticated
  using (bucket_id = 'backups' and (storage.foldername(name))[1] = auth.uid()::text);

create policy "snapshots: dono grava"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'backups' and (storage.foldername(name))[1] = auth.uid()::text);

-- update: o snapshot do dia corrente é reescrito a cada gravação, para que a
-- foto de hoje acompanhe o trabalho de hoje. Os dias anteriores nunca são
-- tocados pelo app — só esta policy permitiria, e nada no código a usa fora
-- do arquivo do dia.
create policy "snapshots: dono atualiza"
  on storage.objects for update to authenticated
  using      (bucket_id = 'backups' and (storage.foldername(name))[1] = auth.uid()::text)
  with check (bucket_id = 'backups' and (storage.foldername(name))[1] = auth.uid()::text);

-- delete: nenhuma tela do app apaga snapshot. A policy existe para você poder
-- limpar arquivos antigos pelo painel do Supabase se um dia quiser.
create policy "snapshots: dono apaga"
  on storage.objects for delete to authenticated
  using (bucket_id = 'backups' and (storage.foldername(name))[1] = auth.uid()::text);

-- ── 3. Conferência ────────────────────────────────────────────────────────
-- Depois de rodar, isto deve devolver o bucket 'backups' com public = false
-- e as quatro policies:
--
--   select id, public, file_size_limit from storage.buckets where id = 'backups';
--   select policyname, cmd from pg_policies
--    where schemaname = 'storage' and tablename = 'objects'
--      and policyname like 'snapshots:%' order by policyname;
