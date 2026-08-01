-- ═══════════════════════════════════════════════════════════════════════
-- Migração 002 — suporte a gestação gemelar
--
-- Por quê: o app só sabia lidar com gestação única. Isso adiciona:
--   - gestacoes.tipo_gestacao ('unica' | 'gemelar') — escolhido no cadastro
--     da gestação. Default 'unica' pra não quebrar gestações já existentes.
--   - gestacoes.corionicidade — só relevante quando gemelar (dicoriônica/
--     diamniótica, monocoriônica/diamniótica, monocoriônica/monoamniótica),
--     importante pra critérios de CIUR seletivo mais adiante.
--   - exams.feto ('A' | 'B' | null) — em gestação gemelar cada feto tem seu
--     próprio registro de exame na mesma data; em gestação única fica null.
--
-- Como rodar: SQL Editor do Supabase → cole isto → Run. Seguro rodar mais
-- de uma vez ("add column if not exists").
-- ═══════════════════════════════════════════════════════════════════════

alter table public.gestacoes
  add column if not exists tipo_gestacao text not null default 'unica'
    check (tipo_gestacao in ('unica','gemelar'));

alter table public.gestacoes
  add column if not exists corionicidade text
    check (corionicidade in ('dicorionica_diamniotica','monocorionica_diamniotica','monocorionica_monoamniotica'));

alter table public.exams
  add column if not exists feto text check (feto in ('A','B'));
