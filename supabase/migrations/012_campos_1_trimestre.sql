-- ═══════════════════════════════════════════════════════════════════════════
-- 012 — Campos do 1º trimestre (FMF): TN, FC e riscos digitados
-- ═══════════════════════════════════════════════════════════════════════════
--
-- A médica já digita translucência nucal, frequência cardíaca fetal e os
-- riscos de trissomias/pré-eclâmpsia (calculados pelo software oficial da
-- FMF, não pelo app) no editor de laudos (morfologico-1trimestre.html) — só
-- que ali eles nunca chegam ao Supabase, ficam só no laudo impresso. Fase 1
-- do port da página de risco/gráficos da FMF para o Curva de Crescimento:
-- essas colunas passam a existir aqui, alimentadas por um formulário próprio
-- do app (o editor de laudos continua sem gravar nelas por enquanto — ver
-- CLAUDE.md, "Fase 1 é só no curva-fetal").
--
-- Todas opt-in (nullable, sem default) — exame sem morfológico de 1º
-- trimestre simplesmente não preenche.
--
-- risco_t21/risco_t18/risco_t13/risco_pre_eclampsia são texto livre (formato
-- "1 em X", como o software da FMF devolve) — não são calculados aqui, só
-- exibidos; não há CHECK de formato de propósito, mesmo espírito de outros
-- campos de texto livre já existentes (au_fluxo, dv_onda).

alter table public.exams
  add column if not exists nt numeric,
  add column if not exists fc smallint,
  add column if not exists risco_t21 text,
  add column if not exists risco_t18 text,
  add column if not exists risco_t13 text,
  add column if not exists risco_pre_eclampsia text;
