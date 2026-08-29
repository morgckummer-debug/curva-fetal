-- ═══════════════════════════════════════════════════════════════════════════
-- 008 — Relatórios emitidos (segunda via do PDF de curva de crescimento)
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Até aqui, o relatório gerado em "Gerar PDF" (confirmarGerarPDF, index.html)
-- só existia na hora: abria a janela de impressão e sumia. Se a paciente
-- perdesse a via impressa, a única saída era remarcar exame para gerar outro.
--
-- Esta migração cria a área onde o app passa a guardar uma cópia de cada
-- relatório gerado, em relatorios/{user_id}/{gestacao_id}/{data}_{hora}.html —
-- mesmo padrão da 006 (bucket privado + RLS por auth.uid() na primeira pasta
-- do caminho), só que um arquivo por emissão em vez de reescrito por dia: cada
-- clique em "Gerar PDF" é uma emissão distinta, não um estado que se atualiza.
--
-- O arquivo guardado é o HTML autocontido inteiro (fontes embutidas em base64,
-- sem depender de nada externo) — reabri-lo entrega o mesmo relatório, com o
-- mesmo <body onload="window.print()">, pronto para imprimir de novo.
--
-- Idempotente: pode rodar mais de uma vez sem efeito colateral.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── 1. O bucket ───────────────────────────────────────────────────────────
-- public = false: nenhum relatório é acessível por URL pública — mesmo dado
-- clínico que o resto do app, mesma exigência de privacidade. A "segunda via"
-- abre por URL assinada (createSignedUrl), de curta duração, gerada só quando
-- a médica clica em "Abrir" na lista.
--
-- file_size_limit de 5 MB é folga larga: um relatório fica na casa de 100 KB
-- (a maior parte é a fonte embutida). O limite existe só contra um bug que
-- gerasse HTML gigante encher a cota do plano Free.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('relatorios', 'relatorios', false, 5242880, null)
on conflict (id) do update
  set public             = excluded.public,
      file_size_limit    = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- ── 2. Quem enxerga o quê ─────────────────────────────────────────────────
-- Os arquivos ficam em relatorios/{user_id}/{gestacao_id}/{data}_{hora}.html.
-- A policy amarra só a primeira pasta do caminho (o user_id) ao auth.uid() de
-- quem está pedindo — igual à 006 — então cada conta só alcança os próprios
-- relatórios; o id da gestação por baixo não precisa de policy própria porque
-- ninguém entra na pasta do user_id de outra pessoa para começo de conversa.

drop policy if exists "relatorios: dono lê"    on storage.objects;
drop policy if exists "relatorios: dono grava" on storage.objects;
drop policy if exists "relatorios: dono apaga" on storage.objects;

create policy "relatorios: dono lê"
  on storage.objects for select to authenticated
  using (bucket_id = 'relatorios' and (storage.foldername(name))[1] = auth.uid()::text);

create policy "relatorios: dono grava"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'relatorios' and (storage.foldername(name))[1] = auth.uid()::text);

-- delete: nenhuma tela do app apaga relatório emitido — a policy existe para
-- você poder limpar pelo painel do Supabase se um dia quiser (ex.: depois de
-- excluir a gestação correspondente).
create policy "relatorios: dono apaga"
  on storage.objects for delete to authenticated
  using (bucket_id = 'relatorios' and (storage.foldername(name))[1] = auth.uid()::text);

-- Sem policy de UPDATE de propósito: cada relatório é um arquivo imutável
-- (nome carimbado com data e hora até o segundo), nada no app reescreve um
-- relatório já emitido.

-- ── 3. Conferência ────────────────────────────────────────────────────────
-- Depois de rodar, isto deve devolver o bucket 'relatorios' com public = false
-- e as três policies:
--
--   select id, public, file_size_limit from storage.buckets where id = 'relatorios';
--   select policyname, cmd from pg_policies
--    where schemaname = 'storage' and tablename = 'objects'
--      and policyname like 'relatorios:%' order by policyname;

-- ═══════════════════════════════════════════════════════════════════════════
-- DIAGNÓSTICO — rode isto sozinho se o bucket aparecer no painel mas vazio
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Mesma pegadinha da 006: `insert into storage.buckets` quase sempre passa,
-- enquanto `create policy on storage.objects` pode ser recusado no SQL Editor
-- com "must be owner of table objects", dependendo do projeto. Nesse caso o
-- bucket existe, aparece no painel — e todo upload é negado pelo RLS, em
-- silêncio (a tela "Relatórios emitidos" fica vazia mesmo depois de gerar PDF).
--
-- O resultado esperado é 4 linhas: 1 do bucket e 3 policies (SELECT, INSERT,
-- DELETE). Se vier só a do bucket, é esse o problema: crie as três permissões
-- pelo painel, em Storage → Policies → relatorios, cada uma com a expressão
-- (storage.foldername(name))[1] = auth.uid()::text  para o papel `authenticated`.
--
--   select 'bucket' as o_que, id as nome, public::text as detalhe
--     from storage.buckets where id = 'relatorios'
--   union all
--   select 'policy', policyname, cmd
--     from pg_policies
--    where schemaname = 'storage' and tablename = 'objects'
--      and policyname like 'relatorios:%'
--    order by 1, 2;
