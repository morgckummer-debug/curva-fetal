-- ═══════════════════════════════════════════════════════════════════════════
-- 013 — Risco de parto prematuro e de diabetes gestacional (FMF)
-- ═══════════════════════════════════════════════════════════════════════════
--
-- O software oficial da FMF passou a incluir, no rastreamento combinado do
-- 1º trimestre, o risco de parto prematuro e o risco de diabetes gestacional
-- ao lado dos já existentes (T21/T18/T13, pré-eclâmpsia — migração 012).
-- Mesmo tratamento: texto livre ("1 em X", como o software devolve), não
-- calculado aqui, achado materno da visita (não é por feto, mesmo que a
-- gestação seja gemelar/trigemelar — é um rastreamento só, sobre a mãe).
--
-- Opt-in (nullable, sem default) — exame sem morfológico de 1º trimestre
-- simplesmente não preenche. Sem CHECK de formato, mesmo espírito de
-- risco_t21/risco_t18/risco_t13/risco_pre_eclampsia.

alter table public.exams
  add column if not exists risco_parto_prematuro text,
  add column if not exists risco_diabetes_gestacional text;
